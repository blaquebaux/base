module TestLiveIntegration

# Integration test for scripts/live_execution.jl: mock venue + a REAL SQLite ledger in a
# temp dir. Verifies the governed rebalance loop end-to-end — submit → drain+record fills
# (with lineage) → reconcile → audit sink. Needs Jib (ExecutionLayer) + SQLite (FeedbackLayer);
# heavier than the Jib-free controller unit test, appropriately (it's an integration test).

using Test, Dates

include("../src/module_7_execution/module_7_execution.jl"); using .ExecutionLayer
include("../src/module_10_feedback/module_10_feedback.jl"); using .FeedbackLayer
include("../scripts/live_execution.jl")

mutable struct MockVenue <: ExecutionVenue
    submits::Int
    fills::Vector{NamedTuple}
    posns::Dict{String,Float64}
    _lk::ReentrantLock
end
MockVenue() = MockVenue(0, NamedTuple[], Dict{String,Float64}(), ReentrantLock())
ExecutionLayer.connect!(::MockVenue) = true
ExecutionLayer.disconnect!(::MockVenue) = nothing
ExecutionLayer.is_connected(::MockVenue) = true
function ExecutionLayer.submit!(v::MockVenue, o::VenueOrder)
    oid = lock(v._lk) do; v.submits += 1; "OID$(v.submits)" end
    OrderAck(:accepted, oid, o.client_order_id, nothing)
end
ExecutionLayer.positions(v::MockVenue, ::String) = lock(() -> copy(v.posns), v._lk)
ExecutionLayer.drain_fills(v::MockVenue) = lock(v._lk) do; fs = copy(v.fills); empty!(v.fills); fs end

@testset "live integration (mock venue + real ledger)" begin
    tmp = mktempdir()
    audit_path = joinpath(tmp, "audit.jsonl")
    venue = MockVenue()
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = joinpath(tmp, "ledger.sqlite")),
        audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    set_pool_budget!(ctrl, "us", 1_000_000.0)
    set_pool_staleness!(ctrl, "us", Second(60))
    feed_staleness!(ctrl, "us"; stale = false)

    # Rebalance to +10 AAPL; simulate the broker fill + position for the buy.
    venue.fills = [(symbol="AAPL", order_id="OID1", exec_id="EX1", fill_price=100.0, shares=10, side="BOT", timestamp=now(UTC))]
    venue.posns = Dict("AAPL" => 10.0)
    res = execute_rebalance!(ctrl, ledger;
        targets = Dict("AAPL" => 10.0), prices = Dict("AAPL" => 100.0),
        signal_id = "sig1", regime = "calm", solve_id = "solveA", pool_id = "us", settle_secs = 0)

    @test length(res.acks) == 1 && res.acks[1].status == :accepted
    @test res.reconciled == true
    @test ctrl.expected["AAPL"] == 10.0

    # Ledger recorded the fill WITH full lineage (AUDIT-001), fill_id from execId.
    recorded = query_fills(ledger, "AAPL")
    @test length(recorded) == 1
    @test recorded[1].signal_id == "sig1" && recorded[1].regime == "calm" && recorded[1].solve_id == "solveA"
    @test recorded[1].order_id == "OID1" && recorded[1].fill_id == "EX1"
    @test recorded[1].signed_qty == 10.0

    # Already at target → no new orders, no re-submit.
    venue.fills = NamedTuple[]
    res2 = execute_rebalance!(ctrl, ledger;
        targets = Dict("AAPL" => 10.0), prices = Dict("AAPL" => 100.0),
        signal_id = "sig1", regime = "calm", solve_id = "solveB", pool_id = "us", settle_secs = 0)
    @test isempty(res2.acks)           # delta 0 → nothing emitted
    @test venue.submits == 1

    # Audit sink persists a halt event (GOV-002).
    halt!(ctrl, "integration test halt")
    @test isfile(audit_path)
    @test occursin("halt", read(audit_path, String))

    close_ledger(ledger)
end

end  # module
