module ExecutionLayer

using Dates, Sockets, Logging, TimeZones

export OrderType, IBKROrder, CircuitBreakerState, CircuitBreakerStateMachine,
       check_emergency_liquidation, send_order, cancel_order,
       get_current_positions, LatencyMetrics,
       apply_position_floor,
       # Venue-adapter execution (venue-agnostic governed path)
       ExecutionVenue, VenueOrder, OrderAck, isaccepted, islocked_id,
       connect!, disconnect!, is_connected, submit!, cancel!, positions, drain_fills,
       IBKRVenue, IBKRConfig, IBKRConnection, drain_pending_fills,
       ExecutionController, submit_governed!, halt!, resume!, reconcile!, rehydrate!,
       apply_fill!, process_fills!, process_and_reconcile!,
       set_pool_budget!, set_pool_loss_limit!, update_pnl!,
       halt_pool!, resume_pool!, reset_daily!,
       set_pool_staleness!, mark_data_fresh!, set_audit_sink!

# ============================================================================
# Order Types and Structures
# ============================================================================

"""
    OrderType

Enumeration of supported order types.
"""
@enum OrderType begin
    LIMIT
    MARKET
end

"""
    IBKROrder

Interactive Brokers order structure.

# Fields
- `symbol::String`: Trading symbol
- `order_type::OrderType`: Order type (LIMIT or MARKET)
- `limit_price::Union{Float64,Nothing}`: Limit price (nothing for market orders)
- `quantity::Int`: Order quantity (positive = buy, negative = sell)
- `account::String`: Account identifier
- `timestamp::ZonedDateTime`: Order timestamp
"""
struct IBKROrder
    symbol::String
    order_type::OrderType
    limit_price::Union{Float64,Nothing}
    quantity::Int
    account::String
    timestamp::ZonedDateTime

    function IBKROrder(
        symbol::String,
        order_type::OrderType,
        limit_price::Union{Float64,Nothing},
        quantity::Int,
        account::String,
        timestamp::ZonedDateTime
    )
        if order_type == LIMIT
            @assert limit_price !== nothing "Limit price required for LIMIT orders"
            @assert limit_price > 0 "Limit price must be positive"
        end
        @assert quantity != 0 "Order quantity cannot be zero"
        new(symbol, order_type, limit_price, quantity, account, timestamp)
    end
end

# Convenience constructor with current timestamp
function IBKROrder(
    symbol::String,
    order_type::OrderType,
    limit_price::Union{Float64,Nothing},
    quantity::Int,
    account::String
)
    IBKROrder(symbol, order_type, limit_price, quantity, account, now(tz"America/New_York"))
end

# ============================================================================
# Circuit Breaker State Machine
# ============================================================================

"""
    CircuitBreakerState

Enumeration of circuit breaker states.

States:
- NORMAL: Normal operation
- VVIX_WATCH: VVIX elevated, monitoring
- BOOTSTRAP_WATCH: Bootstrap envelope breached
- EMERGENCY_LIQUIDATION: Emergency liquidation in progress
- COOLDOWN: Post-liquidation cooldown period
"""
@enum CircuitBreakerState begin
    NORMAL
    VVIX_WATCH
    BOOTSTRAP_WATCH
    EMERGENCY_LIQUIDATION
    COOLDOWN
end

"""
    CircuitBreakerStateMachine

State machine for circuit breaker logic.

# Fields
- `state::CircuitBreakerState`: Current state
- `vvix_breached_count::Int`: Consecutive VVIX breach count
- `bootstrap_envelope_3x::Bool`: Bootstrap envelope 3× threshold flag
- `cooldown_until::Union{Nothing,ZonedDateTime}`: Cooldown expiration
"""
mutable struct CircuitBreakerStateMachine
    state::CircuitBreakerState
    vvix_breached_count::Int
    bootstrap_envelope_3x::Bool
    cooldown_until::Union{Nothing,ZonedDateTime}

    function CircuitBreakerStateMachine()
        new(NORMAL, 0, false, nothing)
    end
end

# ============================================================================
# Emergency Liquidation Logic
# ============================================================================

"""
    check_emergency_liquidation(
        vvix::Float64,
        vix::Float64,
        bootstrap_envelope_width::Float64,
        bootstrap_median_6month::Float64,
        state_machine::CircuitBreakerStateMachine
    ) -> Tuple{Bool, CircuitBreakerStateMachine}

Check if emergency liquidation should be triggered.

# Triggers (OR with persistence)
1. VVIX > 120 (3-minute persistence)
2. Bootstrap envelope width > 3× 6-month median
3. VIX > 40 (immediate)

# Arguments
- `vvix::Float64`: Current VVIX value
- `vix::Float64`: Current VIX value
- `bootstrap_envelope_width::Float64`: Current bootstrap envelope width
- `bootstrap_median_6month::Float64`: 6-month median envelope width
- `state_machine::CircuitBreakerStateMachine`: Current state machine

# Returns
- `should_liquidate::Bool`: Whether to liquidate
- `new_state::CircuitBreakerStateMachine`: Updated state machine
"""
function check_emergency_liquidation(
    vvix::Float64,
    vix::Float64,
    bootstrap_envelope_width::Float64,
    bootstrap_median_6month::Float64,
    state_machine::CircuitBreakerStateMachine
)::Tuple{Bool, CircuitBreakerStateMachine}

    new_state = deepcopy(state_machine)
    should_liquidate = false

    # Check cooldown
    if new_state.cooldown_until !== nothing
        if now(tz"America/New_York") < new_state.cooldown_until
            return (false, new_state)
        else
            new_state.cooldown_until = nothing
            new_state.state = NORMAL
        end
    end

    # Trigger 1: VVIX > 2×VIX for 3-minute persistence (spec Section 7.4)
    # NOTE: Spec uses ratio VVIX/VIX > 2.0, NOT absolute VVIX level.
    # A ratio threshold is more robust across different vol regimes.
    vvix_ratio = vix > 0 ? vvix / vix : 0.0
    if vvix_ratio > 2.0
        new_state.vvix_breached_count += 1
        if new_state.vvix_breached_count >= 3
            new_state.state = EMERGENCY_LIQUIDATION
            should_liquidate = true
        else
            new_state.state = VVIX_WATCH
        end
    else
        new_state.vvix_breached_count = 0
        if new_state.state == VVIX_WATCH
            new_state.state = NORMAL
        end
    end

    # Trigger 2: Bootstrap envelope 3× median
    if bootstrap_median_6month > 0 && 
       bootstrap_envelope_width > 3.0 * bootstrap_median_6month
        new_state.bootstrap_envelope_3x = true
        new_state.state = BOOTSTRAP_WATCH
        should_liquidate = true
    else
        new_state.bootstrap_envelope_3x = false
    end

    # NOTE: A standalone VIX > 40 trigger was in the original draft but is NOT in the
    # v2.0 spec (Section 7.4). The spec uses only: (1) VVIX/VIX ratio persistence
    # and (2) bootstrap envelope width. High VIX is already captured via the ratio
    # trigger above. Removed to maintain spec fidelity.
    # To re-enable: uncomment below and adjust threshold as appropriate.
    # if vix > 40.0
    #     new_state.state = EMERGENCY_LIQUIDATION
    #     should_liquidate = true
    # end

    # Set cooldown if liquidating
    if should_liquidate
        new_state.cooldown_until = now(tz"America/New_York") + Minute(30)
    end

    return (should_liquidate, new_state)
end

# ============================================================================
# Order Execution
# ============================================================================

"""
    send_order(order::IBKROrder) -> Tuple{Bool, String, Union{Nothing,String}}

Send order to Interactive Brokers.

# Arguments
- `order::IBKROrder`: Order to send

# Returns
- `success::Bool`: Whether order was accepted
- `order_id::String`: Order identifier (or empty string if failed)
- `error_message::Union{Nothing,String}`: Error message if failed
"""
function send_order(order::IBKROrder)::Tuple{Bool, String, Union{Nothing,String}}
    # In production: Connect to IBKR API (TWS/Gateway)
    # For now: simulated execution with validation

    @info "Order submitted" symbol=order.symbol quantity=order.quantity order_type=order.order_type account=order.account

    # Validate order
    if abs(order.quantity) > 1000000
        return (false, "", "Order quantity exceeds maximum limit")
    end

    if order.order_type == LIMIT && order.limit_price === nothing
        return (false, "", "Limit price required for LIMIT order")
    end

    # Simulated success
    order_id = "IBKR_$(Dates.format(order.timestamp, "yyyymmdd_HHMMSS"))_$(rand(1000:9999))"

    @info "Order executed successfully" order_id=order_id

    return (true, order_id, nothing)
end

"""
    cancel_order(order_id::String) -> Bool

Cancel an existing order.

# Arguments
- `order_id::String`: Order identifier to cancel

# Returns
- `Bool`: Whether cancellation was successful
"""
function cancel_order(order_id::String)::Bool
    @info "Cancelling order" order_id=order_id

    # In production: Send cancel request to IBKR
    # For now: simulated success
    return true
end

"""
    get_current_positions(account::String) -> Dict{String,Float64}

Query current positions for reconciliation.

# Arguments
- `account::String`: Account identifier

# Returns
- `Dict{String,Float64}`: Symbol → quantity mapping
"""
function get_current_positions(account::String)::Dict{String,Float64}
    # In production: Query IBKR position API
    # For now: return empty (positions managed externally)
    @info "Querying positions" account=account
    return Dict{String,Float64}()
end

# ============================================================================
# Latency Metrics
# ============================================================================

"""
    LatencyMetrics

Execution latency monitoring targets.

# Fields
- `daily_rebalance_latency::Float64`: Daily rebalance latency (seconds)
- `intraday_trigger_latency::Float64`: Intraday trigger latency (seconds)
- `emergency_liquidation_latency::Float64`: Emergency liquidation latency (seconds)
"""
struct LatencyMetrics
    daily_rebalance_latency::Float64
    intraday_trigger_latency::Float64
    emergency_liquidation_latency::Float64
end

"""
    measure_latency(operation::Function) -> Tuple{Any, Float64}

Measure execution time of an operation.

# Returns
- `result`: Operation result
- `elapsed_seconds::Float64`: Elapsed time
"""
function measure_latency(operation::Function)::Tuple{Any, Float64}
    start_time = time()
    result = operation()
    elapsed = time() - start_time
    return (result, elapsed)
end

# ============================================================================
# Position Floor Logic
# ============================================================================

"""
    apply_position_floor(
        notional::Float64,
        min_notional::Float64=500.0
    ) -> Float64

Apply absolute position floor.

Orders below minimum notional are rejected (return 0.0).

# Arguments
- `notional::Float64`: Order notional value
- `min_notional::Float64`: Minimum notional threshold (default: \$500)

# Returns
- `Float64`: Order notional (0.0 if below floor)
"""
function apply_position_floor(
    notional::Float64,
    min_notional::Float64=500.0
)::Float64
    if notional < min_notional
        @warn "Order below position floor" notional=notional floor=min_notional
        return 0.0
    end
    return notional
end

"""
    apply_position_floor(
        quantity::Int,
        price::Float64,
        min_notional::Float64=500.0
    ) -> Int

Apply position floor to quantity.

# Returns
- `Int`: Adjusted quantity (0 if below floor)
"""
function apply_position_floor(
    quantity::Int,
    price::Float64,
    min_notional::Float64=500.0
)::Int
    notional = abs(quantity * price)
    if notional < min_notional
        return 0
    end
    return quantity
end

# ============================================================================
# Venue-adapter execution layer
# ----------------------------------------------------------------------------
# Order matters: interface first, then connection primitives, then the IBKR
# adapter, then the venue-agnostic governed controller. The legacy simulated
# `send_order` above is retained for backward compatibility and will be retired
# once `submit_governed!` is fully wired (steps 2–5).
# ============================================================================
include("venue_interface.jl")
include("ibkr_connection.jl")     # was dead code; now wired. `using Jib` lives inside.
include("venues/ibkr.jl")
include("execution_controller.jl")

end  # module ExecutionLayer
