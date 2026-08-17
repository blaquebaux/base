#!/usr/bin/env julia
# ============================================================================
# keeper_book_regime_validation.jl — does the BONDS regime overlay improve the KEEPER BOOK?
#
# The keeper book is a risk-parity blend of 8 ingredients (asset-class spine + CRACK/BORE/TREND).
# Its STATIC equity leg (the spine SPY held directly) leans on the spine's IEF to diversify it — but
# blaquebaux/bonds #1 showed that stock-bond diversification is regime-conditional. The overlay trims
# ONLY that static SPY leg when the correlation is POSITIVE (hedge dead), leaving TREND's adaptive SPY
# and BORE's SPY hedge untouched.
#
# This is a fully causal walk-forward (mirrors keeper_book_validation.jl) comparing:
#   FULL     — the keeper book as-is
#   OVERLAY  — static SPY leg x REGIME_DERISK whenever the 63d SPY-IEF correlation is positive
# Net of cost. The book is ALREADY very diversified (~ -6% DD), so the honest prior is the overlay
# adds little; the bar decides whether it earns being on-by-default.  Read-only.
#   Run:  julia --project=. scripts/keeper_book_regime_validation.jl
# ============================================================================
using Statistics, LinearAlgebra, Dates, Printf
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "scripts/research/keeper_ingredients.jl"))

const SPINE_AC     = ["SPY", "IEF", "GLD", "DBC", "DBA"]
const TREND_ASSETS = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const BORE_NAMES   = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                      "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const DATA_UNIVERSE = unique(vcat(SPINE_AC, TREND_ASSETS, ["CRAK", "USO"], BORE_NAMES))
const COST = parse(Float64, get(ENV, "BB_COST_BPS", "5")) / 1e4
const REB, WARMUP, CORR_WIN = 21, 380, 63
const DERISK = parse(Float64, get(ENV, "BB_REGIME_DERISK", "0.75"))

@info "fetching $(length(DATA_UNIVERSE)) instruments..."
D = Dict(s => fetch_closes(s) for s in DATA_UNIVERSE)
dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
Rinst = hcat([(p = [D[s][d] for d in dates]; p[2:end] ./ p[1:end-1] .- 1) for s in DATA_UNIVERSE]...)
rdates = dates[2:end]; T = size(Rinst, 1); sidx = Dict(s => i for (i, s) in enumerate(DATA_UNIVERSE))
col(R, s) = R[:, sidx[s]]

function ingredients(R)
    Tr = size(R, 1)
    ac = [col(R, s) for s in SPINE_AC]
    cser = compute_crack(col(R, "USO"), col(R, "CRAK"), Tr)
    tser = compute_trend(hcat([col(R, s) for s in TREND_ASSETS]...), Tr)
    bser = compute_bore(hcat([col(R, s) for s in BORE_NAMES]...), col(R, "SPY"), Tr)
    hcat(ac..., cser, bser, tser)
end

"Netted per-instrument weights at the last bar; eq_scale trims ONLY the static spine SPY leg."
function book_weights(R; eq_scale = 1.0)
    Rp = ingredients(R); valid = findall(t -> all(isfinite, Rp[t, :]), 1:size(Rp, 1))
    b = risk_parity(cov(Rp[valid, :])); bAC, bC, bB, bT = b[1:5], b[6], b[7], b[8]
    Btr = hcat([col(R, s) for s in TREND_ASSETS]...); Bbo = hcat([col(R, s) for s in BORE_NAMES]...)
    tw = trend_weights_today(Btr); wbo, beta = bore_weights_today(Bbo, col(R, "SPY")); csig = crack_signal(col(R, "USO"))
    net = Dict{String,Float64}(); add!(s, x) = (net[s] = get(net, s, 0.0) + x)
    for (i, s) in enumerate(SPINE_AC);     add!(s, s == "SPY" ? bAC[i] * eq_scale : bAC[i]); end   # <- overlay trims static SPY only
    add!("CRAK", bC * csig)
    for (i, s) in enumerate(TREND_ASSETS); add!(s, bT * tw[i]); end
    for (i, s) in enumerate(BORE_NAMES);   add!(s, bB * wbo[i]); end
    add!("SPY", bB * (-beta)); net
end

# ---- causal walk-forward: FULL vs OVERLAY (regime from 63d SPY-IEF corr) ----
full = Float64[]; over = Float64[]; oosidx = Int[]
wf_prev = Dict{String,Float64}(); wo_prev = Dict{String,Float64}(); npos = 0; nderisk = 0
for t0 in WARMUP:REB:(T-1)
    spy = col(Rinst, "SPY")[t0-CORR_WIN+1:t0]; ief = col(Rinst, "IEF")[t0-CORR_WIN+1:t0]
    corr = (std(spy) > 0 && std(ief) > 0) ? cor(spy, ief) : 0.0
    scale = corr < 0 ? 1.0 : DERISK
    global npos += 1; corr < 0 || (global nderisk += 1)
    wf = book_weights(Rinst[1:t0, :]; eq_scale = 1.0)
    wo = book_weights(Rinst[1:t0, :]; eq_scale = scale)
    tf = sum(abs(get(wf, s, 0.0) - get(wf_prev, s, 0.0)) for s in union(keys(wf), keys(wf_prev)))
    to = sum(abs(get(wo, s, 0.0) - get(wo_prev, s, 0.0)) for s in union(keys(wo), keys(wo_prev)))
    for day in (t0+1):min(t0+REB, T)
        rf = sum(get(wf, s, 0.0) * Rinst[day, sidx[s]] for s in keys(wf))
        ro = sum(get(wo, s, 0.0) * Rinst[day, sidx[s]] for s in keys(wo))
        if day == t0 + 1; rf -= tf * COST; ro -= to * COST; end
        push!(full, rf); push!(over, ro); push!(oosidx, day)
    end
    global wf_prev = wf; global wo_prev = wo
end
S(x) = sharpe(collect(skipmissing(x)))

println("="^80, "\nKEEPER BOOK + bonds-regime overlay — does trimming the static equity leg help?\n", "="^80)
@printf("\n  window %s .. %s   OOS days %d   de-risked %d of %d rebalances (%.0f%%)\n",
        rdates[oosidx[1]], rdates[oosidx[end]], length(full), nderisk, npos, 100nderisk/npos)
@printf("  %-30s %8s %8s %8s\n", "book", "Sharpe", "CAGR", "maxDD")
@printf("  %-30s %+8.2f %7.1f%% %7.0f%%\n", "FULL keeper (as-is)", S(full), ann_return(full)*100, max_drawdown(full)*100)
@printf("  %-30s %+8.2f %7.1f%% %7.0f%%\n", "OVERLAY (regime-trimmed SPY)", S(over), ann_return(over)*100, max_drawdown(over)*100)

shF, shO = S(full), S(over); ddF, ddO = max_drawdown(full), max_drawdown(over)
println("\n  THE BAR (overlay must earn on-by-default):")
checks = [
    ("Sharpe not worse (>= FULL - 0.03)", shO >= shF - 0.03, @sprintf("%.2f vs %.2f", shO, shF)),
    ("reduces max drawdown",              ddO > ddF + 0.002,  @sprintf("%.1f%% vs %.1f%%", ddO*100, ddF*100)),
]
for (n, ok, v) in checks; @printf("    [%s] %-34s %s\n", ok ? "PASS" : "FAIL", n, v); end
allpass = all(c -> c[2], checks)
println("\n  DECISION (bonds-regime overlay on the keeper book): ", allpass ?
    "ON by default — the trim earns its place." :
    "OFF by default — the book is already risk-parity-diversified (bonds/gold/commodities + market-neutral\n           BORE + crisis-hedging TREND), so trimming the small static equity leg barely moves drawdown and\n           costs return. Wired in and available via BB_BONDS_OVERLAY=1; the honest endpoint of the pattern.")
