#!/usr/bin/env julia
# ============================================================================
# blunt_live.jl — BLAQUE BAUX BLUNT sleeve #4 live driver (crude -> refiner lead-lag).
#
# Same governed order path and Layer-3 safety gate as spine_live.jl — only the
# universe and the signal differ. This is a SHORT-HORIZON tactical sleeve, run as
# a 4th paper A/B leg alongside single / split / multi.
#
#   data(USO,CRAK) -> SIGNAL -> CRAK target -> [ SAFETY GATE ] -> governed order -> reconcile
#
# SIGNAL (validated in scripts/research/blunt/crack_prototype.py, NET Sharpe ~1.0):
#   crude (USO) leads refiner equities (CRAK) by a day. If crude ROSE on the last
#   completed session, hold a vol-targeted LONG in CRAK today; otherwise stay FLAT.
#   Long-only, so we are never perpetually short crude's drift. Crude is a SIGNAL
#   ONLY and is never traded — the sole position is CRAK.
#
# PAPER by default. Real money requires:  export BB_LIVE_CONFIRM=I_UNDERSTAND_THIS_IS_REAL_MONEY
# Kill switch: create ~/.config/blaquebaux/HALT. Dry run (no connect, no trade,
# prints the intended target): export BB_DRYRUN=1  (uses whatever data keys are in env).
# NOT validated to the spine's bar; a paper-A/B candidate, not real capital.
# ============================================================================
using Dates, Printf

const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_10_feedback/module_10_feedback.jl"))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
include(joinpath(REPO, "src/module_1_data/equity_panel.jl"))
include(joinpath(REPO, "src/module_1_data/alpaca_panel.jl"))
include(joinpath(REPO, "src/module_8_governance/safety_gate.jl"))
using .ExecutionLayer, .FeedbackLayer, .PortfolioOptModule, .EquityPanel, .AlpacaPanel, .SafetyGate
include(joinpath(REPO, "scripts/live_execution.jl"))

const SIGNAL_SYM    = "USO"     # crude — signal only, NEVER traded
const TRADE_SYM     = "CRAK"    # refiner equities — the sole position
const UNIVERSE      = [SIGNAL_SYM, TRADE_SYM]
const LIVE_SENTINEL = "I_UNDERSTAND_THIS_IS_REAL_MONEY"
const VOL_TARGET    = 0.10      # 10% annualized position vol
const VOL_HL        = 20        # EWMA halflife (days) for the CRAK vol estimate
const WEIGHT_CAP    = 0.80      # single-name cap; stays under the gate's 0.85 per-name & 2x gross

_readf(p) = isfile(p) ? (v = tryparse(Float64, strip(read(p, String))); v === nothing ? NaN : v) : NaN
_writef(p, x) = (mkpath(dirname(p)); write(p, string(x)))

"EWMA volatility (annualized) of a daily-return vector."
function ewma_vol_ann(r::AbstractVector; hl::Int = VOL_HL)
    isempty(r) && return NaN
    lam = 0.5^(1 / hl); v = float(r[1])^2
    @inbounds for t in eachindex(r)
        v = t == 1 ? float(r[t])^2 : lam * v + (1 - lam) * float(r[t])^2
    end
    return sqrt(max(v, 1e-12)) * sqrt(252)
end

"Compute the sleeve's target CRAK weight from the panel. Returns (weight, crude_ret, crak_vol, crak_px)."
function blunt_signal(panel)
    syms = panel.symbols
    ui = findfirst(==(SIGNAL_SYM), syms); ci = findfirst(==(TRADE_SYM), syms)
    (ui === nothing || ci === nothing) && error("panel missing $SIGNAL_SYM/$TRADE_SYM (got $syms)")
    crude_ret = panel.returns[end, ui]                 # last completed session's crude move
    crak_vol  = ewma_vol_ann(panel.returns[:, ci])
    raw       = crude_ret > 0 ? 1.0 : 0.0              # long-only, crude-up
    weight    = clamp(VOL_TARGET / max(crak_vol, 1e-6), 0.0, WEIGHT_CAP) * raw
    return (weight = weight, crude_ret = crude_ret, crak_vol = crak_vol, crak_px = panel.prices[ci])
end

function main(; capital = nothing, pool = "us", limits::SafetyLimits = SafetyLimits(),
              state_path  = get(ENV, "BB_STATE_PATH",  joinpath(REPO, "blunt_state.jls")),   # reserved; sleeve is stateless
              db_path     = get(ENV, "BB_LEDGER_PATH", joinpath(REPO, "alpaca_ledger_blunt.sqlite")),
              audit_path  = get(ENV, "BB_AUDIT_PATH",  joinpath(REPO, "alpaca_audit_blunt.jsonl")),
              hwm_path    = get(ENV, "BB_HWM_PATH",    joinpath(homedir(), ".config", "blaquebaux", "equity_hwm_blunt.txt")),
              equity_path = get(ENV, "BB_EQUITY_PATH", joinpath(homedir(), ".config", "blaquebaux", "equity_last_blunt.txt")))

    if get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == ""
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY.")
    end
    dryrun = get(ENV, "BB_DRYRUN", "") in ("1", "true", "yes")

    # ── DRY RUN: compute + print the intended target, connect to nothing, trade nothing ──
    if dryrun
        panel = panel_at(AlpacaPanelProvider(UNIVERSE; lookback = 90))
        sig = blunt_signal(panel)
        cap = capital === nothing ? 100_000.0 : capital
        shares = round(Int, sig.weight * cap / sig.crak_px)
        @info "BLUNT dry run" asof=panel.asof crude_last=@sprintf("%.2f%%", 100sig.crude_ret) crak_vol=@sprintf("%.0f%%", 100sig.crak_vol) weight=@sprintf("%.1f%%", 100sig.weight) crak_px=sig.crak_px target_shares=shares nominal_capital=cap
        println("DRYRUN: crude last ", @sprintf("%.2f%%", 100sig.crude_ret),
                " -> ", sig.weight > 0 ? "LONG" : "FLAT",
                " CRAK ", @sprintf("%.1f%%", 100sig.weight),
                " = ", shares, " sh @ \$", @sprintf("%.2f", sig.crak_px),
                " (nominal \$", @sprintf("%.0f", cap), ")")
        return :dryrun
    end

    live  = get(ENV, "BB_LIVE_CONFIRM", "") == LIVE_SENTINEL
    paper = !live
    mode  = live ? "*** LIVE REAL MONEY ***" : "paper"
    @info "blunt_live starting" mode signal="crude->refiner"
    live && alert("BLUNT LIVE REAL-MONEY mode engaged"; level = :critical)

    venue = AlpacaVenue(AlpacaConfig(; paper = paper))
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = db_path), audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    try
        if !connect!(venue)
            alert("ABORT [$mode]: Alpaca connect failed (blunt)"; level = :critical); return :connect_failed
        end
        acct = account_info(venue)
        acct === nothing && (alert("ABORT [$mode]: could not read account (blunt)"; level = :critical); return :no_account)

        cap      = capital === nothing ? acct.equity : capital
        hwm      = max(load_hwm(hwm_path), acct.equity)
        last_eq  = _readf(equity_path)
        panel    = panel_at(AlpacaPanelProvider(UNIVERSE; lookback = 90))
        fresh    = (Dates.today() - panel.asof) <= Day(5)

        sig      = blunt_signal(panel)
        shares   = round(Float64, sig.weight * cap / sig.crak_px)
        targets  = Dict(TRADE_SYM => shares)                    # trade CRAK only; crude is signal-only
        prices   = Dict(TRADE_SYM => sig.crak_px)
        reg      = sig.weight > 0 ? "crude-up" : "flat"
        @info "blunt signal" crude_last=sig.crude_ret crak_vol=sig.crak_vol weight=sig.weight target_shares=shares regime=reg

        # ── THE GATE ─────────────────────────────────────────────────────────────
        ok, reasons = preflight(; account_status = acct.status, trading_blocked = acct.trading_blocked,
            account_blocked = acct.account_blocked, equity = acct.equity, hwm = hwm,
            last_equity = last_eq, buying_power = acct.buying_power, data_fresh = fresh,
            targets = targets, prices = prices, limits = limits)

        save_hwm(hwm, hwm_path); _writef(equity_path, acct.equity)

        if !ok
            msg = "SAFETY ABORT [$mode] (blunt): " * join(reasons, "; ")
            @error msg; halt!(ctrl, "safety gate"); alert(msg; level = :critical); return :aborted
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

        # Seed expected positions from the broker (source of truth) before rebalancing the delta.
        bpos = positions(venue, ctrl.account)
        for (sym, qty) in bpos
            apply_fill!(ctrl, sym, qty)
        end
        @info "seeded expected positions from broker" held=length(bpos)

        res = execute_rebalance!(ctrl, ledger; targets = targets, prices = prices,
            signal_id = "blunt_crack", regime = reg, solve_id = Dates.format(panel.asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 20)

        if !res.reconciled
            alert("RECONCILE FAILED [$mode] (blunt) — halting"; level = :critical)
            halt!(ctrl, "reconcile mismatch")
        end

        summary = "[$mode] blunt $(reg); orders=$(length(res.acks)) fills=$(length(res.fills)) " *
                  "reconciled=$(res.reconciled); equity=$(round(Int, acct.equity)) " *
                  "dd=$(round(100*drawdown(acct.equity, hwm), digits=1))%"
        @info "blunt_live complete" summary
        alert(summary; level = :info)
        return res.reconciled ? :ok : :reconcile_failed
    finally
        disconnect!(venue); close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
