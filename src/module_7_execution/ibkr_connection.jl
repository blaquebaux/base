# ============================================================================
# IBKR CONNECTION — Jib.jl (InteractiveBrokers Julia TWS Client)
# Replaces TCP scaffold with real Jib.jl API calls.
# Jib repo: https://github.com/lbilli/Jib.jl
# TWS live port: 7496  |  Paper port: 7497
# IB Gateway live: 4001 | Paper: 4002
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
    port::Int                 = parse(Int, get(ENV, "IBKR_PORT", "7497")),
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
    next_order_id::Int
    positions::Dict{String, Float64}       # symbol → net position (updated by callbacks)
    pending_fills::Channel{NamedTuple}     # fills arrive asynchronously
    _lock::ReentrantLock
end

function IBKRConnection(config::IBKRConfig = IBKRConfig())
    IBKRConnection(config, nothing, nothing, nothing, false, 1,
                   Dict{String,Float64}(), Channel{NamedTuple}(256), ReentrantLock())
end

const _IBKR_CONN = Ref{IBKRConnection}()

function get_ibkr_connection(config::IBKRConfig = IBKRConfig())
    if !isassigned(_IBKR_CONN)
        _IBKR_CONN[] = IBKRConnection(config)
    end
    return _IBKR_CONN[]
end

# ── Wrapper (Jib callback handler) ────────────────────────────────────────────

"""
Build a minimal Jib wrapper that handles the callbacks we care about:
- nextValidId   → sets next_order_id
- orderStatus   → logs fill status
- position      → updates positions dict
- execDetails   → pushes to pending_fills channel

All other Jib callbacks are silently ignored (they are optional in Jib).
"""
function _build_wrapper(ibkr::IBKRConnection)
    # Jib.Wrapper is a NamedTuple of optional callbacks.
    # Only define the ones we need.
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
            isready(ibkr.pending_fills) || put!(ibkr.pending_fills, fill_record)
            @info "IBKR execDetails" symbol=contract.symbol price=execution.price shares=execution.shares side=execution.side
        end,

        error = (id, errorCode, errorString, advancedOrderRejectJson) -> begin
            if errorCode in (2104, 2106, 2158, 2119)
                # Informational codes — not errors
                @debug "IBKR info" code=errorCode msg=errorString
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
    connect_ibkr([config]) -> Bool

Establish connection to TWS or IB Gateway via Jib.jl.
Starts the Jib reader task and requests the next valid order ID.
"""
function connect_ibkr(config::IBKRConfig = IBKRConfig())::Bool
    ibkr = get_ibkr_connection(config)
    lock(ibkr._lock) do
        ibkr.is_connected && return true   # already connected

        for attempt in 1:config.reconnect_attempts
            try
                wrapper = _build_wrapper(ibkr)
                conn    = Jib.connect(config.host, config.port, config.client_id)
                reader  = Jib.start_reader(conn, wrapper)

                ibkr.conn         = conn
                ibkr.wrapper      = wrapper
                ibkr.reader       = reader
                ibkr.is_connected = true

                # Request next valid order ID — populates next_order_id via callback
                Jib.Requests.reqIds(conn, 1)
                # Request initial position snapshot
                Jib.Requests.reqPositions(conn)

                @info "Connected to IBKR" host=config.host port=config.port client_id=config.client_id attempt=attempt
                return true
            catch e
                @warn "IBKR connection attempt $(attempt) failed" exception=e
                attempt < config.reconnect_attempts && sleep(config.reconnect_delay_sec)
            end
        end

        ibkr.is_connected = false
        @error "Failed to connect to IBKR after $(config.reconnect_attempts) attempts"
        return false
    end
end

function disconnect_ibkr()
    ibkr = get_ibkr_connection()
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
    ibkr_send_order(order::IBKROrder) -> (success, order_id, error)

Place an order via Jib.jl placeOrder(). Constructs Jib Contract and Order
objects from the IBKROrder, then calls Jib.Requests.placeOrder.

The fill arrives asynchronously via the execDetails callback and is placed
on ibkr.pending_fills for the FeedbackLayer.ExecutionLedger to consume.
"""
function ibkr_send_order(order::IBKROrder)::Tuple{Bool, String, Union{Nothing,String}}
    ibkr = get_ibkr_connection()
    lock(ibkr._lock) do
        !ibkr.is_connected && return (false, "", "Not connected to IBKR")

        try
            oid = ibkr.next_order_id
            ibkr.next_order_id += 1

            # Build Jib Contract
            contract = Jib.Contract()
            contract.symbol      = order.symbol
            contract.secType     = _sectype(order)
            contract.exchange    = get(ENV, "IBKR_EXCHANGE", "SMART")
            contract.currency    = "USD"

            # For options: set expiry, strike, right
            if hasproperty(order, :expiry) && !isempty(order.expiry)
                contract.lastTradeDateOrContractMonth = order.expiry
                contract.strike    = order.strike
                contract.right     = order.right   # "C" or "P"
                contract.multiplier = "100"
            end

            # Build Jib Order
            jib_order = Jib.Order()
            jib_order.orderId       = oid
            jib_order.action        = order.action   # "BUY" or "SELL"
            jib_order.totalQuantity = float(order.quantity)
            jib_order.orderType     = order.order_type   # "MKT", "LMT", etc.
            jib_order.tif           = get(order, :tif, "DAY")

            if order.order_type == "LMT" && hasproperty(order, :limit_price)
                jib_order.lmtPrice = order.limit_price
            end
            if hasproperty(order, :account) && !isempty(order.account)
                jib_order.account = order.account
            end

            Jib.Requests.placeOrder(ibkr.conn, oid, contract, jib_order)

            @info "Order placed via Jib" symbol=order.symbol qty=order.quantity order_type=order.order_type oid=oid
            return (true, string(oid), nothing)
        catch e
            return (false, "", "Order error: $e")
        end
    end
end

# ── Position query ────────────────────────────────────────────────────────────

"""
    ibkr_get_positions(account::String) -> Dict{String,Float64}

Return positions from the in-memory cache (populated by reqPositions callback).
Re-requests a snapshot if the cache is empty. On strategy restart, this is
the authoritative source of truth for reconciling the FeedbackLayer ledger.
"""
function ibkr_get_positions(account::String)::Dict{String,Float64}
    ibkr = get_ibkr_connection()
    !ibkr.is_connected && return Dict{String,Float64}()

    lock(ibkr._lock) do
        if isempty(ibkr.positions)
            # Positions haven't arrived yet — re-request and wait briefly
            Jib.Requests.reqPositions(ibkr.conn)
            sleep(0.5)   # callbacks populate ibkr.positions asynchronously
        end
        return copy(ibkr.positions)
    end
end

"""
    drain_pending_fills(max_fills::Int=100) -> Vector{NamedTuple}

Drain the pending fills channel. Call from the FeedbackLayer fill-recording
loop to convert execDetails callbacks into FillRecord entries in the ledger.
"""
function drain_pending_fills(max_fills::Int=100)::Vector{NamedTuple}
    ibkr  = get_ibkr_connection()
    fills = NamedTuple[]
    count = 0
    while isready(ibkr.pending_fills) && count < max_fills
        push!(fills, take!(ibkr.pending_fills))
        count += 1
    end
    return fills
end

# ── Market data / options chain ───────────────────────────────────────────────

"""
    ibkr_req_mkt_data(symbol, tick_list) -> Int

Request market data for `symbol`. Returns reqId. Data arrives via wrapper
callbacks (not captured here — caller must supply a wrapper that handles
tickPrice / tickSize / tickOptionComputation).

For 0DTE option Greeks: use tick_list = "100,101,106" (option Greeks ticks).
"""
function ibkr_req_mkt_data(
    symbol::String,
    tick_list::String = "100,101,106",
    secType::String   = "STK"
)::Int
    ibkr = get_ibkr_connection()
    !ibkr.is_connected && return -1

    req_id = ibkr.next_order_id
    ibkr.next_order_id += 1

    contract = Jib.Contract()
    contract.symbol  = symbol
    contract.secType = secType
    contract.exchange = "SMART"
    contract.currency = "USD"

    Jib.Requests.reqMktData(ibkr.conn, req_id, contract, tick_list, false, false, [])
    @info "reqMktData sent" symbol=symbol reqId=req_id tick_list=tick_list
    return req_id
end

"""
    ibkr_req_sec_def_opt_params(symbol, exchange) -> Int

Request option chain parameters (expirations, strikes) for `symbol`.
Results arrive via the secDefOptParams wrapper callback.
Use this to discover available 0DTE expirations each morning.
"""
function ibkr_req_sec_def_opt_params(
    symbol::String,
    exchange::String = "SMART"
)::Int
    ibkr = get_ibkr_connection()
    !ibkr.is_connected && return -1

    req_id = ibkr.next_order_id
    ibkr.next_order_id += 1
    Jib.Requests.reqSecDefOptParams(ibkr.conn, req_id, symbol, exchange, "STK", 0)
    @info "reqSecDefOptParams sent" symbol=symbol reqId=req_id
    return req_id
end

# ── Internal helpers ──────────────────────────────────────────────────────────

function _sectype(order)::String
    if hasproperty(order, :sec_type)
        return order.sec_type
    end
    return "STK"
end
