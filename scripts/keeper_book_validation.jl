#!/usr/bin/env julia
# ============================================================================
# keeper_book_validation.jl — the VALIDATE-BEFORE-LIVE gate for the keeper book.
#
# The multi-sleeve demo reported the keeper book IN-SAMPLE and GROSS (full-sample risk-parity,
# ~+1.66 Sharpe). This is the honest test before anyone flips the driver to paper: a fully CAUSAL
# WALK-FORWARD, netted to the INSTRUMENT level (so it pays the sleeves' real internal turnover, not
# just book-weight drift), NET OF COSTS, with a stated pass/fail bar and a purged-K-fold cross-check.
#
# METHOD: every 21 trading days after a 380-day warmup, recompute the book from data STRICTLY BEFORE
# that day (risk-parity over the 8 ingredients + each sleeve's current instrument weights), net to
# per-instrument target weights (exactly what keeper_book_live.jl trades), hold 21 days, accrue the
# instrument-level P&L, and charge Σ|Δweight| × cost on each rebalance. This produces an out-of-sample
# net equity curve — no future information anywhere. Sleeve math is the shared keeper_sleeves.jl.
#
# THE BAR (all five must hold to PASS):
#   1. OOS net Sharpe >= 0.80              5. OOS Sharpe >= 0.60 x in-sample (limited overfit decay)
#   2. OOS net Sharpe >= SPY (same window) 3. OOS maxDD >= -20%   4. positive in >= 70% of years
#
# RESULTS AS TESTED (2017-11 .. 2026-07, 105 rebalances, net 5 bps/side):
#   keeper OOS net Sharpe +1.28 / CAGR +6.4% / maxDD -6%   (in-sample-fit ceiling +1.39 -> only a
#   ~8% Sharpe haircut = robust, not overfit; the demo's +1.66 gross was the full 15-ingredient set).
#   Beats SPY (+0.79 / -34%) on risk-adjusted at a fraction of the drawdown; positive in 9/10 years;
#   purged 6-fold OOS Sharpe mean +1.24 (min +0.17). ALL FIVE bar checks PASS -> clears the bar.
# Cost default 5 bps/side (BB_COST_BPS). Read-only (data only). NOT a live-money endorsement.
# ============================================================================
using Statistics, LinearAlgebra, Dates, Printf
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "scripts/research/keeper_ingredients.jl"))    # fetch_closes, compute_*, keeper_sleeves, PortfolioOpt
include(joinpath(REPO, "src/module_11_cv/purged_kfold.jl")); using .PurgedKFold

const SPINE_AC     = ["SPY", "IEF", "GLD", "DBC", "DBA"]
const TREND_ASSETS = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const BORE_NAMES   = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                      "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const DATA_UNIVERSE = unique(vcat(SPINE_AC, TREND_ASSETS, ["CRAK", "USO"], BORE_NAMES))
const COST = parse(Float64, get(ENV, "BB_COST_BPS", "5")) / 1e4
const REB, WARMUP = 21, 380

@info "fetching $(length(DATA_UNIVERSE)) instruments..."
D = Dict(s => fetch_closes(s) for s in DATA_UNIVERSE)
dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
Rinst = hcat([(p = [D[s][d] for d in dates]; p[2:end] ./ p[1:end-1] .- 1) for s in DATA_UNIVERSE]...)
rdates = dates[2:end]; T = size(Rinst, 1); sidx = Dict(s => i for (i, s) in enumerate(DATA_UNIVERSE))
col(R, s) = R[:, sidx[s]]

# ---- the 8 ingredient series over a (sub)panel, and the netted instrument book at its last bar ----
function ingredients(R)
    Tr = size(R, 1)
    ac = [col(R, s) for s in SPINE_AC]
    cser = compute_crack(col(R, "USO"), col(R, "CRAK"), Tr)
    tser = compute_trend(hcat([col(R, s) for s in TREND_ASSETS]...), Tr)
    bser = compute_bore(hcat([col(R, s) for s in BORE_NAMES]...), col(R, "SPY"), Tr)
    hcat(ac..., cser, bser, tser)
end
function book_weights(R)                                     # netted per-instrument weights at the last bar
    Rp = ingredients(R); valid = findall(t -> all(isfinite, Rp[t, :]), 1:size(Rp, 1))
    b = risk_parity(cov(Rp[valid, :])); bAC, bC, bB, bT = b[1:5], b[6], b[7], b[8]
    Btr = hcat([col(R, s) for s in TREND_ASSETS]...); Bbo = hcat([col(R, s) for s in BORE_NAMES]...)
    tw = trend_weights_today(Btr); wbo, beta = bore_weights_today(Bbo, col(R, "SPY")); csig = crack_signal(col(R, "USO"))
    net = Dict{String,Float64}(); add!(s, x) = (net[s] = get(net, s, 0.0) + x)
    for (i, s) in enumerate(SPINE_AC);     add!(s, bAC[i]); end
    add!("CRAK", bC * csig)
    for (i, s) in enumerate(TREND_ASSETS); add!(s, bT * tw[i]); end
    for (i, s) in enumerate(BORE_NAMES);   add!(s, bB * wbo[i]); end
    add!("SPY", bB * (-beta)); net
end

# ---- causal walk-forward, instrument-level, net of costs -------------------
oos = Float64[]; oosidx = Int[]; wprev = Dict{String,Float64}()
for t0 in WARMUP:REB:(T-1)
    w = book_weights(Rinst[1:t0, :])
    turn = sum(abs(get(w, s, 0.0) - get(wprev, s, 0.0)) for s in union(keys(w), keys(wprev)))
    for day in (t0+1):min(t0+REB, T)
        r = sum(get(w, s, 0.0) * Rinst[day, sidx[s]] for s in keys(w))
        day == t0 + 1 && (r -= turn * COST)                 # charge turnover on the first held day
        push!(oos, r); push!(oosidx, day)
    end
    global wprev = w
end

# ---- benchmarks over the same OOS window -----------------------------------
fullRp = ingredients(Rinst); b_full = risk_parity(cov(fullRp[findall(t -> all(isfinite, fullRp[t, :]), 1:T), :]))
insample = [dot(b_full, fullRp[i, :]) for i in oosidx]        # in-sample-fit weights (optimistic ceiling)
spy_oos  = [Rinst[i, sidx["SPY"]] for i in oosidx]
ew_oos   = [mean(fullRp[i, :]) for i in oosidx]
S(x) = sharpe(collect(skipmissing(x)))

# ---- per-year consistency + purged-K-fold cross-check ----------------------
yrs = unique([rdates[i][1:4] for i in oosidx])
yr_ret = [prod(1 .+ oos[[j for j in eachindex(oosidx) if rdates[oosidx[j]][1:4] == y]]) - 1 for y in yrs]
posyr = mean(yr_ret .> 0)
folds = purged_kfold_split(length(oos), PurgedKFoldConfig(; n_splits = 6, embargo_bars = REB); returns = oos)
foldsh = [sharpe(oos[f.test_idx]) for f in folds if length(f.test_idx) > 30]

println("="^78, "\nKEEPER BOOK — walk-forward OOS validation (net $(round(Int,COST*1e4)) bps/side)\n", "="^78)
@printf("\n  window: %s .. %s   OOS days: %d   rebalances: %d\n", rdates[oosidx[1]], rdates[oosidx[end]], length(oos), length(WARMUP:REB:(T-1)))
@printf("\n  %-28s %8s %8s %8s\n", "book", "Sharpe", "CAGR", "maxDD")
@printf("  %-28s %+8.2f %7.1f%% %7.0f%%\n", "keeper OOS (net, causal)", S(oos), ann_return(oos)*100, max_drawdown(oos)*100)
@printf("  %-28s %+8.2f %7.1f%% %7.0f%%\n", "in-sample fit (gross, ceiling)", S(insample), ann_return(insample)*100, max_drawdown(insample)*100)
@printf("  %-28s %+8.2f %7.1f%% %7.0f%%\n", "SPY (same window)", S(spy_oos), ann_return(spy_oos)*100, max_drawdown(spy_oos)*100)
@printf("  %-28s %+8.2f %7.1f%% %7.0f%%\n", "equal-weight 8 (same window)", S(ew_oos), ann_return(ew_oos)*100, max_drawdown(ew_oos)*100)
@printf("\n  per-year OOS return: %s\n", join(["$(yrs[i]) $(round(100*yr_ret[i],digits=0))%" for i in eachindex(yrs)], "  "))
@printf("  purged 6-fold OOS Sharpe: mean %+.2f  min %+.2f  (embargo %d bars)\n", mean(foldsh), minimum(foldsh), REB)

# ---- THE BAR ---------------------------------------------------------------
oos_sh, in_sh, spy_sh = S(oos), S(insample), S(spy_oos)
checks = [
    ("OOS net Sharpe >= 0.80",            oos_sh >= 0.80,                @sprintf("%.2f", oos_sh)),
    ("OOS Sharpe >= SPY (same window)",   oos_sh >= spy_sh,              @sprintf("%.2f vs %.2f", oos_sh, spy_sh)),
    ("OOS maxDD >= -20%",                 max_drawdown(oos) >= -0.20,    @sprintf("%.0f%%", max_drawdown(oos)*100)),
    ("positive in >= 70% of years",       posyr >= 0.70,                 @sprintf("%.0f%%", posyr*100)),
    ("OOS Sharpe >= 0.60 x in-sample",    oos_sh >= 0.60*in_sh,          @sprintf("%.2f vs %.2f", oos_sh, 0.60*in_sh)),
]
println("\n  THE BAR:")
for (name, ok, val) in checks; @printf("    [%s] %-34s %s\n", ok ? "PASS" : "FAIL", name, val); end
allpass = all(c -> c[2], checks)
println("\n  VERDICT: ", allpass ? "PASS — clears the bar; the keeper book graduates to paper." :
        "MIXED — does NOT fully clear the bar; keep it in dry-run and review the failed checks above.")
