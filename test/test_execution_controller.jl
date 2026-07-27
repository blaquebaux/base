module TestExecutionController

# Venue-agnostic execution controller tests. Self-contained and Jib-FREE: includes only the
# venue interface + controller and drives them with a MockVenue, so this runs with no TWS /
# IB Gateway. The IBKR adapter itself (Jib calls) is verified separately against a paper
# Gateway (#4). Covers EXEC-001/002/003, AUDIT-001/002, RISK-003/004, DATA-003, GOV-002,
# plus the review fixes (F2/G1/G3, H1, I1/I2/J2) and a concurrency stress test for I2.

using Test, Dates

include("../src/module_7_execution/venue_interface.jl")
include("../src/module_7_execution/execution_controller.jl")

# ── Mock venue ─────────────────────────────────────────────────────────────────
mutable struct MockVenue <: ExecutionVenue
    next_status::Symbol
    submits::Int
    fills::Vector{NamedTuple}
    posns::Dict{String,Float64}
    yield_in_submit::Bool
    _lk::ReentrantLock
end
MockVenue() = MockVenue(:accepted, 0, NamedTuple[], Dict{String,Float64}(), false, ReentrantLock())

connect!(::MockVenue) = true
disconnect!(::MockVenue) = nothing
is_connected(::MockVenue) = true
function submit!(v::MockVenue, o::VenueOrder)
    v.yield_in_submit && yield()   # simulate the network await point (interleaves coroutines)
    oid = lock(v._lk) do
        v.submits += 1
        "OID$(v.submits)"
    end
    OrderAck(v.next_status, v.next_status === :rejected ? "" : oid, o.client_order_id,
             v.next_status === :accepted ? nothing : "note")
end
positions(v::MockVenue, ::String) = lock(() -> copy(v.posns), v._lk)
drain_fills(v::MockVenue) = lock(v._lk) do
    fs = copy(v.fills); empty!(v.fills); fs
end

ord(; cid, sym="AAPL", side=:buy, qty=10, pool="us", sig="s1", reg="calm", solve="q1",
      price=nothing, ot=:market) =
    VenueOrder(; client_order_id=cid, symbol=sym, side=side, quantity=qty, order_type=ot,
               limit_price=ot===:limit ? price : nothing, ref_price=price, pool_id=pool,
               signal_id=sig, regime=reg, solve_id=solve)

@testset "ExecutionController (venue-agnostic, mock venue)" begin

    @testset "REQ-EXEC-002 idempotency" begin
        v = MockVenue(); c = ExecutionController(v)
        a1 = submit_governed!(c, ord(cid="c1"))
        a2 = submit_governed!(c, ord(cid="c1"))
        @test isaccepted(a1)
        @test a2.venue_order_id == a1.venue_order_id
        @test v.submits == 1                         # replay did not re-submit
    end

    @testset "F2/G1 uncertain locks the id and keeps its oid" begin
        v = MockVenue(); v.next_status = :uncertain; c = ExecutionController(v)
        a1 = submit_governed!(c, ord(cid="u1"))
        @test a1.status == :uncertain
        @test !isempty(a1.venue_order_id)            # G1
        submit_governed!(c, ord(cid="u1"))
        @test v.submits == 1                         # uncertain retry did not re-submit
    end

    @testset "REQ-AUDIT-002 lineage gate" begin
        v = MockVenue(); c = ExecutionController(v)
        bad = VenueOrder(; client_order_id="b1", symbol="AAPL", side=:buy, quantity=10,
                         pool_id="us", signal_id=nothing, regime="calm", solve_id="q1")
        a = submit_governed!(c, bad)
        @test a.status == :rejected && occursin("AUDIT-002", a.error)
        @test v.submits == 0
    end

    @testset "REQ-RISK-003 budget gate + reservation rollback" begin
        v = MockVenue(); c = ExecutionController(v); set_pool_budget!(c, "us", 1000.0)
        @test submit_governed!(c, ord(cid="g1", qty=5, price=100.0)).status == :accepted      # 500
        @test submit_governed!(c, ord(cid="g2", sym="MSFT", qty=6, price=100.0)).status == :rejected  # 500+600>1000
        v.next_status = :rejected
        submit_governed!(c, ord(cid="g3", sym="NVDA", qty=1, price=100.0))                    # venue-rejected → rollback
        v.next_status = :accepted
        @test submit_governed!(c, ord(cid="g4", sym="TSLA", qty=4, price=100.0)).status == :accepted  # 900 ok (g3 rolled back)
    end

    @testset "REQ-RISK-003 budget with no price rejects" begin
        v = MockVenue(); c = ExecutionController(v); set_pool_budget!(c, "us", 1000.0)
        @test submit_governed!(c, ord(cid="np", price=nothing)).status == :rejected
    end

    @testset "REQ-DATA-003 staleness gate" begin
        v = MockVenue(); c = ExecutionController(v); set_pool_staleness!(c, "us", Second(5))
        @test submit_governed!(c, ord(cid="s1")).status == :rejected     # never marked = stale
        mark_data_fresh!(c, "us")
        @test submit_governed!(c, ord(cid="s2")).status == :accepted
        mark_data_fresh!(c, "us"; ts = now(UTC) - Second(60))
        @test submit_governed!(c, ord(cid="s3")).status == :rejected     # stale again
    end

    @testset "REQ-RISK-004 loss halt + per-pool isolation + resume" begin
        v = MockVenue(); c = ExecutionController(v); set_pool_loss_limit!(c, "us", 1000.0)
        @test submit_governed!(c, ord(cid="l1")).status == :accepted
        update_pnl!(c, "us", -1500.0)
        @test submit_governed!(c, ord(cid="l2", sym="MSFT")).status == :rejected
        @test submit_governed!(c, ord(cid="l3", sym="GOOG", pool="emea")).status == :accepted  # other pool ok
        resume_pool!(c, "us")
        @test submit_governed!(c, ord(cid="l4", sym="AMZN")).status == :accepted
    end

    @testset "REQ-GOV-002 kill switch + I1 audit robustness" begin
        events = NamedTuple[]
        v = MockVenue(); c = ExecutionController(v; audit = e -> push!(events, e))
        halt!(c, "manual")
        @test submit_governed!(c, ord(cid="k1")).status == :rejected
        @test any(e -> e.event == :halt, events)
        resume!(c)
        @test submit_governed!(c, ord(cid="k2")).status == :accepted
        set_audit_sink!(c, e -> error("sink down"))
        @test (halt!(c, "stress"); true)             # I1: throwing sink does not break halt
        @test c.halted == true
    end

    @testset "H1 disjoint-symbol guard + J2 rebind override" begin
        v = MockVenue(); c = ExecutionController(v)
        @test submit_governed!(c, ord(cid="d1", sym="AAPL", pool="us")).status == :accepted
        @test submit_governed!(c, ord(cid="d2", sym="AAPL", pool="emea")).status == :rejected
        rebind_symbol!(c, "AAPL", "emea")            # J2: admin correction
        @test submit_governed!(c, ord(cid="d3", sym="AAPL", pool="emea")).status == :accepted
    end

    @testset "REQ-EXEC-003 reconcile per-pool + F1 fill-driven expected" begin
        v = MockVenue(); c = ExecutionController(v)
        submit_governed!(c, ord(cid="r1", sym="AAPL", pool="us"))
        v.fills = [(symbol="AAPL", order_id="OID1", fill_price=100.0, shares=10, side="BOT", timestamp=now(UTC))]
        process_fills!(c)
        v.posns = Dict("AAPL" => 10.0)
        @test reconcile!(c) == true
        v.posns = Dict("AAPL" => 7.0)
        @test reconcile!(c) == false
        @test haskey(c.halted_pools, "us")           # scoped to the right pool
    end

    @testset "G3 record-then-apply fail-safe" begin
        v = MockVenue(); c = ExecutionController(v)
        submit_governed!(c, ord(cid="g3a", sym="AAPL", pool="us"))
        v.fills = [(symbol="AAPL", order_id="OID1", fill_price=100.0, shares=10, side="BOT", timestamp=now(UTC))]
        processed = process_fills!(c; record = _ -> error("ledger down"))
        @test isempty(processed)                      # record threw → fill not counted as processed
        @test get(c.expected, "AAPL", 0.0) == 0.0     # expected NOT updated on record failure
        v.posns = Dict("AAPL" => 10.0)                # broker has the (unrecorded) fill
        @test reconcile!(c) == false                  # G3: the loss surfaces as a divergence/halt
        @test haskey(c.halted_pools, "us")
    end

    @testset "G2 rehydrate restores seen (no re-submit) and lineage (tags fills)" begin
        v = MockVenue(); c = ExecutionController(v)
        rehydrate!(c;
            seen    = Dict("cid9" => OrderAck(:accepted, "OID9", "cid9", nothing)),
            lineage = Dict("OID9" => (signal_id="s9", regime="r9", solve_id="q9", client_order_id="cid9")))
        a = submit_governed!(c, ord(cid="cid9"))
        @test a.venue_order_id == "OID9" && v.submits == 0   # rehydrated seen → replay, no re-submit
        v.fills = [(symbol="AAPL", order_id="OID9", fill_price=100.0, shares=5, side="BOT", timestamp=now(UTC))]
        p = process_fills!(c)
        @test p[1].signal_id == "s9"                  # rehydrated lineage tagged the fill (G2/AUDIT-001)
    end

    @testset "reset_daily! clears turnover but keeps halts" begin
        v = MockVenue(); c = ExecutionController(v); set_pool_budget!(c, "us", 200.0)
        @test submit_governed!(c, ord(cid="rd1", qty=2, price=100.0)).status == :accepted   # uses 200
        @test submit_governed!(c, ord(cid="rd2", sym="MSFT", qty=1, price=100.0)).status == :rejected  # over budget
        halt_pool!(c, "us", "manual")
        reset_daily!(c)
        @test get(c.pool_used, "us", 0.0) == 0.0      # turnover cleared
        @test haskey(c.halted_pools, "us")            # halt NOT auto-lifted
        @test occursin("halted", submit_governed!(c, ord(cid="rd3", sym="GOOG", qty=1, price=100.0)).error)
        resume_pool!(c, "us")
        @test submit_governed!(c, ord(cid="rd4", sym="AMZN", qty=1, price=100.0)).status == :accepted  # budget freed
    end

    @testset "K4 misc: process_and_reconcile!, multi-fill, non-breach PnL" begin
        v = MockVenue(); c = ExecutionController(v)
        submit_governed!(c, ord(cid="pr1", sym="AAPL"))
        v.fills = [(symbol="AAPL", order_id="OID1", fill_price=100.0, shares=10, side="BOT", timestamp=now(UTC))]
        v.posns = Dict("AAPL" => 10.0)
        @test process_and_reconcile!(c) == true       # applies fills then reconciles → match

        v2 = MockVenue(); c2 = ExecutionController(v2)
        submit_governed!(c2, ord(cid="mf1", sym="AAPL"))
        v2.fills = [(symbol="AAPL", order_id="OID1", fill_price=100.0, shares=6, side="BOT", timestamp=now(UTC)),
                    (symbol="AAPL", order_id="OID1", fill_price=100.0, shares=4, side="BOT", timestamp=now(UTC))]
        process_fills!(c2)
        @test c2.expected["AAPL"] == 10.0             # multiple/partial fills accumulate

        v3 = MockVenue(); c3 = ExecutionController(v3); set_pool_loss_limit!(c3, "us", 1000.0)
        update_pnl!(c3, "us", -500.0)                 # within limit → no halt
        @test !haskey(c3.halted_pools, "us")
        @test submit_governed!(c3, ord(cid="nb1")).status == :accepted
    end

    @testset "I2 concurrency: exact budget fill, no over/under-commit (looped)" begin
        # Budget 1000 / notional 100 → EXACTLY 10 accepted, 40 rejected. Looping gives a rare
        # race real chances to manifest; == (not <=) also catches spurious under-acceptance.
        for iter in 1:100
            v = MockVenue(); v.yield_in_submit = true
            c = ExecutionController(v); set_pool_budget!(c, "us", 1000.0)
            @sync for i in 1:50
                Threads.@spawn submit_governed!(c, ord(cid="cc$(iter)_$i", sym="S$i", qty=1, price=100.0))
            end
            @test get(c.pool_used, "us", 0.0) == 1000.0   # fully + exactly utilized
            @test length(c.seen) == 10                     # exact budget-fitting count (no over/under)
            @test length(c.lineage) == 10
        end
    end
end

end  # module
