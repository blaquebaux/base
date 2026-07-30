module TestAlpacaVenue

# Offline unit tests for AlpacaVenue (src/module_7_execution/venues/alpaca.jl). Network calls
# need live keys, so these cover the parts that DON'T hit the wire: type contract, missing-key
# guards (no silent proceed), the whole-share policy, and base-URL selection. The live paths
# (submit/positions/drain) are exercised in the Alpaca paper smoke run once keys exist.

using Test, Dates

include("../src/module_7_execution/module_7_execution.jl")
using .ExecutionLayer

@testset "AlpacaVenue — offline guards & contract" begin
    v = AlpacaVenue(AlpacaConfig(; key_id = "", secret = "", paper = true))
    @test v isa ExecutionVenue
    @test connect!(v) == false                       # no keys → not connected (no network)
    @test is_connected(v) == false
    @test isempty(positions(v, "acct"))
    @test isempty(drain_fills(v))

    o = VenueOrder(; client_order_id = "us|SPY|20260101", symbol = "SPY", side = :buy,
                   quantity = 10, ref_price = 100.0, pool_id = "us")
    a = submit!(v, o)
    @test a.status == :rejected
    @test occursin("keys", a.error)
    @test a.client_order_id == "us|SPY|20260101"     # idempotency key echoed even on reject

    # Whole-share policy: fractional rejected BEFORE any network call (keys present here).
    vk = AlpacaVenue(AlpacaConfig(; key_id = "k", secret = "s"))
    of = VenueOrder(; client_order_id = "us|SPY|frac", symbol = "SPY", side = :buy,
                    quantity = 1.5, pool_id = "us")
    rf = submit!(vk, of)
    @test rf.status == :rejected
    @test occursin("whole shares", rf.error)

    # Paper vs live base URL selection.
    @test occursin("paper-api.alpaca.markets", AlpacaConfig(; paper = true).base_url)
    @test occursin("//api.alpaca.markets", AlpacaConfig(; paper = false).base_url)

    # cancel_all_open! is a no-op (0, no network) without keys.
    @test cancel_all_open!(AlpacaVenue(AlpacaConfig(; key_id = "", secret = ""))) == 0
end

end # module
