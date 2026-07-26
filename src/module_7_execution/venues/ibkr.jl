# ============================================================================
# IBKR VENUE ADAPTER — IBKRVenue <: ExecutionVenue
# ----------------------------------------------------------------------------
# Thin adapter: translates a canonical VenueOrder to Jib.jl and delegates
# connection/session management to an IBKRConnection it OWNS (no global
# singleton). Carries NO safety logic — that lives in ExecutionController.
#
# Requires (included earlier in ExecutionLayer): venue_interface.jl, ibkr_connection.jl
# ============================================================================

"""
    IBKRVenue(; kwargs...) <: ExecutionVenue

Interactive Brokers execution venue over Jib.jl / TWS-Gateway. Owns its
`IBKRConnection`. Defaults to the PAPER port (7497). Going live requires an
explicit config change AND the governed invariants green (see HONEST-ASSESSMENT.md).
"""
struct IBKRVenue <: ExecutionVenue
    conn::IBKRConnection
end
IBKRVenue(conn_config::IBKRConfig) = IBKRVenue(IBKRConnection(conn_config))
IBKRVenue(; kwargs...) = IBKRVenue(IBKRConnection(IBKRConfig(; kwargs...)))

connect!(v::IBKRVenue)::Bool                     = connect_ibkr(v.conn)
disconnect!(v::IBKRVenue)                        = disconnect_ibkr(v.conn)
is_connected(v::IBKRVenue)::Bool                 = v.conn.is_connected
positions(v::IBKRVenue, account::String)::Dict{String,Float64} = ibkr_get_positions(v.conn, account)

# US equities to start: STK/SMART/USD. Other asset classes extend this translation
# when their pools go live.
function submit!(v::IBKRVenue, o::VenueOrder)::OrderAck
    # #5 — US equities are whole shares. Reject fractional rather than silently
    # rounding (rounding would change the order size). Fractional support is an
    # explicit future flag, not an accident.
    if o.quantity != round(o.quantity)
        return OrderAck(false, "", o.client_order_id,
                        "IBKR STK requires whole shares; got quantity=$(o.quantity)")
    end

    ok, oid, err = reserve_and_place(v.conn) do assigned_oid
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

function cancel!(v::IBKRVenue, venue_order_id::String)::Bool
    v.conn.is_connected || return false
    lock(v.conn._lock) do
        try
            Jib.Requests.cancelOrder(v.conn.conn, parse(Int, venue_order_id))
            return true
        catch e
            @warn "cancel! failed" venue_order_id=venue_order_id exception=e
            return false
        end
    end
end
