# ============================================================================
# OKX VENUE ADAPTER — OKXVenue <: ExecutionVenue
# ----------------------------------------------------------------------------
# Thin adapter over OKX v5 REST for the crypto funding-carry sleeve. Translates a canonical VenueOrder to
# POST /api/v5/trade/order (spot leg tdMode=cash; perp leg tdMode=cross), reports positions from
# /account/positions (perp, contracts→coin) + /account/balance (spot, base-ccy holding), and drains fills from
# /trade/fills-history. Carries NO safety logic — that lives in ExecutionController + the carry driver's tail
# governance. DEMO by default (header `x-simulated-trading: 1`, demo API keys) — real money is Phase 3 only.
#
# UNIFORM COIN-UNIT INTERFACE: the controller works in COIN units for BOTH legs; this adapter converts the perp
# leg coin-qty <-> CONTRACTS internally via the instrument's ctVal (e.g. BTC-USDT-SWAP ctVal=0.01 BTC/contract),
# so nothing upstream needs to know about contracts. positions() converts perp contracts back to coin so
# reconcile matches the coin-unit targets.
#
# Auth: OK-ACCESS-{KEY,SIGN,TIMESTAMP,PASSPHRASE}; SIGN = Base64(HMAC-SHA256(ts+METHOD+path+body, secret)).
# Idempotency (REQ-EXEC-002): our client_order_id -> OKX clOrdId (sanitized to ^[A-Za-z0-9]{1,32}$). A duplicate
# clOrdId is surfaced as :uncertain (order may already be live) so the controller doesn't double-submit.
# ============================================================================
using HTTP, JSON3, SHA, Base64, Dates

"""
    OKXConfig(; demo=true, key_id, secret, passphrase, base_url="https://www.okx.com", timeout_sec=15.0)

Connection config for `OKXVenue`. `demo=true` sends `x-simulated-trading: 1` and expects DEMO API keys
(created in OKX's demo environment). `demo=false` is real money — Phase 3 only, governed invariants green first.
Keys default to OKX_KEY_ID / OKX_SECRET / OKX_PASSPHRASE.
"""
struct OKXConfig
    key_id::String
    secret::String
    passphrase::String
    base_url::String
    timeout_sec::Float64
    demo::Bool
end
function OKXConfig(; demo::Bool = true,
                   key_id::AbstractString = get(ENV, "OKX_KEY_ID", ""),
                   secret::AbstractString = get(ENV, "OKX_SECRET", ""),
                   passphrase::AbstractString = get(ENV, "OKX_PASSPHRASE", ""),
                   base_url::AbstractString = "https://www.okx.com", timeout_sec::Real = 15.0)
    OKXConfig(String(key_id), String(secret), String(passphrase), String(base_url), float(timeout_sec), demo)
end

"""
    OKXVenue(cfg=OKXConfig()) <: ExecutionVenue

OKX crypto venue. `specs` caches per-instrument (ctVal, lotSz, minSz) fetched at connect!. `since` bounds the
fill-drain window; `seen` dedups already-reported fills.
"""
mutable struct OKXVenue <: ExecutionVenue
    cfg::OKXConfig
    connected::Bool
    specs::Dict{String,NamedTuple{(:ctVal, :lotSz, :minSz),Tuple{Float64,Float64,Float64}}}
    since::DateTime
    seen::Set{String}
    _lock::ReentrantLock
end
OKXVenue(cfg::OKXConfig = OKXConfig()) = OKXVenue(cfg, false, Dict{String,NamedTuple{(:ctVal,:lotSz,:minSz),Tuple{Float64,Float64,Float64}}}(), now(UTC), Set{String}(), ReentrantLock())
OKXVenue(; kwargs...) = OKXVenue(OKXConfig(; kwargs...))

_okeys(v::OKXVenue) = !isempty(v.cfg.key_id) && !isempty(v.cfg.secret) && !isempty(v.cfg.passphrase)
_oto(v::OKXVenue)   = round(Int, v.cfg.timeout_sec)
_isperp(sym::AbstractString) = endswith(sym, "-SWAP")
# OKX clOrdId must match ^[A-Za-z0-9]{1,32}$ — strip and keep the last 32 chars (deterministic → dedup-safe).
_clord(id::AbstractString) = (s = replace(id, r"[^A-Za-z0-9]" => ""); isempty(s) ? "bb" : s[max(1, end-31):end])

function _sign(v::OKXVenue, ts, method, path, body)
    msg = string(ts, method, path, body)
    base64encode(SHA.hmac_sha256(Vector{UInt8}(v.cfg.secret), msg))
end
function _headers(v::OKXVenue, method, path, body)
    ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
    h = ["OK-ACCESS-KEY" => v.cfg.key_id, "OK-ACCESS-SIGN" => _sign(v, ts, method, path, body),
         "OK-ACCESS-TIMESTAMP" => ts, "OK-ACCESS-PASSPHRASE" => v.cfg.passphrase,
         "Content-Type" => "application/json", "User-Agent" => "blaquebaux/okx"]
    v.cfg.demo && push!(h, "x-simulated-trading" => "1")
    h
end
"Signed request. Returns (status, json|nothing). GET carries the query in `path`; body is JSON for POST."
function _req(v::OKXVenue, method::String, path::String, body::String = "")
    resp = try
        if method == "GET"
            HTTP.get(string(v.cfg.base_url, path); headers = _headers(v, "GET", path, ""),
                     readtimeout = _oto(v), status_exception = false, retry = false)
        else
            HTTP.post(string(v.cfg.base_url, path); headers = _headers(v, "POST", path, body),
                      body = body, readtimeout = _oto(v), status_exception = false, retry = false)
        end
    catch e
        return (-1, nothing)
    end
    j = try JSON3.read(resp.body) catch; nothing end
    (resp.status, j)
end
# public (unsigned) GET — instrument specs, no keys
function _pub(v::OKXVenue, path::String)
    resp = try
        HTTP.get(string(v.cfg.base_url, path); headers = ["User-Agent" => "blaquebaux/okx"],
                 readtimeout = _oto(v), status_exception = false, retry = false)
    catch; return nothing; end
    resp.status == 200 ? (try JSON3.read(resp.body) catch; nothing end) : nothing
end
_num(x) = (y = tryparse(Float64, string(x)); y === nothing ? NaN : y)

"Load and cache (ctVal, lotSz, minSz) for a perp instId (public)."
function _load_spec!(v::OKXVenue, instId::AbstractString)
    haskey(v.specs, instId) && return v.specs[instId]
    j = _pub(v, "/api/v5/public/instruments?instType=SWAP&instId=$instId")
    (j === nothing || isempty(get(j, :data, []))) && return nothing
    d = j.data[1]
    s = (ctVal = _num(d.ctVal), lotSz = _num(d.lotSz), minSz = _num(d.minSz))
    lock(() -> (v.specs[instId] = s), v._lock); s
end

function connect!(v::OKXVenue)::Bool
    _okeys(v) || (@warn "OKXVenue: missing OKX_KEY_ID/OKX_SECRET/OKX_PASSPHRASE (demo keys for testnet)"; return false)
    st, _ = _req(v, "GET", "/api/v5/account/balance")     # auth probe
    ok = st == 200
    lock(v._lock) do
        v.connected = ok; v.since = now(UTC) - Minute(1); empty!(v.seen)
    end
    ok || @warn "OKXVenue connect! failed (status $st) — check demo keys / x-simulated-trading"
    return ok
end
disconnect!(v::OKXVenue) = (lock(() -> (v.connected = false), v._lock); nothing)
is_connected(v::OKXVenue)::Bool = v.connected

function submit!(v::OKXVenue, o::VenueOrder)::OrderAck
    _okeys(v) || return OrderAck(:rejected, "", o.client_order_id, "OKXVenue: missing API keys")
    body = Dict{String,Any}("instId" => o.symbol, "clOrdId" => _clord(o.client_order_id),
                            "side" => o.side === :buy ? "buy" : "sell",
                            "ordType" => o.order_type === :limit ? "limit" : "market")
    if _isperp(o.symbol)
        spec = _load_spec!(v, o.symbol)
        spec === nothing && return OrderAck(:rejected, "", o.client_order_id, "OKXVenue: no contract spec for $(o.symbol)")
        contracts = round(o.quantity / spec.ctVal / spec.lotSz) * spec.lotSz     # coin → contracts, to lot size
        contracts < spec.minSz && return OrderAck(:rejected, "", o.client_order_id,
            "OKXVenue: perp size $(contracts) < minSz $(spec.minSz) ($(o.symbol))")
        body["tdMode"] = "cross"; body["sz"] = string(contracts)                 # net (one-way) mode: side sell = short
    else
        body["tdMode"] = "cash"; body["sz"] = string(round(o.quantity, digits = 8))
        o.order_type === :market && (body["tgtCcy"] = "base_ccy")                # market sz in base coin (both sides)
    end
    o.order_type === :limit && o.limit_price !== nothing && (body["px"] = string(o.limit_price))
    st, j = _req(v, "POST", "/api/v5/trade/order", JSON3.write(body))
    st == -1 && return OrderAck(:uncertain, "", o.client_order_id, "OKXVenue: POST threw (order may be live)")
    (j === nothing) && return OrderAck(:rejected, "", o.client_order_id, "OKXVenue: HTTP $st (unparseable)")
    d = get(j, :data, nothing)
    if d !== nothing && !isempty(d)
        sCode = String(get(d[1], :sCode, "1")); ordId = String(get(d[1], :ordId, ""))
        sCode == "0" && return OrderAck(:accepted, ordId, o.client_order_id, nothing)
        # 51402/duplicate-clOrdId family → the order may already be live
        occursin("clOrdId", String(get(d[1], :sMsg, ""))) &&
            return OrderAck(:uncertain, "", o.client_order_id, "OKXVenue: duplicate clOrdId (order likely live)")
        return OrderAck(:rejected, "", o.client_order_id, "OKXVenue: sCode $sCode — $(get(d[1], :sMsg, ""))")
    end
    OrderAck(:rejected, "", o.client_order_id, "OKXVenue: code $(get(j, :code, "?")) — $(get(j, :msg, ""))")
end

"""
    account_info(v::OKXVenue) -> NamedTuple | nothing

`GET /account/balance` → `(; status, equity, cash, buying_power, trading_blocked, account_blocked, margin_ratio)`.
`margin_ratio` (OKX `mgnRatio`, equity/maintenance-margin) feeds the carry driver's margin-health circuit breaker.
"""
function account_info(v::OKXVenue)
    _okeys(v) || return nothing
    st, j = _req(v, "GET", "/api/v5/account/balance")
    (st == 200 && j !== nothing && !isempty(get(j, :data, []))) || return nothing
    d = j.data[1]
    eq = _num(get(d, :totalEq, "0")); avail = _num(get(d, :availEq, get(d, :totalEq, "0")))
    mgn = _num(get(d, :mgnRatio, "NaN"))
    (status = "ACTIVE", equity = isfinite(eq) ? eq : 0.0, cash = isfinite(avail) ? avail : 0.0,
     buying_power = isfinite(avail) ? avail : 0.0, trading_blocked = false, account_blocked = false,
     margin_ratio = mgn)
end

"Signed positions: perp instIds (contracts→coin, signed) + spot base-ccy holdings keyed as the order symbol."
function positions(v::OKXVenue, account::String)::Dict{String,Float64}
    d = Dict{String,Float64}(); _okeys(v) || return d
    st, j = _req(v, "GET", "/api/v5/account/positions?instType=SWAP")   # perps
    if st == 200 && j !== nothing
        for p in get(j, :data, [])
            instId = String(get(p, :instId, "")); pos = _num(get(p, :pos, "0"))
            spec = _load_spec!(v, instId)
            (spec === nothing || !isfinite(pos)) && continue
            d[instId] = pos * spec.ctVal                              # contracts → signed coin units
        end
    end
    stb, jb = _req(v, "GET", "/api/v5/account/balance")               # spot holdings (base-ccy) as "BASE-USDT"
    if stb == 200 && jb !== nothing && !isempty(get(jb, :data, []))
        for det in get(jb.data[1], :details, [])
            ccy = String(get(det, :ccy, "")); bal = _num(get(det, :cashBal, "0"))
            (ccy == "" || ccy == "USDT" || ccy == "USDC" || !isfinite(bal) || bal == 0) && continue
            d["$ccy-USDT"] = get(d, "$ccy-USDT", 0.0) + bal
        end
    end
    d
end

function drain_fills(v::OKXVenue)
    fills = NamedTuple[]; _okeys(v) || return fills
    lock(v._lock) do
        st, j = _req(v, "GET", "/api/v5/trade/fills-history?instType=ANY&limit=100")
        (st == 200 && j !== nothing) || return fills
        for f in get(j, :data, [])
            oid = String(get(f, :ordId, "")); tid = String(get(f, :tradeId, ""))
            key = oid * ":" * tid
            (isempty(tid) || key in v.seen) && continue
            sz = _num(get(f, :fillSz, "0")); px = _num(get(f, :fillPx, "0"))
            (!isfinite(sz) || sz <= 0) && continue
            instId = String(get(f, :instId, "")); spec = _isperp(instId) ? _load_spec!(v, instId) : nothing
            coin = spec === nothing ? sz : sz * spec.ctVal            # report perp fills in coin units
            tms = _num(get(f, :ts, "0")); ts = isfinite(tms) && tms > 0 ? unix2datetime(tms/1000) : now(UTC)
            push!(fills, (symbol = instId, order_id = oid, exec_id = tid, fill_price = px, shares = coin,
                          side = String(get(f, :side, "")) == "buy" ? "BOT" : "SLD", timestamp = ts))
            push!(v.seen, key)
        end
    end
    fills
end

function cancel!(v::OKXVenue, venue_order_id::String)::Bool
    _okeys(v) || return false
    st, j = _req(v, "POST", "/api/v5/trade/cancel-order", JSON3.write(Dict("ordId" => venue_order_id)))
    st == 200 && j !== nothing && String(get(j, :code, "1")) == "0"
end

"""
    cancel_all_open!(v::OKXVenue) -> Int

Cancel all pending orders (GET /trade/orders-pending → POST /trade/cancel-batch-orders). Returns the number
cancelled (0 if none/no keys, −1 on error). Rebalance hygiene, same contract as the Alpaca venue.
"""
function cancel_all_open!(v::OKXVenue)::Int
    _okeys(v) || return 0
    st, j = _req(v, "GET", "/api/v5/trade/orders-pending?limit=100")
    (st == 200 && j !== nothing) || return -1
    orders = [(instId = String(o.instId), ordId = String(o.ordId)) for o in get(j, :data, [])]
    isempty(orders) && return 0
    n = 0
    for chunk in Iterators.partition(orders, 20)          # OKX cancel-batch: max 20 per call
        body = JSON3.write([Dict("instId" => o.instId, "ordId" => o.ordId) for o in chunk])
        stc, jc = _req(v, "POST", "/api/v5/trade/cancel-batch-orders", body)
        stc == 200 && jc !== nothing && (n += count(x -> String(get(x, :sCode, "1")) == "0", get(jc, :data, [])))
    end
    n
end
