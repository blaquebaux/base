module TestSpinePipeline

# Integration test: the WHOLE Path-B pipeline on cached data —
#   CSV panel → stateful spine (regime :dd) → signed share targets → governed
#   ExecutionController → simulated fills → real SQLite ledger w/ lineage → reconcile.
# Guards that data → spine → governed orders → ledger stays wired end-to-end. Reuses the
# driver in scripts/spine_end_to_end.jl (SimVenue + the real modules); the ONLY thing not
# exercised here is the live IBKR data/venue swap.

using Test

include("../scripts/spine_end_to_end.jl")   # defines main(...), SimVenue, and loads the modules

@testset "spine end-to-end pipeline (cached → governed → ledger)" begin
    res = main(; n_rebalances = 6, verbose = false)

    @test length(res.rebalances) == 6
    @test all(r -> r.reconciled, res.rebalances)            # every trading day reconciles vs the venue
    @test all(r -> r.accepted >= 1, res.rebalances)         # the spine emits governed orders
    @test all(r -> r.orders == r.accepted, res.rebalances)  # none rejected (budget reset per day)
    @test all(r -> r.fills == r.accepted, res.rebalances)   # every accepted order fills
    @test all(r -> r.gross > 0, res.rebalances)             # a real book is deployed

    @test res.ledger_fills >= 6                             # fills persisted to the ledger

    # AUDIT-001: recorded fills carry full decision lineage.
    s = res.sample
    @test s !== nothing
    @test s.signal_id == "spine"
    @test !isempty(s.regime) && !isempty(s.solve_id) && !isempty(s.order_id)
    @test s.signed_qty != 0.0
end

end # module
