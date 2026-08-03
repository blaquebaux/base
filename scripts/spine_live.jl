#!/usr/bin/env julia
# ============================================================================
# spine_live.jl — PRODUCTION driver with the Layer-3 live-money safety gate.
#
#   account/data → SPINE → targets → [ SAFETY GATE preflight ] → governed orders → reconcile
#                                          │ if ANY guard trips:
#                                          └─ HALT + ALERT, place NOTHING.
#
# Safety checks ALWAYS run (paper and live). PAPER by default. Real money requires the explicit
# sentinel:   export BB_LIVE_CONFIRM=I_UNDERSTAND_THIS_IS_REAL_MONEY   — nothing else flips it.
# Optional alert webhook: export BB_ALERT_WEBHOOK=<slack/discord url>. Kill switch: create the
# file ~/.config/blaquebaux/HALT (delete to resume). This is the driver the launchd job should
# use once you're past pure-paper testing.
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

# DBA (agriculture) added 2026-07-31 as the one genuinely-uncorrelated sleeve (0.44 corr to DBC;
# everything else tested — intl/EM equity, credit, REITs, silver — carried 0.66-0.84 equity/rate
# beta and did not diversify). Backtest 2016-2026: Sharpe 0.94->1.04, CAGR 5.4%->5.9%, maxDD ~flat.
# Caveat: validated on 2016-2026 only (no GFC); the economic case (weather/supply-driven, orthogonal
# to financial risk) is the stronger justification. See docs/CANONICAL_ARCHITECTURE.md.
const UNIVERSE     = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const LIVE_SENTINEL = "I_UNDERSTAND_THIS_IS_REAL_MONEY"

_readf(p) = isfile(p) ? (v = tryparse(Float64, strip(read(p, String))); v === nothing ? NaN : v) : NaN
_writef(p, x) = (mkpath(dirname(p)); write(p, string(x)))

function main(; universe = UNIVERSE, capital = 100_000.0, pool = "us", regime = :dd,
              limits::SafetyLimits = SafetyLimits(),
              # All persistence paths are env-overridable so a SECOND account can run this same driver
              # in full isolation (e.g. the single-multi A/B leg). Defaults = account #1's files.
              state_path  = get(ENV, "BB_STATE_PATH",  joinpath(REPO, "spine_state_alpaca.jls")),
              db_path     = get(ENV, "BB_LEDGER_PATH", joinpath(REPO, "alpaca_ledger.sqlite")),
              audit_path  = get(ENV, "BB_AUDIT_PATH",  joinpath(REPO, "alpaca_audit.jsonl")),
              hwm_path    = get(ENV, "BB_HWM_PATH",    default_hwm_path()),
              equity_path = get(ENV, "BB_EQUITY_PATH", default_equity_path()))

    if get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == ""
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY.")
    end
    live  = get(ENV, "BB_LIVE_CONFIRM", "") == LIVE_SENTINEL
    paper = !live
    mode  = live ? "*** LIVE REAL MONEY ***" : "paper"
    @info "spine_live starting" mode
    live && alert("LIVE REAL-MONEY mode engaged"; level = :critical)

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

        hwm      = max(load_hwm(hwm_path), acct.equity)
        last_eq  = _readf(equity_path)
        panel    = panel_at(AlpacaPanelProvider(universe; lookback = 252))
        fresh    = (Dates.today() - panel.asof) <= Day(5)

        state    = isfile(state_path) ? deserialize(state_path)::SpineState :
                                        SpineState(length(universe); regime = regime)
        # Self-healing guard: if the persisted vol-state was built for a different universe size
        # (an asset was just added/removed), its per-sleeve weight vectors won't match the new
        # panel width. Migrate — but PRESERVE the scalar vol levels (base_s2/trend_s2/n) so the
        # per-sleeve vol-target stays warm and the first post-change book is NOT sized at full cap;
        # only the resized weight vectors reset (a one-bar, negligible fold-in effect).
        if length(state.base_w) != length(universe)
            @warn "universe size changed ($(length(state.base_w)) -> $(length(universe))); migrating spine vol-state (vol levels preserved, weights resized)"
            migrated = SpineState(length(universe); regime = regime)
            migrated.base_s2, migrated.trend_s2, migrated.n = state.base_s2, state.trend_s2, state.n
            state = migrated
        end
        # trend construction flag: BB_TREND_MODE=multi enables the 3/6/12-month multi-horizon trend
        # (more convex; sketch-validated, pending OOS). Default :sign = the exactly-validated 12-mo sign.
        trend_mode = Symbol(lowercase(get(ENV, "BB_TREND_MODE", "sign")))
        @info "spine trend mode" trend_mode
        w        = spine_step!(state, panel.returns; trend_mode = trend_mode)
        reg      = regime_multiplier(panel.returns, :dd) < 1.0 ? "risk-off" : "normal"
        targets  = spine_targets(w, panel.symbols, panel.prices, capital)
        prices   = Dict(panel.symbols[i] => panel.prices[i] for i in eachindex(panel.symbols))

        # ── THE GATE ─────────────────────────────────────────────────────────────
        ok, reasons = preflight(; account_status = acct.status, trading_blocked = acct.trading_blocked,
            account_blocked = acct.account_blocked, equity = acct.equity, hwm = hwm,
            last_equity = last_eq, buying_power = acct.buying_power, data_fresh = fresh,
            targets = targets, prices = prices, limits = limits)

        save_hwm(hwm, hwm_path); _writef(equity_path, acct.equity)   # persist regardless (per-account)

        if !ok
            msg = "SAFETY ABORT [$mode]: " * join(reasons, "; ")
            @error msg
            halt!(ctrl, "safety gate")
            alert(msg; level = :critical)
            return :aborted
        end

        # ── safe to trade ────────────────────────────────────────────────────────
        reset_daily!(ctrl)
        set_pool_budget!(ctrl, pool, limits.max_gross_leverage * acct.equity)
        set_pool_loss_limit!(ctrl, pool, limits.max_daily_loss)
        set_pool_staleness!(ctrl, pool, Day(5))
        feed_staleness!(ctrl, pool; stale = !fresh)
        isfinite(last_eq) && update_pnl!(ctrl, pool, acct.equity - last_eq)   # feed controller loss-halt too

        ncanc = cancel_all_open!(venue); @info "cancelled stale orders" count=ncanc
        ncanc > 0 && sleep(2)

        # Rebalance the DELTA, not the full target. A fresh daily process starts with expected=0,
        # so seed it from the broker's ACTUAL holdings — otherwise it would re-place the whole
        # target on top of prior fills (stacking positions, then a reconcile halt). Broker is the
        # source of truth (survives restarts, manual edits, partial fills, corporate actions).
        bpos = positions(venue, ctrl.account)
        for (sym, qty) in bpos
            apply_fill!(ctrl, sym, qty)
        end
        @info "seeded expected positions from broker" held=length(bpos)

        res = execute_rebalance!(ctrl, ledger; targets = targets, prices = prices,
            signal_id = "spine", regime = reg, solve_id = Dates.format(panel.asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 20)
        serialize(state_path, state)

        if !res.reconciled
            alert("RECONCILE FAILED [$mode] — halting; book may not match broker"; level = :critical)
            halt!(ctrl, "reconcile mismatch")
        end

        summary = "[$mode] $(reg); orders=$(length(res.acks)) fills=$(length(res.fills)) " *
                  "reconciled=$(res.reconciled); equity=$(round(Int, acct.equity)) " *
                  "dd=$(round(100*drawdown(acct.equity, hwm), digits=1))%"
        @info "spine_live complete" summary
        alert(summary; level = :info)
        return res.reconciled ? :ok : :reconcile_failed
    finally
        disconnect!(venue); close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
