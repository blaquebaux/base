# ============================================================================
# IBKR VENUE ADAPTER — IBKRVenue <: ExecutionVenue
# ----------------------------------------------------------------------------
# Thin adapter: translates a canonical VenueOrder to Jib.jl Contract/Order and
# delegates connection/session management to ibkr_connection.jl. Carries NO
# safety logic — that lives in ExecutionController (built once, all venues share).
#
# Requires (included earlier in ExecutionLayer): venue_interface.jl, ibkr_connection.jl
# ============================================================================

"""
    IBKRVenue(; kwargs...) <: ExecutionVenue

Interactive Brokers execution venue over Jib.jl / TWS-Gateway.
Defaults to the PAPER port (7497). Live requires an explicit config change —
and the governed invariants must be green first (see HONEST-ASSESSMENT.md).
"""
struct IBKRVenue <: ExecutionVenue
    config::IBKRConfig
end
IBKRVenue(; kwargs...) = IBKRVenue(IBKRConfig(; kwargs...))

connect!(v::IBKRVenue)::Bool          = connect_ibkr(v.config)
disconnect!(::IBKRVenue)              = disconnect_ibkr()
is_connected(::IBKRVenue)::Bool       = get_ibkr_connection().is_connected
positions(::IBKRVenue, account::String)::Dict{String,Float64} = ibkr_get_positions(account)

# US equities to start: STK/SMART/USD. Other asset classes (futures, options,
# non-US equities) extend this translation when their pools go live.
function submit!(v::IBKRVenue, o::VenueOrder)::OrderAck
    ok, oid, err = reserve_and_place() do assigned_oid
        contract = Jib.Contract()
        contract.symbol   = o.symbol
        contract.secType  = "STK"
        contract.exchange = get(ENV, "IBKR_EXCHANGE", "SMART")
        contract.currency = "USD"

        jib = Jib.Order()
        jib.orderId       = assigned_oid
        jib.action        = o.side === :buy ? "BUY" : "SELL"
        jib.totalQuantity = o.quantity
        jib.orderType     = o.order_type === :limit ? "LMT" : "MKT"
        jib.tif           = uppercase(String(o.tif))
        if o.order_type === :limit && o.limit_price !== nothing
            jib.lmtPrice = o.limit_price
        end
        isempty(o.account) || (jib.account = o.account)
        (contract, jib)
    end
    return OrderAck(ok, ok ? oid : "", o.client_order_id, err)
end

function cancel!(::IBKRVenue, venue_order_id::String)::Bool
    ibkr = get_ibkr_connection()
    ibkr.is_connected || return false
    lock(ibkr._lock) do
        try
            Jib.Requests.cancelOrder(ibkr.conn, parse(Int, venue_order_id))
            return true
        catch e
            @warn "cancel! failed" venue_order_id=venue_order_id exception=e
            return false
        end
    end
end
