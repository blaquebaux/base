# ============================================================================
# ALPACA VENUE ADAPTER — AlpacaVenue <: ExecutionVenue
# ----------------------------------------------------------------------------
# Thin adapter over Alpaca's Trading REST v2. Translates a canonical VenueOrder to
# POST /v2/orders, reports positions from GET /v2/positions, and drains fills from
# GET /v2/orders?status=closed. Carries NO safety logic — that lives in ExecutionController.
# Paper by default (paper-api.alpaca.markets). Requires ALPACA_KEY_ID / ALPACA_SECRET_KEY
# (paper keys need no account approval). HTTP + JSON3 are project deps.
#
# Idempotency (REQ-EXEC-002): our `client_order_id` is sent to Alpaca, which also dedups on
# it — a duplicate returns 422 and is surfaced as :uncertain (order may already be live), so
# the controller keeps the lineage recordable rather than double-submitting.
# ============================================================================
using HTTP, JSON3

"""
    AlpacaConfig(; paper=true, key_id=ENV["ALPACA_KEY_ID"], secret=ENV["ALPACA_SECRET_KEY"],
                 base_url=<paper|live>, timeout_sec=15.0)

Connection config for `AlpacaVenue`. `paper=true` → `paper-api.alpaca.markets`; `false` →
`api.alpaca.markets` (real money — governed invariants must be green first).
"""
struct AlpacaConfig
    key_id::String
    secret::String
    base_url::String
    timeout_sec::Float64
    crypto::Bool               # crypto mode: fractional qty + gtc + "BTC/USD" symbols (equity path when false)
end
function AlpacaConfig(; paper::Bool = true,
                      key_id::AbstractString = get(ENV, "ALPACA_KEY_ID", ""),
                      secret::AbstractString = get(ENV, "ALPACA_SECRET_KEY", ""),
                      base_url::AbstractString = paper ? "https://paper-api.alpaca.markets" :
                                                         "https://api.alpaca.markets",
                      timeout_sec::Real = 15.0, crypto::Bool = false)
    AlpacaConfig(String(key_id), String(secret), String(base_url), float(timeout_sec), crypto)
end

"""
    AlpacaVenue(cfg=AlpacaConfig()) <: ExecutionVenue
    AlpacaVenue(; kwargs...)     # kwargs forwarded to AlpacaConfig

Alpaca execution venue. `since` bounds the fill-drain query to the current session and `seen`
dedups already-reported fills (also guards against re-counting a partially-filled order).
"""
mutable struct AlpacaVenue <: ExecutionVenue
    cfg::AlpacaConfig
    connected::Bool
    since::DateTime               # UTC lower bound for drain_fills queries
    seen::Set{String}            # venue order ids already emitted as fills
    _lock::ReentrantLock
end
AlpacaVenue(cfg::AlpacaConfig = AlpacaConfig()) =
    AlpacaVenue(cfg, false, now(UTC), Set{String}(), ReentrantLock())
AlpacaVenue(; kwargs...) = AlpacaVenue(AlpacaConfig(; kwargs...))

_akeys(v::AlpacaVenue) = !isempty(v.cfg.key_id) && !isempty(v.cfg.secret)
_ahdrs(v::AlpacaVenue) = ["APCA-API-KEY-ID" => v.cfg.key_id, "APCA-API-SECRET-KEY" => v.cfg.secret]
_ato(v::AlpacaVenue)   = round(Int, v.cfg.timeout_sec)

function connect!(v::AlpacaVenue)::Bool
    _akeys(v) || (@warn "AlpacaVenue: missing ALPACA_KEY_ID/ALPACA_SECRET_KEY"; return false)
    resp = try
        HTTP.get(string(v.cfg.base_url, "/v2/account"); headers = _ahdrs(v),
                 readtimeout = _ato(v), status_exception = false, retry = false)
    catch e
        @warn "AlpacaVenue connect! threw" exception=e; return false
    end
    ok = resp.status == 200
    lock(v._lock) do
        v.connected = ok
        v.since = now(UTC) - Minute(1)       # small back-window so same-second submits are captured
        empty!(v.seen)
    end
    ok || @warn "AlpacaVenue connect! HTTP $(resp.status)" body=String(resp.body)
    return ok
end

disconnect!(v::AlpacaVenue) = (lock(() -> (v.connected = false), v._lock); nothing)
is_connected(v::AlpacaVenue)::Bool = v.connected

function submit!(v::AlpacaVenue, o::VenueOrder)::OrderAck
    _akeys(v) || return OrderAck(:rejected, "", o.client_order_id, "AlpacaVenue: missing API keys")
    if v.cfg.crypto
        # Crypto: fractional quantities are allowed; TIF must be gtc (crypto has no "day"); "BTC/USD" symbols.
        body = Dict{String,Any}(
            "symbol"          => o.symbol,
            "qty"             => string(round(o.quantity, digits = 8)),
            "side"            => o.side === :buy ? "buy" : "sell",
            "type"            => o.order_type === :limit ? "limit" : "market",
            "time_in_force"   => "gtc",
            "client_order_id" => o.client_order_id,
        )
    else
        # Equity: controller already rounds to whole shares; reject fractional rather than silently altering size.
        o.quantity != round(o.quantity) &&
            return OrderAck(:rejected, "", o.client_order_id,
                            "AlpacaVenue: whole shares only; got quantity=$(o.quantity)")
        body = Dict{String,Any}(
            "symbol"          => o.symbol,
            "qty"             => string(Int(o.quantity)),
            "side"            => o.side === :buy ? "buy" : "sell",
            "type"            => o.order_type === :limit ? "limit" : "market",
            "time_in_force"   => String(o.tif),
            "client_order_id" => o.client_order_id,          # broker-side idempotency (REQ-EXEC-002)
        )
    end
    o.order_type === :limit && o.limit_price !== nothing && (body["limit_price"] = string(o.limit_price))
    resp = try
        HTTP.post(string(v.cfg.base_url, "/v2/orders");
                  headers = [_ahdrs(v)..., "Content-Type" => "application/json"],
                  body = JSON3.write(body), readtimeout = _ato(v),
                  status_exception = false, retry = false)
    catch e
        # Sent but no confirmed response — the order MAY be live. Uncertain keeps lineage recordable.
        return OrderAck(:uncertain, "", o.client_order_id, "AlpacaVenue: POST threw (order may be live): $e")
    end
    if resp.status in (200, 201)
        j = JSON3.read(resp.body)
        return OrderAck(:accepted, String(j.id), o.client_order_id, nothing)
    elseif resp.status == 422 && occursin("client_order_id", String(resp.body))
        return OrderAck(:uncertain, "", o.client_order_id,
                        "AlpacaVenue: duplicate client_order_id (order likely already live)")
    else
        return OrderAck(:rejected, "", o.client_order_id,
                        "AlpacaVenue: HTTP $(resp.status) — $(String(resp.body))")
    end
end

"""
    account_info(v::AlpacaVenue) -> NamedTuple | nothing

`GET /v2/account` → `(; status, equity, cash, buying_power, trading_blocked, account_blocked)`.
`nothing` on missing keys / HTTP error. Feeds the Layer-3 safety gate (equity/drawdown, buying
power, account status).
"""
function account_info(v::AlpacaVenue)
    _akeys(v) || return nothing
    resp = try
        HTTP.get(string(v.cfg.base_url, "/v2/account"); headers = _ahdrs(v),
                 readtimeout = _ato(v), status_exception = false, retry = false)
    catch e
        @warn "AlpacaVenue account_info threw" exception=e; return nothing
    end
    resp.status == 200 || (@warn "AlpacaVenue account_info HTTP $(resp.status)" body=String(resp.body); return nothing)
    j = JSON3.read(resp.body)
    num(x) = (v = tryparse(Float64, string(x)); v === nothing ? 0.0 : v)
    return (status = String(get(j, :status, "")), equity = num(get(j, :equity, "0")),
            cash = num(get(j, :cash, "0")), buying_power = num(get(j, :buying_power, "0")),
            trading_blocked = Bool(get(j, :trading_blocked, false)),
            account_blocked = Bool(get(j, :account_blocked, false)))
end

function positions(v::AlpacaVenue, account::String)::Dict{String,Float64}
    d = Dict{String,Float64}()
    _akeys(v) || return d
    resp = try
        HTTP.get(string(v.cfg.base_url, "/v2/positions"); headers = _ahdrs(v),
                 readtimeout = _ato(v), status_exception = false, retry = false)
    catch e
        @warn "AlpacaVenue positions threw" exception=e; return d
    end
    resp.status == 200 || (@warn "AlpacaVenue positions HTTP $(resp.status)" body=String(resp.body); return d)
    for pos in JSON3.read(resp.body)
        q = tryparse(Float64, string(pos.qty))
        q === nothing && continue                         # Alpaca qty is signed (+ long, − short)
        sym = String(pos.symbol)
        # Crypto positions report "BTCUSD"; normalize to the "BTC/USD" order symbol so reconcile matches.
        v.cfg.crypto && !occursin('/', sym) && endswith(sym, "USD") && (sym = sym[1:end-3] * "/USD")
        d[sym] = q
    end
    return d
end

function drain_fills(v::AlpacaVenue)
    fills = NamedTuple[]
    _akeys(v) || return fills
    lock(v._lock) do
        after = Dates.format(v.since, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"  # literal Z (TimeZones treats Z as a tz token)
        resp = try
            HTTP.get(string(v.cfg.base_url, "/v2/orders"); headers = _ahdrs(v),
                     query = Dict("status" => "closed", "after" => after,
                                  "limit" => "500", "direction" => "asc"),
                     readtimeout = _ato(v), status_exception = false, retry = false)
        catch e
            @warn "AlpacaVenue drain_fills threw" exception=e; return fills
        end
        resp.status == 200 ||
            (@warn "AlpacaVenue drain_fills HTTP $(resp.status)" body=String(resp.body); return fills)
        for ord in JSON3.read(resp.body)
            st = String(get(ord, :status, ""))
            (st == "filled" || st == "partially_filled") || continue
            oid = String(ord.id)
            oid in v.seen && continue                    # dedup / partial-fill guard
            fq = tryparse(Float64, string(get(ord, :filled_qty, "0")))
            (fq === nothing || fq <= 0) && continue
            fap = tryparse(Float64, string(get(ord, :filled_avg_price, "0")))
            fap === nothing && (fap = 0.0)
            fa = get(ord, :filled_at, nothing)
            ts = fa === nothing ? now(UTC) : DateTime(String(fa)[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
            push!(fills, (symbol = String(ord.symbol), order_id = oid, exec_id = oid,
                          fill_price = fap, shares = fq,
                          side = String(ord.side) == "buy" ? "BOT" : "SLD", timestamp = ts))
            push!(v.seen, oid)
        end
    end
    return fills
end

function cancel!(v::AlpacaVenue, venue_order_id::String)::Bool
    _akeys(v) || return false
    resp = try
        HTTP.delete(string(v.cfg.base_url, "/v2/orders/", venue_order_id); headers = _ahdrs(v),
                    readtimeout = _ato(v), status_exception = false, retry = false)
    catch e
        @warn "AlpacaVenue cancel! threw" exception=e; return false
    end
    return resp.status in (200, 204)
end

"""
    cancel_all_open!(v::AlpacaVenue) -> Int

Cancel ALL open orders on the account (Alpaca `DELETE /v2/orders`); returns the number cancelled
(0 if none / no keys, −1 on HTTP error). Daily-rebalance hygiene: call this BEFORE placing new
orders so stale working orders can't double up with fresh ones. Cancels every open order, which
is correct for a dedicated single-strategy account.
"""
function cancel_all_open!(v::AlpacaVenue)::Int
    _akeys(v) || return 0
    resp = try
        HTTP.delete(string(v.cfg.base_url, "/v2/orders"); headers = _ahdrs(v),
                    readtimeout = _ato(v), status_exception = false, retry = false)
    catch e
        @warn "AlpacaVenue cancel_all_open! threw" exception=e; return -1
    end
    resp.status in (200, 204, 207) ||
        (@warn "AlpacaVenue cancel_all_open! HTTP $(resp.status)" body=String(resp.body); return -1)
    n = 0
    if resp.status == 207                    # multi-status: one entry per attempted cancel
        try; for _ in JSON3.read(resp.body); n += 1 end; catch; end
    end
    return n
end
