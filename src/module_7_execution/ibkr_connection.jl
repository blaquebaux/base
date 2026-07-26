# ============================================================================
# IBKR CONNECTION — Jib.jl (InteractiveBrokers Julia TWS Client)
# TWS live port: 7496 | Paper: 7497 | IB Gateway live: 4001 | Paper: 4002
# Jib repo: https://github.com/lbilli/Jib.jl
# ----------------------------------------------------------------------------
# Instance-based: each IBKRConnection is owned by its IBKRVenue (no global
# singleton), so multiple venues/accounts can coexist in one process.
# ============================================================================

using Sockets, Dates, TimeZones, Logging
using Base.Threads: ReentrantLock
using Jib

# ── Configuration ─────────────────────────────────────────────────────────────

struct IBKRConfig
    host::String
    port::Int
    client_id::Int
    account::String
    reconnect_attempts::Int
    reconnect_delay_sec::Float64
end

function IBKRConfig(;
    host::String              = get(ENV, "IBKR_HOST", "127.0.0.1"),
    port::Int                 = parse(Int, get(ENV, "IBKR_PORT", "7497")),  # paper by default
    client_id::Int            = 1,
    account::String           = get(ENV, "IBKR_ACCOUNT", ""),
    reconnect_attempts::Int   = 3,
    reconnect_delay_sec::Float64 = 5.0
)
    IBKRConfig(host, port, client_id, account, reconnect_attempts, reconnect_delay_sec)
end

# ── Connection state ──────────────────────────────────────────────────────────

mutable struct IBKRConnection
    config::IBKRConfig
    conn::Union{Jib.Connection, Nothing}   # Jib connection handle
    wrapper::Union{Any, Nothing}           # Jib wrapper (callback dispatch)
    reader::Union{Task, Nothing}           # Jib reader task
    is_connected::Bool
    next_order_id::Int                     # IBKR order ids ONLY (from nextValidId)
    next_req_id::Int                       # market-data / query request ids (separate space)
    positions::Dict{String, Float64}       # symbol → net position (updated by callbacks)
    pending_fills::Channel{NamedTuple}     # fills arrive asynchronously
    _lock::ReentrantLock
end

function IBKRConnection(config::IBKRConfig = IBKRConfig())
    IBKRConnection(config, nothing, nothing, nothing, false,
                   1,          # next_order_id (overwritten by nextValidId callback)
                   1_000_000,  # next_req_id — high base, disjoint from order-id space
                   Dict{String,Float64}(), Channel{NamedTuple}(256), ReentrantLock())
end

# ── Wrapper (Jib callback handler) ────────────────────────────────────────────

"""
Build a minimal Jib wrapper handling the callbacks we care about:
nextValidId → order id; orderStatus → log; position → positions dict;
execDetails → pending_fills channel. Other callbacks are ignored.
"""
function _build_wrapper(ibkr::IBKRConnection)
    return (
        nextValidId = (orderId::Int) -> begin
            lock(ibkr._lock) do
                ibkr.next_order_id = orderId
            end
            @info "IBKR nextValidId" next_order_id=orderId
        end,

        orderStatus = (orderId, status, filled, remaining, avgFillPrice,
                       permId, parentId, lastFillPrice, clientId, whyHeld, mktCapPrice) -> begin
            @info "IBKR orderStatus" orderId=orderId status=status filled=filled avgFillPrice=avgFillPrice
        end,

        position = (account, contract, pos, avgCost) -> begin
            lock(ibkr._lock) do
                ibkr.positions[contract.symbol] = pos
            end
            @info "IBKR position" symbol=contract.symbol pos=pos avgCost=avgCost
        end,

        positionEnd = () -> @info "IBKR positionEnd — snapshot complete",

        execDetails = (reqId, contract, execution) -> begin
            fill_record = (
                symbol     = contract.symbol,
                order_id   = execution.orderId,
                fill_price = execution.price,
                shares     = execution.shares,
                side       = execution.side,
                timestamp  = now(UTC)
            )
            # Every fill MUST be recorded (REQ-AUDIT-001) — never drop. Buffer is 256;
            # if it is ever full, blocking here signals the drain loop is behind, which
            # is far preferable to silently discarding an audit record.
            if Base.n_avail(ibkr.pending_fills) >= 250
                @error "pending_fills near capacity — drain loop is behind" n=Base.n_avail(ibkr.pending_fills)
            end
            put!(ibkr.pending_fills, fill_record)
            @info "IBKR execDetails" symbol=contract.symbol price=execution.price shares=execution.shares side=execution.side
        end,

        error = (id, errorCode, errorString, advancedOrderRejectJson) -> begin
            if errorCode in (2104, 2106, 2158, 2119)
                @debug "IBKR info" code=errorCode msg=errorString   # informational, not errors
            else
                @warn "IBKR error" id=id code=errorCode msg=errorString
            end
        end,

        connectionClosed = () -> begin
            lock(ibkr._lock) do
                ibkr.is_connected = false
            end
            @warn "IBKR connection closed"
        end
    )
end

# ── Connect / disconnect ──────────────────────────────────────────────────────

"""
    connect_ibkr(ibkr::IBKRConnection) -> Bool

Establish a connection to TWS or IB Gateway for this connection instance via
Jib.jl. Starts the reader task and requests the next valid order id.
"""
function connect_ibkr(ibkr::IBKRConnection)::Bool
    cfg = ibkr.config
    # Fast path — already connected. (F3: hold the lock only around state, not I/O.)
    lock(ibkr._lock) do; ibkr.is_connected end && return true
    # NOTE: not fully re-entrant against two simultaneous connect callers; connect is a
    # startup/reconnect operation, not a hot path. A "connecting" guard can be added if needed.

    for attempt in 1:cfg.reconnect_attempts
        try
            wrapper = _build_wrapper(ibkr)
            conn    = Jib.connect(cfg.host, cfg.port, cfg.client_id)   # network I/O — no lock
            reader  = Jib.start_reader(conn, wrapper)

            lock(ibkr._lock) do        # lock only the state mutation
                ibkr.conn         = conn
                ibkr.wrapper      = wrapper
                ibkr.reader       = reader
                ibkr.is_connected = true
            end

            Jib.Requests.reqIds(conn, 1)        # → next_order_id via callback
            Jib.Requests.reqPositions(conn)     # → initial position snapshot

            @info "Connected to IBKR" host=cfg.host port=cfg.port client_id=cfg.client_id attempt=attempt
            return true
        catch e
            @warn "IBKR connection attempt $(attempt) failed" exception=e
            attempt < cfg.reconnect_attempts && sleep(cfg.reconnect_delay_sec)   # sleep — no lock
        end
    end

    lock(ibkr._lock) do; ibkr.is_connected = false end
    @error "Failed to connect to IBKR after $(cfg.reconnect_attempts) attempts"
    return false
end

function disconnect_ibkr(ibkr::IBKRConnection)
    lock(ibkr._lock) do
        if ibkr.is_connected && ibkr.conn !== nothing
            Jib.disconnect(ibkr.conn)
            ibkr.is_connected = false
            ibkr.conn         = nothing
            @info "Disconnected from IBKR"
        end
    end
end

# ── Order submission ──────────────────────────────────────────────────────────

"""
    reserve_and_place(ibkr::IBKRConnection, build::Function) -> (success, order_id, error)

Allocate the next IBKR order id and place the order under a SINGLE lock, so
submission is serial and order-id allocation is atomic with placement
(REQ-EXEC-001). `build(oid::Int) -> (contract::Jib.Contract, order::Jib.Order)`.
The fill arrives asynchronously via `execDetails` on `ibkr.pending_fills`.
"""
function reserve_and_place(ibkr::IBKRConnection, build::Function)::Tuple{Symbol, String, Union{Nothing,String}}
    lock(ibkr._lock) do
        # Not connected → the order definitely did not go out; safe to retry.
        !ibkr.is_connected && return (:rejected, "", "Not connected to IBKR")
        oid = ibkr.next_order_id
        ibkr.next_order_id += 1
        try
            contract, jib_order = build(oid)
            Jib.Requests.placeOrder(ibkr.conn, oid, contract, jib_order)
            @info "Order placed via Jib" symbol=contract.symbol oid=oid
            return (:accepted, string(oid), nothing)
        catch e
            # placeOrder may have reached the broker before throwing → UNCERTAIN, not a
            # clean rejection. The order id is already consumed; do not reuse it. The
            # controller must lock this client_order_id, not retry it (F2 / REQ-EXEC-002).
            return (:uncertain, string(oid), "Order error (may have reached broker): $e")
        end
    end
end

# ── Position query / fill drain ───────────────────────────────────────────────

"""
    ibkr_get_positions(ibkr::IBKRConnection, account::String) -> Dict{String,Float64}

Positions from the in-memory cache (populated by reqPositions callbacks). Re-requests
a snapshot if empty. Authoritative broker-truth source for reconciliation (REQ-EXEC-003).
"""
function ibkr_get_positions(ibkr::IBKRConnection, account::String)::Dict{String,Float64}
    !ibkr.is_connected && return Dict{String,Float64}()
    # F3: don't hold the lock across the async wait. Request under lock, sleep outside,
    # then snapshot under lock.
    requested = lock(ibkr._lock) do
        if isempty(ibkr.positions)
            Jib.Requests.reqPositions(ibkr.conn)
            true
        else
            false
        end
    end
    requested && sleep(0.5)   # callbacks populate ibkr.positions asynchronously — outside the lock
    return lock(ibkr._lock) do
        copy(ibkr.positions)
    end
end

"""
    drain_pending_fills(ibkr::IBKRConnection, max_fills::Int=100) -> Vector{NamedTuple}

Drain the pending-fills channel. Called from the FeedbackLayer fill-recording loop
to convert execDetails callbacks into ledger FillRecord entries.
"""
function drain_pending_fills(ibkr::IBKRConnection, max_fills::Int=100)::Vector{NamedTuple}
    fills = NamedTuple[]
    count = 0
    while isready(ibkr.pending_fills) && count < max_fills
        push!(fills, take!(ibkr.pending_fills))
        count += 1
    end
    return fills
end

# ── Market data / options chain ───────────────────────────────────────────────
# Market-data / query request ids come from `next_req_id` (a SEPARATE id space from
# order ids) and are allocated under the lock — never from `next_order_id`.

function _reserve_req_id(ibkr::IBKRConnection)::Int
    lock(ibkr._lock) do
        rid = ibkr.next_req_id
        ibkr.next_req_id += 1
        return rid
    end
end

"""
    ibkr_req_mkt_data(ibkr, symbol, tick_list, secType) -> Int

Request market data for `symbol`. Returns reqId. Data arrives via wrapper callbacks.
For 0DTE option Greeks: tick_list = "100,101,106".
"""
function ibkr_req_mkt_data(
    ibkr::IBKRConnection,
    symbol::String,
    tick_list::String = "100,101,106",
    secType::String   = "STK"
)::Int
    ibkr.is_connected || return -1
    req_id = _reserve_req_id(ibkr)

    contract = Jib.Contract()
    contract.symbol   = symbol
    contract.secType  = secType
    contract.exchange = "SMART"
    contract.currency = "USD"

    Jib.Requests.reqMktData(ibkr.conn, req_id, contract, tick_list, false, false, [])
    @info "reqMktData sent" symbol=symbol reqId=req_id tick_list=tick_list
    return req_id
end

"""
    ibkr_req_sec_def_opt_params(ibkr, symbol, exchange) -> Int

Request option-chain parameters (expirations, strikes). Results arrive via the
secDefOptParams callback. Use to discover 0DTE expirations each morning.
"""
function ibkr_req_sec_def_opt_params(
    ibkr::IBKRConnection,
    symbol::String,
    exchange::String = "SMART"
)::Int
    ibkr.is_connected || return -1
    req_id = _reserve_req_id(ibkr)
    Jib.Requests.reqSecDefOptParams(ibkr.conn, req_id, symbol, exchange, "STK", 0)
    @info "reqSecDefOptParams sent" symbol=symbol reqId=req_id
    return req_id
end
