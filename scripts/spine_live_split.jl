#!/usr/bin/env julia
# ============================================================================
# spine_live_split.jl — PRODUCTION driver for the SPLIT-UNIVERSE spine.
#
# Identical governance to spine_live.jl (Layer-3 safety gate → governed orders →
# reconcile), but the strategy is the split-universe spine: the long-only base
# sleeve runs on 6 risk-premium asset-class ETFs; the long/short trend sleeve runs
# on a broader 11-market CTA set (FX + single-commodity complexes). Validated
# 2016-2026: Sharpe 1.04→1.07, lower vol/drawdown vs the single-universe +DBA spine
# (docs/CANONICAL_ARCHITECTURE.md, "Split-universe spine").
#
# Runs against its OWN state file (spine_state_split.jls) and does NOT touch the
# single-universe production state — so you can paper-run this alongside/instead of
# spine_live.jl, then repoint the launchd wrapper here when you're satisfied.
#
# PAPER by default; real money requires:  export BB_LIVE_CONFIRM=I_UNDERSTAND_THIS_IS_REAL_MONEY
# ============================================================================
using Dates, Serialization, Printf

const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_10_feedback/module_10_feedback.jl"))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
include(joinpath(REPO, "src/module_1_data/equity_panel.jl"))
include(joinpath(REPO, "src/module_1_data/alpaca_panel.jl"))
include(joinpath(REPO, "src/module_8_governance/safety_gate.jl"))
using .ExecutionLayer, .FeedbackLayer, .PortfolioOptModule, .EquityPanel, .AlpacaPanel, .SafetyGate
include(joinpath(REPO, "scripts/live_execution.jl"))

# Base = risk-premium assets (long-only harvest). Trend = broad CTA markets (long/short).
const SPLIT_BASE   = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const SPLIT_TREND  = ["SPY", "IEF", "TLT", "GLD", "DBA", "DBB", "DBE", "SLV", "UUP", "FXE", "FXY"]
const SPLIT_UNION  = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA", "DBB", "DBE", "SLV", "UUP", "FXE", "FXY"]
const LIVE_SENTINEL = "I_UNDERSTAND_THIS_IS_REAL_MONEY"

_readf(p) = isfile(p) ? (v = tryparse(Float64, strip(read(p, String))); v === nothing ? NaN : v) : NaN
_writef(p, x) = (mkpath(dirname(p)); write(p, string(x)))

function main(; capital = 100_000.0, pool = "us", regime = :dd, base_weight = 0.5,
              limits::SafetyLimits = SafetyLimits(),
              state_path = joinpath(REPO, "spine_state_split.jls"),
              db_path = joinpath(REPO, "alpaca_ledger.sqlite"),
              audit_path = joinpath(REPO, "alpaca_audit.jsonl"))

    if get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == ""
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY.")
    end
    live  = get(ENV, "BB_LIVE_CONFIRM", "") == LIVE_SENTINEL
    paper = !live
    mode  = live ? "*** LIVE REAL MONEY ***" : "paper"
    @info "spine_live_split starting" mode
    live && alert("LIVE REAL-MONEY mode engaged (split-universe)"; level = :critical)

    venue = AlpacaVenue(AlpacaConfig(; paper = paper))
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = db_path), audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    try
        if !connect!(venue)
            alert("ABORT [$mode]: Alpaca connect failed"; level = :critical); return :connect_failed
        end
        acct = account_info(venue)
        if acct === nothing
            alert("ABORT [$mode]: could not read account"; level = :critical); return :no_account
        end

        hwm      = max(load_hwm(), acct.equity)
        last_eq  = _readf(default_equity_path())
        panel    = panel_at(AlpacaPanelProvider(SPLIT_UNION; lookback = 252))
        fresh    = (Dates.today() - panel.asof) <= Day(5)

        bi, ti   = split_indices(panel.symbols, SPLIT_BASE, SPLIT_TREND)
        state    = isfile(state_path) ? deserialize(state_path)::SplitSpineState :
                                        SplitSpineState(bi, ti; base_weight = base_weight, regime = regime)
        # Self-healing guard: if either sub-universe changed, migrate but preserve the vol levels.
        if state.base_idx != bi || state.trend_idx != ti
            @warn "split universe changed; migrating vol-state (levels preserved, indices reset)"
            m = SplitSpineState(bi, ti; base_weight = base_weight, regime = regime)
            m.base_s2, m.trend_s2, m.n = state.base_s2, state.trend_s2, state.n
            state = m
        end
        w        = split_spine_step!(state, panel.returns)
        reg      = regime_multiplier(panel.returns[:, bi], :dd) < 1.0 ? "risk-off" : "normal"
        targets  = spine_targets(w, panel.symbols, panel.prices, capital)
        prices   = Dict(panel.symbols[i] => panel.prices[i] for i in eachindex(panel.symbols))

        # ── THE GATE ─────────────────────────────────────────────────────────────
        ok, reasons = preflight(; account_status = acct.status, trading_blocked = acct.trading_blocked,
            account_blocked = acct.account_blocked, equity = acct.equity, hwm = hwm,
            last_equity = last_eq, buying_power = acct.buying_power, data_fresh = fresh,
            targets = targets, prices = prices, limits = limits)

        save_hwm(hwm); _writef(default_equity_path(), acct.equity)

        if !ok
            msg = "SAFETY ABORT [$mode]: " * join(reasons, "; ")
            @error msg
            halt!(ctrl, "safety gate"); alert(msg; level = :critical)
            return :aborted
        end

        # ── safe to trade ────────────────────────────────────────────────────────
        reset_daily!(ctrl)
        set_pool_budget!(ctrl, pool, limits.max_gross_leverage * acct.equity)
        set_pool_loss_limit!(ctrl, pool, limits.max_daily_loss)
        set_pool_staleness!(ctrl, pool, Day(5))
        feed_staleness!(ctrl, pool; stale = !fresh)
        isfinite(last_eq) && update_pnl!(ctrl, pool, acct.equity - last_eq)

        ncanc = cancel_all_open!(venue); @info "cancelled stale orders" count=ncanc
        ncanc > 0 && sleep(2)

        # Delta-rebalance: seed expected from the broker's ACTUAL holdings first.
        bpos = positions(venue, ctrl.account)
        for (sym, qty) in bpos
            apply_fill!(ctrl, sym, qty)
        end
        @info "seeded expected positions from broker" held=length(bpos)

        res = execute_rebalance!(ctrl, ledger; targets = targets, prices = prices,
            signal_id = "spine_split", regime = reg, solve_id = Dates.format(panel.asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 20)
        serialize(state_path, state)

        if !res.reconciled
            alert("RECONCILE FAILED [$mode] — halting; book may not match broker"; level = :critical)
            halt!(ctrl, "reconcile mismatch")
        end

        summary = "[$mode] split $(reg); orders=$(length(res.acks)) fills=$(length(res.fills)) " *
                  "reconciled=$(res.reconciled); equity=$(round(Int, acct.equity)) " *
                  "dd=$(round(100*drawdown(acct.equity, hwm), digits=1))%"
        @info "spine_live_split complete" summary
        alert(summary; level = :info)
        return res.reconciled ? :ok : :reconcile_failed
    finally
        disconnect!(venue); close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
