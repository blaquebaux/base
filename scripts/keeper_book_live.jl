#!/usr/bin/env julia
# ============================================================================
# keeper_book_live.jl — governed driver for the diversified KEEPER BOOK.
#
#   data -> build keeper book (spine + CRACK/BORE/TREND, risk-parity) -> net to per-symbol
#   signed-share targets -> [ SAFETY GATE preflight ] -> governed ExecutionController orders
#   -> reconcile.  Same governed path as spine_live.jl; only the TARGET construction differs.
#
# The book is the research keeper set the multi-sleeve demo validated (~+1.6 Sharpe / -5% DD):
#   asset-class spine  SPY IEF GLD DBC DBA   (held directly)
#   CRACK   crude->refiner  (long CRAK when crude up)
#   BORE    beta-hedged momentum-neutral over 20 large caps  (long/short + SPY beta hedge)
#   TREND   vol-scaled multi-horizon trend over SPY/IEF/TLT/GLD/DBC/DBA
# Book weights = risk_parity over the 8 ingredient return streams (recomputed daily); each sleeve
# is expanded into its current instrument weights and NETTED per symbol. (Sleeve math mirrors
# scripts/research/keeper_ingredients.jl.)
#
# MODES (BB_KEEPER_MODE):  dryrun (DEFAULT — compute + gate + log, NO venue, NO orders) | paper | live.
#   Real money additionally requires  export BB_LIVE_CONFIRM=I_UNDERSTAND_THIS_IS_REAL_MONEY.
# Data fetch always needs ALPACA_KEY_ID / ALPACA_SECRET_KEY (read-only bars, even in dry-run).
# Persistence (ledger/audit/hwm/equity) defaults to KEEPER-specific files so it can never touch the
# spine accounts' state.  Kill switch: create ~/.config/blaquebaux/HALT.  NOT validated to the
# spine's bar — this is a paper/dry-run graduation of the research, not a live-money endorsement.
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
include(joinpath(REPO, "scripts/research/keeper_sleeves.jl"))   # shared sleeve math (single source of truth)

const SPINE_AC     = ["SPY", "IEF", "GLD", "DBC", "DBA"]                 # asset-class ingredients (held)
const TREND_ASSETS = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const BORE_NAMES   = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                      "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const DATA_UNIVERSE = unique(vcat(SPINE_AC, TREND_ASSETS, ["CRAK", "USO"], BORE_NAMES))  # USO = CRACK signal only
const LIVE_SENTINEL = "I_UNDERSTAND_THIS_IS_REAL_MONEY"

# ---- build the netted keeper book (sleeve math from keeper_sleeves.jl) ------
function keeper_book(panel, capital)
    syms = panel.symbols; R = panel.returns; Tr = size(R, 1)
    price = Dict(syms[i] => panel.prices[i] for i in eachindex(syms))
    col(s) = R[:, findfirst(==(s), syms)]
    ac    = [col(s) for s in SPINE_AC]
    cser  = compute_crack(col("USO"), col("CRAK"), Tr)
    Btr   = hcat([col(s) for s in TREND_ASSETS]...); tser = compute_trend(Btr, Tr)
    Bbo   = hcat([col(s) for s in BORE_NAMES]...);   bser = compute_bore(Bbo, col("SPY"), Tr)
    Rp = hcat(ac..., cser, bser, tser)                                   # T x 8 : AC(5), CRACK, BORE, TREND
    valid = findall(t -> all(isfinite, Rp[t, :]), 1:size(Rp, 1))
    b = risk_parity(cov(Rp[valid, :]))                                   # 8 book weights (risk parity)
    bAC, bC, bB, bT = b[1:5], b[6], b[7], b[8]

    tw = trend_weights_today(Btr); wbo, beta = bore_weights_today(Bbo, col("SPY"))
    csig = crack_signal(col("USO"))
    net = Dict{String,Float64}(); add!(s, x) = (net[s] = get(net, s, 0.0) + x)
    for (i, s) in enumerate(SPINE_AC);     add!(s, bAC[i]); end           # asset classes held directly
    add!("CRAK", bC * csig)                                               # CRACK: conditional long CRAK
    for (i, s) in enumerate(TREND_ASSETS); add!(s, bT * tw[i]); end       # TREND: signed vol-scaled weights
    for (i, s) in enumerate(BORE_NAMES);   add!(s, bB * wbo[i]); end      # BORE: long/short 20 names
    add!("SPY", bB * (-beta))                                             # BORE: SPY beta hedge
    targets = Dict{String,Float64}(); pr = Dict{String,Float64}()
    for (s, wt) in net
        haskey(price, s) || continue
        targets[s] = round(Int, wt * capital / price[s]); pr[s] = price[s]
    end
    (; targets, prices = pr, net, b, gross = sum(abs, values(net)))
end

_readf(p) = isfile(p) ? (v = tryparse(Float64, strip(read(p, String))); v === nothing ? NaN : v) : NaN
_writef(p, x) = (mkpath(dirname(p)); write(p, string(x)))

function main(; capital = parse(Float64, get(ENV, "BB_KEEPER_CAPITAL", "100000")),
              pool = "keeper", limits::SafetyLimits = SafetyLimits(),
              db_path     = get(ENV, "BB_KEEPER_LEDGER", joinpath(REPO, "alpaca_ledger_keeper.sqlite")),
              audit_path  = get(ENV, "BB_KEEPER_AUDIT",  joinpath(REPO, "alpaca_audit_keeper.jsonl")),
              hwm_path    = get(ENV, "BB_KEEPER_HWM",    joinpath(homedir(), ".config", "blaquebaux", "equity_hwm_keeper.txt")),
              equity_path = get(ENV, "BB_KEEPER_EQUITY", joinpath(homedir(), ".config", "blaquebaux", "equity_last_keeper.txt")))
    (get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == "") &&
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY (read-only bars are needed even in dry-run).")
    mode = lowercase(get(ENV, "BB_KEEPER_MODE", "dryrun"))
    live = mode == "live" && get(ENV, "BB_LIVE_CONFIRM", "") == LIVE_SENTINEL
    (mode == "live" && !live) && error("BB_KEEPER_MODE=live requires BB_LIVE_CONFIRM=$LIVE_SENTINEL")
    @info "keeper_book_live starting" mode capital

    panel = panel_at(AlpacaPanelProvider(DATA_UNIVERSE; lookback = 500))
    fresh = (Dates.today() - panel.asof) <= Day(5)
    bk = keeper_book(panel, capital)
    @info "book weights (risk-parity over 8 ingredients)" asof=panel.asof gross=round(bk.gross, digits=2) weights=Dict(["SPY_ac","IEF","GLD","DBC","DBA","CRACK","BORE","TREND"][i] => round(bk.b[i], digits=3) for i in 1:8)
    println("\n  netted per-symbol target weights (of $(round(Int,capital)) capital):")
    for (s, w) in sort(collect(bk.net), by = x -> -abs(x[2]))
        abs(w) < 1e-4 && continue
        @printf("    %-6s %+6.1f%%   -> %+d sh @ \$%.2f\n", s, 100w, Int(get(bk.targets, s, 0.0)), get(bk.prices, s, NaN))
    end

    if mode == "dryrun"
        ok, reasons = preflight(; account_status = "ACTIVE", equity = capital, hwm = capital,
            last_equity = capital, buying_power = capital, data_fresh = fresh,
            targets = bk.targets, prices = bk.prices, limits = limits)
        @info "SAFETY GATE (dry-run, nominal account)" ok reasons
        println("\n  DRY RUN — no venue connection, no orders placed. Gate: $(ok ? "PASS" : "ABORT: " * join(reasons, "; "))")
        return ok ? :dryrun_ok : :dryrun_gate_abort
    end

    # ---- paper / live: the governed path (mirrors spine_live.jl) ----
    paper = !live; runmode = live ? "*** LIVE REAL MONEY ***" : "paper"
    live && alert("KEEPER BOOK: LIVE REAL-MONEY mode engaged"; level = :critical)
    venue = AlpacaVenue(AlpacaConfig(; paper = paper))
    built = build_live_controller(; venue = venue, ledger_config = LedgerConfig(; db_path = db_path), audit_path = audit_path)
    ctrl, ledger = built.ctrl, built.ledger
    try
        connect!(venue) || (alert("ABORT [$runmode]: Alpaca connect failed"; level = :critical); return :connect_failed)
        acct = account_info(venue)
        acct === nothing && (alert("ABORT [$runmode]: could not read account"; level = :critical); return :no_account)
        hwm = max(load_hwm(hwm_path), acct.equity); last_eq = _readf(equity_path)
        ok, reasons = preflight(; account_status = acct.status, trading_blocked = acct.trading_blocked,
            account_blocked = acct.account_blocked, equity = acct.equity, hwm = hwm, last_equity = last_eq,
            buying_power = acct.buying_power, data_fresh = fresh, targets = bk.targets, prices = bk.prices, limits = limits)
        save_hwm(hwm, hwm_path); _writef(equity_path, acct.equity)
        if !ok
            msg = "SAFETY ABORT [$runmode]: " * join(reasons, "; "); @error msg
            halt!(ctrl, "safety gate"); alert(msg; level = :critical); return :aborted
        end
        reset_daily!(ctrl)
        set_pool_budget!(ctrl, pool, limits.max_gross_leverage * acct.equity)
        set_pool_loss_limit!(ctrl, pool, limits.max_daily_loss)
        set_pool_staleness!(ctrl, pool, Day(5)); feed_staleness!(ctrl, pool; stale = !fresh)
        isfinite(last_eq) && update_pnl!(ctrl, pool, acct.equity - last_eq)
        ncanc = cancel_all_open!(venue); ncanc > 0 && sleep(2)
        for (sym, qty) in positions(venue, ctrl.account); apply_fill!(ctrl, sym, qty); end   # trade the delta
        res = execute_rebalance!(ctrl, ledger; targets = bk.targets, prices = bk.prices,
            signal_id = "keeper_book", regime = "n/a", solve_id = Dates.format(panel.asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 20)
        !res.reconciled && (alert("RECONCILE FAILED [$runmode] — halting"; level = :critical); halt!(ctrl, "reconcile mismatch"))
        summary = "[$runmode] keeper book; orders=$(length(res.acks)) fills=$(length(res.fills)) reconciled=$(res.reconciled) equity=$(round(Int, acct.equity))"
        @info "keeper_book_live complete" summary; alert(summary; level = :info)
        return res.reconciled ? :ok : :reconcile_failed
    finally
        disconnect!(venue); close_ledger(ledger)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
