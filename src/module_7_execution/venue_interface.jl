# ============================================================================
# VENUE INTERFACE — venue-agnostic execution contract
# ----------------------------------------------------------------------------
# The governed execution controller speaks ONLY this interface. Concrete
# venues (IBKRVenue now, AlpacaVenue later) implement it via multiple dispatch.
# This is what lets "IBKR now, Alpaca later" be one governed codebase with a
# thin adapter per broker — NOT a repo fork. See design.md "Execution venues".
# ============================================================================

"""
    ExecutionVenue

Abstract supertype for every broker adapter. A venue is responsible ONLY for
translating a canonical `VenueOrder` to its broker's API and back. All safety
logic (idempotency, budget gate, lineage, loss halt, kill switch) lives in the
venue-agnostic `ExecutionController`, not here.
"""
abstract type ExecutionVenue end

"""
    VenueOrder

Canonical, broker-neutral order. Adapters translate this to their own order
type. Direction is carried by `side`; `quantity` is always positive.

Idempotency (REQ-EXEC-002) and lineage (REQ-AUDIT-001) fields are part of the
order from the start so the controller and adapters are shaped correctly before
the governed logic that populates/enforces them is wired.

# Fields
- `client_order_id::String` — caller-assigned idempotency key (REQ-EXEC-002)
- `symbol::String`
- `side::Symbol` — `:buy` or `:sell`
- `quantity::Float64` — always positive
- `order_type::Symbol` — `:market` or `:limit`
- `limit_price::Union{Float64,Nothing}` — required for `:limit`
- `tif::Symbol` — `:day`, `:gtc`, or `:ioc`
- `account::String`
- `pool_id::String` — for the per-pool budget gate (REQ-RISK-003)
- `signal_id`/`regime`/`solve_id` — decision lineage (REQ-AUDIT-001)
"""
struct VenueOrder
    client_order_id::String
    symbol::String
    side::Symbol
    quantity::Float64
    order_type::Symbol
    limit_price::Union{Float64,Nothing}
    tif::Symbol
    account::String
    pool_id::String
    signal_id::Union{String,Nothing}
    regime::Union{String,Nothing}
    solve_id::Union{String,Nothing}

    function VenueOrder(client_order_id, symbol, side, quantity, order_type,
                        limit_price, tif, account, pool_id,
                        signal_id, regime, solve_id)
        @assert !isempty(client_order_id) "client_order_id (idempotency key) required — REQ-EXEC-002"
        @assert side in (:buy, :sell) "side must be :buy or :sell, got $side"
        @assert order_type in (:market, :limit) "order_type must be :market or :limit, got $order_type"
        @assert quantity > 0 "quantity must be positive (direction is carried by side)"
        @assert tif in (:day, :gtc, :ioc) "tif must be :day, :gtc, or :ioc, got $tif"
        if order_type == :limit
            @assert limit_price !== nothing "limit_price required for :limit orders"
            @assert limit_price > 0 "limit_price must be positive"
        end
        new(client_order_id, symbol, side, quantity, order_type, limit_price,
            tif, account, pool_id, signal_id, regime, solve_id)
    end
end

# Keyword convenience constructor.
function VenueOrder(; client_order_id::String, symbol::String, side::Symbol,
                    quantity::Real, order_type::Symbol=:market,
                    limit_price::Union{Real,Nothing}=nothing, tif::Symbol=:day,
                    account::String="", pool_id::String="",
                    signal_id=nothing, regime=nothing, solve_id=nothing)
    VenueOrder(client_order_id, symbol, side, float(quantity), order_type,
               limit_price === nothing ? nothing : float(limit_price),
               tif, account, pool_id, signal_id, regime, solve_id)
end

"""
    OrderAck

Result of a submission attempt. `status` is the source of truth (F2):

- `:accepted`  — the venue confirmed receipt; `venue_order_id` is set.
- `:rejected`  — the order was definitely **not** sent (pre-submit validation, or not
                 connected). Safe to retry (ideally with a new `client_order_id`).
- `:uncertain` — the send may have reached the broker but no confirmation was received
                 (exception/timeout mid-placeOrder). **Must not be blindly retried** —
                 the order could be live. The controller locks this `client_order_id`.

`client_order_id` is echoed so callers can correlate with their idempotency key.
"""
struct OrderAck
    status::Symbol
    venue_order_id::String
    client_order_id::String
    error::Union{String,Nothing}

    function OrderAck(status::Symbol, venue_order_id::String,
                     client_order_id::String, error::Union{String,Nothing})
        @assert status in (:accepted, :rejected, :uncertain) "status must be :accepted/:rejected/:uncertain, got $status"
        new(status, venue_order_id, client_order_id, error)
    end
end

"True iff the venue confirmed the order."
isaccepted(a::OrderAck) = a.status === :accepted

"""
True iff this `client_order_id` must not be resubmitted — either accepted (already
live) or uncertain (may be live). This is the idempotency-lock predicate (REQ-EXEC-002).
"""
islocked_id(a::OrderAck) = a.status === :accepted || a.status === :uncertain

# ── The interface every venue must implement (stubs error until a venue adds a method) ──

connect!(v::ExecutionVenue)::Bool =
    error("connect! not implemented for $(typeof(v))")
disconnect!(v::ExecutionVenue) =
    error("disconnect! not implemented for $(typeof(v))")
is_connected(v::ExecutionVenue)::Bool =
    error("is_connected not implemented for $(typeof(v))")
submit!(v::ExecutionVenue, ::VenueOrder)::OrderAck =
    error("submit! not implemented for $(typeof(v))")
cancel!(v::ExecutionVenue, venue_order_id::String)::Bool =
    error("cancel! not implemented for $(typeof(v))")
positions(v::ExecutionVenue, account::String)::Dict{String,Float64} =
    error("positions not implemented for $(typeof(v))")
