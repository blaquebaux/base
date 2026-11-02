# =============================================================================
# test_module_12.jl — Module 12 (smart order router, SORLayer) load + smoke test
# (PRE-02). Confirms the module loads and its public API is defined, with no
# network use (routing is exercised against the in-memory default venues).
# Deeper routing behaviour is a later task.
# =============================================================================
isdefined(Main, :SORLayer) || include("../src/module_12_sor/module_12_sor.jl")
using .SORLayer
using Test

@testset "Module 12: SORLayer loads" begin
    for s in (:Venue, :VenueQuote, :SORConfig, :RoutingCache, :SORResult,
              :route_order, :build_routing_cache, :update_venue_quote!)
        @test isdefined(SORLayer, s)
    end
    # DEFAULT_VENUES is an in-memory venue list (no network).
    @test !isempty(SORLayer.DEFAULT_VENUES)
end
