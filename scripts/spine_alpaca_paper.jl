#!/usr/bin/env julia
# ============================================================================
# spine_alpaca_paper.jl — run the Path-B spine LIVE ON ALPACA PAPER.
#
#   Alpaca data (AlpacaPanelProvider) → stateful spine (regime :dd) → signed share targets
#   → governed ExecutionController → Alpaca paper orders (AlpacaVenue) → SQLite ledger w/
#   lineage → reconcile. This is the real thing on paper — no IBKR, no approval gate.
#
# PREREQ (2-min, free, no approval): create an Alpaca account, generate PAPER API keys, then
#   export ALPACA_KEY_ID=...  ALPACA_SECRET_KEY=...
# Then:  julia --project=. scripts/spine_alpaca_paper.jl
#
# Paper only. Real money requires IBKRVenue/live AlpacaConfig(paper=false) AND the governed
# invariants green — do not flip that here.
# ============================================================================

using Dates, Serialization, Printf

const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_10_feedback/module_10_feedback.jl"))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
include(joinpath(REPO, "src/module_1_data/equity_panel.jl"))
include(joinpath(REPO, "src/module_1_data/alpaca_panel.jl"))
using .ExecutionLayer, .FeedbackLayer, .PortfolioOptModule, .EquityPanel, .AlpacaPanel
include(joinpath(REPO, "scripts/live_execution.jl"))

const UNIVERSE = ["SPY", "IEF", "TLT", "GLD", "DBC"]

function main(; universe = UNIVERSE, capital = 100_000.0, pool = "us", regime = :dd,
              state_path = joinpath(REPO, "spine_state_alpaca.jls"),
              db_path = joinpath(REPO, "alpaca_ledger.sqlite"),
              audit_path = joinpath(REPO, "alpaca_audit.jsonl"))
    if get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == ""
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY (free paper keys — alpaca.markets → Paper Trading → API keys).")
    end

    venue = AlpacaVenue(AlpacaConfig(; paper = true))
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = db_path), audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    try
        connect!(venue) || error("Alpaca connect failed — check keys / network (paper-api.alpaca.markets).")
        @info "Connected to Alpaca paper" universe

        reset_daily!(ctrl)
        set_pool_budget!(ctrl, pool, 3 * capital)
        set_pool_loss_limit!(ctrl, pool, capital)
        set_pool_staleness!(ctrl, pool, Day(5))
        feed_staleness!(ctrl, pool; stale = false)

        provider = AlpacaPanelProvider(universe; lookback = 252)
        panel = panel_at(provider)                              # trailing daily bars up to today
        @info "Panel pulled" asof=panel.asof bars=size(panel.returns, 1) symbols=panel.symbols

        state = isfile(state_path) ? deserialize(state_path)::SpineState :
                                     SpineState(length(universe); regime = regime)
        w = spine_step!(state, panel.returns)
        reg = regime_multiplier(panel.returns, :dd) < 1.0 ? "risk-off" : "normal"
        targets = spine_targets(w, panel.symbols, panel.prices, capital)
        prices = Dict(panel.symbols[i] => panel.prices[i] for i in eachindex(panel.symbols))

        @info "Spine targets" regime=reg targets=Dict(k => round(Int, v) for (k, v) in targets)
        res = execute_rebalance!(ctrl, ledger; targets = targets, prices = prices,
            signal_id = "spine", regime = reg, solve_id = Dates.format(panel.asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 5)          # give paper fills a moment to come back
        serialize(state_path, state)

        @info "Rebalance complete" orders=length(res.acks) fills=length(res.fills) reconciled=res.reconciled
        for a in res.acks
            @printf("  %-6s status=%-9s id=%s %s\n", "order", string(a.status), a.venue_order_id,
                    a.error === nothing ? "" : "err=$(a.error)")
        end
        total = sum(length(query_fills(ledger, s)) for s in universe)
        @info "Ledger fills (this account, with lineage)" total
    finally
        disconnect!(venue)
        close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
