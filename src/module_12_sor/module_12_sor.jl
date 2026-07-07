module SORLayer
include("smart_order_router.jl")
using .SmartOrderRouter
export SmartOrderRouter
export Venue, VenueQuote, SORConfig, RoutingCache, SORResult, SORDecision,
       update_venue_quote!, build_routing_cache, route_order,
       should_recompute_cache
const DEFAULT_VENUES = SmartOrderRouter.DEFAULT_VENUES
end
