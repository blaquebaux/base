#!/usr/bin/env julia
# ============================================================================
# tactical_book_live.jl — governed driver for the TACTICAL SLEEVE BOOK (the non-keepers, used as designed:
# small + regime-gated + time-boxed + combined). Validated by scripts/tactical_book_validation.jl (combined
# +0.45 net, beta ~0, uncorrelated to the keeper book, ~+5% overlay uplift at half weight).
#
#   data -> for each regime sleeve {cost-push, beige, bulgar, pead}: check its regime + build market-neutral
#   (SPY-hedged) weights -> apply the THREE RULES -> combine -> net per-symbol signed-share targets ->
#   [ SAFETY GATE preflight ] -> governed ExecutionController orders -> reconcile.
#
# PEAD (4th sleeve) is EVENT-DRIVEN: long the top-third / short the bottom-third earnings surprise among names
# still in their post-earnings drift window (from the pead_calendar.py cache). It is exempt from the time-box
# (positions self-limit as the drift window rolls off); its "regime" is simply having active events. Refresh
# the calendar periodically:  python scripts/pead_calendar.py  (weekly is plenty).
#
# THE THREE RULES:
#   (1) LIMITED SIZE  — each sleeve capped at ALLOC (10%) of the tactical capital.
#   (2) REGIME GATE   — a sleeve deploys ONLY when its own signal is on (cost-push: suppliers strong; beige:
#                       fuel rising; bulgar: ag rising). Off-regime -> that sleeve is flat.
#   (3) TIME-BOX      — after MAXHOLD_DAYS of CONTINUOUS deployment ("a quarter or two"), the sleeve is forced
#                       to STAND DOWN for COOL_DAYS (cooldown), so it can never overstay a regime into the
#                       reversal. This needs PERSISTENT STATE across daily runs -> a serialized state file.
#
# MODES (BB_TACTICAL_MODE): dryrun (DEFAULT — compute + gate + log, NO venue, NO orders, does NOT advance the
#   time-box clock) | paper | live.  Real money also requires BB_LIVE_CONFIRM=I_UNDERSTAND_THIS_IS_REAL_MONEY.
# Read-only bars always need ALPACA_KEY_ID / ALPACA_SECRET_KEY. Persistence defaults to TACTICAL-specific files
# so it can never touch the spine or keeper accounts' state. Kill switch: ~/.config/blaquebaux/HALT.
# NOT validated to the spine's bar — a paper/dry-run graduation of the tactical research, not a live endorsement.
# ============================================================================
using Dates, Serialization, Printf, Statistics, LinearAlgebra

const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_10_feedback/module_10_feedback.jl"))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
include(joinpath(REPO, "src/module_1_data/equity_panel.jl"))
include(joinpath(REPO, "src/module_1_data/alpaca_panel.jl"))
include(joinpath(REPO, "src/module_8_governance/safety_gate.jl"))
using .ExecutionLayer, .FeedbackLayer, .PortfolioOptModule, .EquityPanel, .AlpacaPanel, .SafetyGate
include(joinpath(REPO, "scripts/live_execution.jl"))
include(joinpath(REPO, "scripts/pead_sleeve.jl"))              # PEAD (4th sleeve): earnings-drift, event-driven
const PEAD_CAL = load_pead_calendar(joinpath(REPO, "scripts", "pead_earnings_calendar.json"))

const LIVE_SENTINEL = "I_UNDERSTAND_THIS_IS_REAL_MONEY"
const ALLOC       = parse(Float64, get(ENV, "BB_TACTICAL_ALLOC", "0.10"))   # limited size per sleeve
const MAXHOLD_DAYS = parse(Int, get(ENV, "BB_TACTICAL_MAXHOLD", "150"))     # ~a quarter or two of continuous deploy
const COOL_DAYS    = parse(Int, get(ENV, "BB_TACTICAL_COOLDOWN", "30"))     # forced stand-down after the time-box

# ---- the regime sleeves: (basket, signal-asset(s), side, lookback) ----
const CP_CUST   = ["KO","PEP","MDLZ","GIS","KHC"]; const CP_SUP = ["INGR","ADM"]
const BEIGE_AIR = ["DAL","UAL","AAL","LUV","ALK","JBLU"]
const BULGAR_PROC = ["INGR","ADM","BG"]
struct Sleeve; name::String; basket::Vector{String}; signal::Vector{String}; side::Float64; lb::Int; end
const SLEEVES = [Sleeve("cost-push", CP_CUST,     CP_SUP,  -1.0, 63),       # short food-mfrs when suppliers strong
                 Sleeve("beige",     BEIGE_AIR,   ["USO"], -1.0, 126),      # short airlines when fuel rising
                 Sleeve("bulgar",    BULGAR_PROC, ["DBA"], +1.0, 63)]       # long processors when ag rising
const DATA_UNIVERSE = unique(vcat([sl.basket for sl in SLEEVES]..., [sl.signal for sl in SLEEVES]..., PEAD_UNIVERSE, "SPY"))

# market-neutral (SPY-hedged) weights for a sleeve, and whether its regime is on. NOT yet scaled by ALLOC.
function sleeve_weights(sl::Sleeve, panel)
    syms = panel.symbols; R = panel.returns; Tr = size(R, 1)
    col(s) = R[:, findfirst(==(s), syms)]
    slv = cumprod(1 .+ vec(mean(hcat([col(s) for s in sl.signal]...), dims = 2)))
    on = Tr > sl.lb && (slv[Tr] / slv[Tr-sl.lb] - 1) > 0
    !on && return (Dict{String,Float64}(), false)
    B = hcat([col(s) for s in sl.basket]...); spy = col("SPY"); br = vec(mean(B, dims = 2))
    w = max(1, Tr-59):Tr
    bt = var(spy[w]) > 0 ? clamp(cov((sl.side .* br)[w], spy[w]) / var(spy[w]), -3.0, 3.0) : 0.0
    net = Dict{String,Float64}(); for s in sl.basket; net[s] = get(net, s, 0.0) + sl.side * (1 / length(sl.basket)); end
    net["SPY"] = get(net, "SPY", 0.0) - bt
    (net, true)
end

# time-box governance state: sleeve => (deploy_since::Union{Date,Nothing}, cooldown_until::Union{Date,Nothing})
load_state(p) = isfile(p) ? deserialize(p) : Dict{String,Tuple{Union{Date,Nothing},Union{Date,Nothing}}}()
save_state(p, s) = (mkpath(dirname(p)); serialize(p, s))

"Apply the three rules; returns (deployed::Bool, new_state_entry, reason)."
function govern(sl::Sleeve, on::Bool, today::Date, st)
    since, cool = get(st, sl.name, (nothing, nothing))
    if cool !== nothing && today < cool
        return (false, (nothing, cool), "cooldown until $cool")
    end
    cool = nothing                                                    # cooldown elapsed (or none)
    if !on
        return (false, (nothing, nothing), "regime off")
    end
    since === nothing && (since = today)
    if today - since >= Day(MAXHOLD_DAYS)
        return (false, (nothing, today + Day(COOL_DAYS)), "TIME-BOX hit ($(today - since)) -> cooldown $(COOL_DAYS)d")
    end
    (true, (since, nothing), "deployed since $since ($(today - since))")
end

function build_book(panel, capital, today, st; advance::Bool)
    price = Dict(panel.symbols[i] => panel.prices[i] for i in eachindex(panel.symbols))
    net = Dict{String,Float64}(); report = String[]
    for sl in SLEEVES
        w, on = sleeve_weights(sl, panel)
        deployed, entry, why = govern(sl, on, today, st)
        advance && (st[sl.name] = entry)
        push!(report, @sprintf("    %-10s %-8s  %s", sl.name, deployed ? "DEPLOY" : "flat", why))
        deployed && for (s, x) in w; net[s] = get(net, s, 0.0) + ALLOC * x; end
    end
    # PEAD (4th sleeve): event-driven -> deploy at ALLOC when there are active post-earnings drift-window events.
    # NO time-box (positions self-limit as the drift window rolls off); its "regime" is simply having live events.
    pw, pon = pead_weights(panel.returns, panel.symbols, PEAD_CAL, today)
    push!(report, @sprintf("    %-10s %-8s  %s", "pead", pon ? "DEPLOY" : "flat",
          pon ? "earnings drift-window book ($(count(x -> x[2] > 0, pw)) long / $(count(x -> x[2] < 0 && x[1] != "SPY", pw)) short)" : "no active earnings events in the drift window"))
    pon && for (s, x) in pw; net[s] = get(net, s, 0.0) + ALLOC * x; end
    targets = Dict{String,Float64}(); pr = Dict{String,Float64}()
    for (s, wt) in net
        haskey(price, s) || continue
        targets[s] = round(Int, wt * capital / price[s]); pr[s] = price[s]
    end
    (; targets, prices = pr, net, report, gross = sum(abs, values(net)))
end

_readf(p) = isfile(p) ? (v = tryparse(Float64, strip(read(p, String))); v === nothing ? NaN : v) : NaN
_writef(p, x) = (mkpath(dirname(p)); write(p, string(x)))

function main(; capital = parse(Float64, get(ENV, "BB_TACTICAL_CAPITAL", "100000")),
              pool = "tactical", limits::SafetyLimits = SafetyLimits(),
              db_path     = get(ENV, "BB_TACTICAL_LEDGER", joinpath(REPO, "alpaca_ledger_tactical.sqlite")),
              audit_path  = get(ENV, "BB_TACTICAL_AUDIT",  joinpath(REPO, "alpaca_audit_tactical.jsonl")),
              state_path  = get(ENV, "BB_TACTICAL_STATE",  joinpath(homedir(), ".config", "blaquebaux", "tactical_state.jls")),
              hwm_path    = get(ENV, "BB_TACTICAL_HWM",    joinpath(homedir(), ".config", "blaquebaux", "equity_hwm_tactical.txt")),
              equity_path = get(ENV, "BB_TACTICAL_EQUITY", joinpath(homedir(), ".config", "blaquebaux", "equity_last_tactical.txt")))
    (get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == "") &&
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY (read-only bars are needed even in dry-run).")
    mode = lowercase(get(ENV, "BB_TACTICAL_MODE", "dryrun"))
    live = mode == "live" && get(ENV, "BB_LIVE_CONFIRM", "") == LIVE_SENTINEL
    (mode == "live" && !live) && error("BB_TACTICAL_MODE=live requires BB_LIVE_CONFIRM=$LIVE_SENTINEL")
    @info "tactical_book_live starting" mode capital alloc=ALLOC maxhold=MAXHOLD_DAYS cooldown=COOL_DAYS

    panel = panel_at(AlpacaPanelProvider(DATA_UNIVERSE; lookback = 500))
    fresh = (Dates.today() - panel.asof) <= Day(5); today = panel.asof
    st = load_state(state_path)
    bk = build_book(panel, capital, today, st; advance = (mode != "dryrun"))   # dry-run never burns the time-box clock
    @info "tactical book" asof=today gross=round(bk.gross, digits=2)
    println("\n  sleeve deployment (three rules: $(Int(ALLOC*100))% cap / regime-gate / time-box $(MAXHOLD_DAYS)d):")
    foreach(println, bk.report)
    println("\n  netted per-symbol target weights (of $(round(Int,capital)) tactical capital):")
    for (s, w) in sort(collect(bk.net), by = x -> -abs(x[2]))
        abs(w) < 1e-4 && continue
        @printf("    %-6s %+6.1f%%   -> %+d sh @ \$%.2f\n", s, 100w, Int(get(bk.targets, s, 0.0)), get(bk.prices, s, NaN))
    end
    isempty(bk.net) && println("    (all sleeves flat — no regime on, or all in cooldown)")

    if mode == "dryrun"
        ok, reasons = preflight(; account_status = "ACTIVE", equity = capital, hwm = capital,
            last_equity = capital, buying_power = capital, data_fresh = fresh,
            targets = bk.targets, prices = bk.prices, limits = limits)
        @info "SAFETY GATE (dry-run, nominal account)" ok reasons
        println("\n  DRY RUN — no venue, no orders, time-box clock NOT advanced. Gate: $(ok ? "PASS" : "ABORT: " * join(reasons, "; "))")
        return ok ? :dryrun_ok : :dryrun_gate_abort
    end

    # ---- paper / live: the governed path (mirrors keeper_book_live.jl) ----
    paper = !live; runmode = live ? "*** LIVE REAL MONEY ***" : "paper"
    live && alert("TACTICAL BOOK: LIVE REAL-MONEY mode engaged"; level = :critical)
    venue = AlpacaVenue(AlpacaConfig(; paper = paper))
    built = build_live_controller(; venue = venue, ledger_config = LedgerConfig(; db_path = db_path), audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    try
        connect!(venue) || (alert("ABORT [$runmode]: Alpaca connect failed (tactical)"; level = :critical); return :connect_failed)
        acct = account_info(venue)
        acct === nothing && (alert("ABORT [$runmode]: could not read account (tactical)"; level = :critical); return :no_account)
        hwm = max(load_hwm(hwm_path), acct.equity); last_eq = _readf(equity_path)
        ok, reasons = preflight(; account_status = acct.status, trading_blocked = acct.trading_blocked,
            account_blocked = acct.account_blocked, equity = acct.equity, hwm = hwm, last_equity = last_eq,
            buying_power = acct.buying_power, data_fresh = fresh, targets = bk.targets, prices = bk.prices, limits = limits)
        save_hwm(hwm, hwm_path); _writef(equity_path, acct.equity)
        if !ok
            msg = "SAFETY ABORT [$runmode] (tactical): " * join(reasons, "; "); @error msg
            halt!(ctrl, "safety gate"); alert(msg; level = :critical); return :aborted
        end
        save_state(state_path, st)                                    # commit the time-box clock only after the gate passes
        reset_daily!(ctrl)
        set_pool_budget!(ctrl, pool, limits.max_gross_leverage * acct.equity)
        set_pool_loss_limit!(ctrl, pool, limits.max_daily_loss)
        set_pool_staleness!(ctrl, pool, Day(5)); feed_staleness!(ctrl, pool; stale = !fresh)
        isfinite(last_eq) && update_pnl!(ctrl, pool, acct.equity - last_eq)
        ncanc = cancel_all_open!(venue); ncanc > 0 && sleep(2)
        for (sym, qty) in positions(venue, ctrl.account); apply_fill!(ctrl, sym, qty); end
        res = execute_rebalance!(ctrl, ledger; targets = bk.targets, prices = bk.prices,
            signal_id = "tactical_book", regime = "regime-gated", solve_id = Dates.format(today, "yyyymmdd"),
            pool_id = pool, settle_secs = 20)
        !res.reconciled && (alert("RECONCILE FAILED [$runmode] (tactical) — halting"; level = :critical); halt!(ctrl, "reconcile mismatch"))
        summary = "[$runmode] tactical book; orders=$(length(res.acks)) fills=$(length(res.fills)) reconciled=$(res.reconciled) equity=$(round(Int, acct.equity))"
        @info "tactical_book_live complete" summary; alert(summary; level = :info)
        return res.reconciled ? :ok : :reconcile_failed
    finally
        disconnect!(venue); close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
