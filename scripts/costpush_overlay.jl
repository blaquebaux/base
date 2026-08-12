#!/usr/bin/env julia
# ============================================================================
# costpush_overlay.jl — does the cost-push sleeve (near-miss standalone, ~+0.16 net) ADD VALUE as an OVERLAY
# on the validated KEEPER BOOK? A low-Sharpe, beta~0 stream still improves a portfolio if it is UNCORRELATED:
# adding sleeve C to book K improves the combined Sharpe iff  S_C > corr(K,C) * S_K.  This measures corr(K,C)
# on the SAME walk-forward date grid and reports the tangency (max-Sharpe) combination + an allocation sweep.
# Reuses the keeper_book_validation machinery so both OOS streams are causal, net of cost, date-aligned.
#
# RESULT — the overlay does NOT rescue cost-push:
#   * corr(keeper, cost-push) = -0.01 -> genuinely UNCORRELATED (the diversification is real), so it technically
#     "adds value" (S_C > corr*S_K). BUT the uplift is +0.1% (tangency +1.28 vs keeper-alone +1.28): an
#     uncorrelated stream's contribution is BOUNDED BY ITS OWN SHARPE, and cost-push's is ~0 over this window.
#     Cost-push also carries 12% vol vs the keeper's 5%, so any real weight (>=0.2) HURTS. Optimal mix ~9%, adds
#     nothing. Diversification != additive when the diversifier's own Sharpe is ~0.
# Two more rescue levers were tested and also failed (research: bulgar_costpush_lag.py context):
#   * BREADTH (fundamental law): widening to 4 suppliers x 12 packaged-food names LOWERED Sharpe (+0.36->+0.17),
#     because HSY/SJM/HRL/MKC etc. buy cocoa/coffee/protein/spices, NOT corn sweetener — wrong input exposure
#     dilutes the IC. That only the corn-linked 5 (KO/PEP/MDLZ/GIS/KHC) respond CONFIRMS the mechanism is real
#     and specific. * HOLDING HORIZON: matching hold to the slow (63-126d) lag did NOT help — best is still a
#     21d hold; longer holds decay to ~0.
# CONCLUSION: cost-push is real, uncorrelated, market-neutral, and mechanism-specific, but its net Sharpe
# (~+0.16 fully-costed to ~+0.30 lightly-costed) is too low to bank standalone OR as an overlay. A documented
# risk/tilt input, not a sleeve. Thread exhausted without overfitting. Read-only (data only).
#   Run:  julia --project=. scripts/costpush_overlay.jl
# ============================================================================
using Statistics, LinearAlgebra, Dates, Printf
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "scripts/research/keeper_ingredients.jl"))    # fetch_closes, compute_*, sleeve math, risk_parity, sharpe
include(joinpath(REPO, "src/module_11_cv/purged_kfold.jl")); using .PurgedKFold

const SPINE_AC     = ["SPY", "IEF", "GLD", "DBC", "DBA"]
const TREND_ASSETS = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const BORE_NAMES   = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                      "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const CP_SUP  = ["INGR", "ADM"]; const CP_CUST = ["KO", "PEP", "MDLZ", "GIS", "KHC"]; const CP_LB = 63
const DATA_UNIVERSE = unique(vcat(SPINE_AC, TREND_ASSETS, ["CRAK", "USO"], BORE_NAMES, CP_SUP, CP_CUST))
const COST = parse(Float64, get(ENV, "BB_COST_BPS", "5")) / 1e4
const REB, WARMUP = 21, 380

@info "fetching $(length(DATA_UNIVERSE)) instruments..."
D = Dict(s => fetch_closes(s) for s in DATA_UNIVERSE)
dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
Rinst = hcat([(p = [D[s][d] for d in dates]; p[2:end] ./ p[1:end-1] .- 1) for s in DATA_UNIVERSE]...)
rdates = dates[2:end]; T = size(Rinst, 1); sidx = Dict(s => i for (i, s) in enumerate(DATA_UNIVERSE))
col(R, s) = R[:, sidx[s]]

function ingredients(R)
    ac = [col(R, s) for s in SPINE_AC]
    cser = compute_crack(col(R, "USO"), col(R, "CRAK"), size(R, 1))
    tser = compute_trend(hcat([col(R, s) for s in TREND_ASSETS]...), size(R, 1))
    bser = compute_bore(hcat([col(R, s) for s in BORE_NAMES]...), col(R, "SPY"), size(R, 1))
    hcat(ac..., cser, bser, tser)
end
function book_weights(R)
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
function costpush_weights(R)                                  # short customers when suppliers strong, SPY-hedged
    Tr = size(R, 1); supl = cumprod(1 .+ vec(mean(hcat([col(R, s) for s in CP_SUP]...), dims = 2)))
    sgn(tt) = tt > CP_LB && (supl[tt] / supl[tt-CP_LB] - 1) > 0 ? -1.0 : 0.0
    Nc = length(CP_CUST); w = fill(sgn(Tr) / Nc, Nc); C = hcat([col(R, s) for s in CP_CUST]...); spy = col(R, "SPY")
    cut = fill(NaN, Tr); sg = sgn(CP_LB + 1)
    for tt in (CP_LB+1):(Tr-1); (tt - (CP_LB + 1)) % 21 == 0 && (sg = sgn(tt)); cut[tt+1] = sg * mean(C[tt+1, :]); end
    y = cut[max(1, Tr-59):Tr]; x = spy[max(1, Tr-59):Tr]; m = .!isnan.(y)
    beta = (sum(m) > 20 && var(x[m]) > 0) ? clamp(cov(y[m], x[m]) / var(x[m]), -3.0, 3.0) : 0.0
    gw = sum(abs, w); s = gw > 1e-6 ? 1.0 / gw : 0.0
    net = Dict{String,Float64}(); for (i, sym) in enumerate(CP_CUST); net[sym] = get(net, sym, 0.0) + s * w[i]; end
    net["SPY"] = get(net, "SPY", 0.0) + s * (-beta); net
end

# ---- dual causal walk-forward, both books on the SAME oos dates ----
oosK = Float64[]; oosC = Float64[]; oosidx = Int[]; wpK = Dict{String,Float64}(); wpC = Dict{String,Float64}()
for t0 in WARMUP:REB:(T-1)
    wK = book_weights(Rinst[1:t0, :]); wC = costpush_weights(Rinst[1:t0, :])
    tK = sum(abs(get(wK, s, 0.0) - get(wpK, s, 0.0)) for s in union(keys(wK), keys(wpK)))
    tC = sum(abs(get(wC, s, 0.0) - get(wpC, s, 0.0)) for s in union(keys(wC), keys(wpC)))
    for day in (t0+1):min(t0+REB, T)
        rK = sum(get(wK, s, 0.0) * Rinst[day, sidx[s]] for s in keys(wK))
        rC = sum(get(wC, s, 0.0) * Rinst[day, sidx[s]] for s in keys(wC))
        day == t0 + 1 && (rK -= tK * COST; rC -= tC * COST)
        push!(oosK, rK); push!(oosC, rC); push!(oosidx, day)
    end
    global wpK = wK; global wpC = wC
end

S(x) = sharpe(collect(skipmissing(x))); vol(x) = std(x) * sqrt(252)
sK, sC = S(oosK), S(oosC); rho = cor(oosK, oosC)
# two-asset tangency (max-Sharpe) combination:
tang = sqrt(max(0.0, (sK^2 - 2rho*sK*sC + sC^2) / (1 - rho^2)))
# optimal cost-push weight in KEEPER-VOL units (w* on vol-normalized streams), then translate to notional
knorm = oosK ./ std(oosK); cnorm = oosC ./ std(oosC)
μk, μc = mean(knorm), mean(cnorm)
Σ = cov(hcat(knorm, cnorm)); wopt = Σ \ [μk, μc]; wopt ./= sum(abs, wopt)  # tangency weights (normalized)

println("="^78, "\nCOST-PUSH as an OVERLAY on the KEEPER BOOK — does an uncorrelated near-miss add value?\n", "="^78)
@printf("\n  window %s .. %s   OOS days %d\n", rdates[oosidx[1]], rdates[oosidx[end]], length(oosK))
@printf("  keeper book   : Sharpe %+.2f  vol %.1f%%\n", sK, vol(oosK)*100)
@printf("  cost-push     : Sharpe %+.2f  vol %.1f%%\n", sC, vol(oosC)*100)
@printf("  corr(keeper, cost-push) = %+.2f     [adds value iff S_C > corr*S_K = %+.2f]\n", rho, rho*sK)
@printf("  -> cost-push %s the book (%.2f %s %.2f)\n",
        sC > rho*sK ? "ADDS to" : "does NOT add to", sC, sC > rho*sK ? ">" : "<=", rho*sK)

println("\n  allocation sweep — combined = keeper + w * cost-push (w in keeper-notional units), net:")
@printf("    %-6s %8s %8s %8s\n", "w", "Sharpe", "vol", "dSharpe")
for w in (0.0, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0)
    comb = oosK .+ w .* oosC; @printf("    %-6.2f %+8.2f %7.1f%% %+8.2f\n", w, S(comb), vol(comb)*100, S(comb) - sK)
end
@printf("\n  tangency (max-Sharpe) combination: Sharpe %+.2f  (keeper-alone %+.2f -> %+.1f%% uplift)\n",
        tang, sK, (tang/sK - 1)*100)
@printf("  optimal mix (vol-normalized): keeper %.0f%% / cost-push %.0f%%\n", 100*wopt[1], 100*wopt[2])
