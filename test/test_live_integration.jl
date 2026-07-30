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

@testset "emergency flatten bypasses halt (L1)" begin
    tmp = mktempdir()
    venue = MockVenue()
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = joinpath(tmp, "l.sqlite")),
        audit_path = joinpath(tmp, "a.jsonl"))
    ctrl, ledger = built.ctrl, built.ledger
    set_pool_budget!(ctrl, "us", 1_000_000.0)

    # Establish +10 AAPL.
    venue.fills = [(symbol="AAPL", order_id="OID1", exec_id="EX1", fill_price=100.0, shares=10, side="BOT", timestamp=now(UTC))]
    venue.posns = Dict("AAPL" => 10.0)
    execute_rebalance!(ctrl, ledger; targets = Dict("AAPL" => 10.0), prices = Dict("AAPL" => 100.0),
        signal_id = "s", regime = "calm", solve_id = "A", pool_id = "us", settle_secs = 0)
    @test expected_position(ctrl, "AAPL") == 10.0

    # Emergency: halt, then flatten. Liquidation must succeed DESPITE the halt.
    halt!(ctrl, "emergency")
    @test ctrl.halted == true
    venue.fills = [(symbol="AAPL", order_id="OID2", exec_id="EX2", fill_price=99.0, shares=10, side="SLD", timestamp=now(UTC))]
    venue.posns = Dict("AAPL" => 0.0)
    liq = flatten!(ctrl, ledger; signal_id = "emergency", regime = "calm", solve_id = "A", settle_secs = 0)
    @test length(liq) == 1 && liq[1].status == :accepted     # accepted despite the halt (bypass)
    @test expected_position(ctrl, "AAPL") == 0.0             # book flattened

    # A NORMAL order is still blocked by the halt.
    normal = submit_governed!(ctrl, VenueOrder(; client_order_id = "n1", symbol = "MSFT", side = :buy,
                 quantity = 1, order_type = :market, ref_price = 100.0, pool_id = "us",
                 signal_id = "s", regime = "calm", solve_id = "A"))
    @test normal.status == :rejected
    close_ledger(ledger)
end

@testset "staleness gate blocks emission (feed_staleness stale=true)" begin
    tmp = mktempdir()
    venue = MockVenue()
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = joinpath(tmp, "l.sqlite")),
        audit_path = joinpath(tmp, "a.jsonl"))
    ctrl, ledger = built.ctrl, built.ledger
    set_pool_budget!(ctrl, "us", 1_000_000.0)
    set_pool_staleness!(ctrl, "us", Second(60))
    feed_staleness!(ctrl, "us"; stale = true)   # NOT marked fresh → stale
    res = execute_rebalance!(ctrl, ledger; targets = Dict("AAPL" => 10.0), prices = Dict("AAPL" => 100.0),
        signal_id = "s", regime = "calm", solve_id = "A", pool_id = "us", settle_secs = 0)
    @test !isempty(res.acks) && all(a -> a.status == :rejected, res.acks)
    @test occursin("DATA-003", res.acks[1].error)
    close_ledger(ledger)
end

@testset "seed expected from broker → rebalance trades the DELTA, no stacking" begin
    tmp = mktempdir()
    venue = MockVenue()
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = joinpath(tmp, "l.sqlite")),
        audit_path = joinpath(tmp, "a.jsonl"))
    ctrl, ledger = built.ctrl, built.ledger
    set_pool_budget!(ctrl, "us", 1_000_000.0)
    set_pool_staleness!(ctrl, "us", Second(60)); feed_staleness!(ctrl, "us"; stale = false)

    # Broker already holds 10 AAPL from a prior day; a fresh controller seeds expected from it.
    venue.posns = Dict("AAPL" => 10.0)
    for (s, q) in ExecutionLayer.positions(venue, ""); apply_fill!(ctrl, s, q) end
    @test expected_position(ctrl, "AAPL") == 10.0

    # Target == current holding ⇒ delta 0 ⇒ NO order (the fix: without seeding it would
    # re-place the full 10 on top of the existing 10).
    res = execute_rebalance!(ctrl, ledger; targets = Dict("AAPL" => 10.0),
        prices = Dict("AAPL" => 100.0), signal_id = "s", regime = "calm",
        solve_id = "D2", pool_id = "us", settle_secs = 0)
    @test isempty(res.acks)
    @test venue.submits == 0

    # Target 15 ⇒ only the +5 delta is ordered.
    venue.fills = [(symbol="AAPL", order_id="OID1", exec_id="EX1", fill_price=100.0, shares=5, side="BOT", timestamp=now(UTC))]
    venue.posns = Dict("AAPL" => 15.0)
    res2 = execute_rebalance!(ctrl, ledger; targets = Dict("AAPL" => 15.0),
        prices = Dict("AAPL" => 100.0), signal_id = "s", regime = "calm",
        solve_id = "D2b", pool_id = "us", settle_secs = 0)
    @test length(res2.acks) == 1 && res2.acks[1].status == :accepted
    @test venue.submits == 1
    @test expected_position(ctrl, "AAPL") == 15.0 && res2.reconciled == true

    close_ledger(ledger)
end

end  # module
