#!/usr/bin/env julia
# =============================================================================
# multi_sleeve_portfolio.jl — the diversification payoff of combining the family's
# FULL KEEPER SET through the engine's own PortfolioOpt optimizers.
#
# The Bio/Basel study showed you cannot MANUFACTURE cross-sectional alpha by
# optimizing correlated equity sectors. The real payoff of PortfolioOpt is
# DIVERSIFICATION across structurally different return drivers. So this demo drops
# the illustrative non-keeper sectors and assembles the validated asset-class spine
# plus every strategy KEEPER that can be reconstructed from daily bars, then runs
# risk-parity / min-variance / max-diversification / HRP / min-CVaR. The sleeve
# constructions live in the shared builder `keeper_ingredients.jl`:
#
#   asset-class spine (validated diversifiers):
#     SPY equity   IEF duration   GLD gold   DBC commodities   DBA agriculture
#   keeper strategy sleeves:
#     CRACK     crude->refiner lead-lag (long CRAK when crude up)
#     BORE      beta-hedged momentum-neutral over large caps
#     TREND     vol-scaled multi-horizon trend over the spine (convexity is FREE)
#     CAMPROT   brown/blue camp rotation (hold the stronger-trending camp)
#     DDBOUNCE  drawdown-bounce (long the most-fallen quality names)
#     BLOCK     cross-asset trend over all 4 derivative blocks incl. FX (Block's tradeable residue)
#     REGIME    drawdown-regime brake on equity (§3.4 — the mechanism the LIVE spine actually uses)
#     GAMMA_REG the actual Gamma-ARMA crisis detector wired in: module 4 (ARMA+GARCH vol / tail index)
#               + module 5 (DPM.detect_crisis_regime). These modules are present and importable; they
#               are simply excluded from the production validation gate and the live path (a separate
#               research lineage that showed no edge over the simpler drawdown brake).
#     BARBELL   Taleb 90/10 BIL/VIXY (PAID convexity — negative carry, crisis insurance)
#     CURVEBALL vol-gated reversed barbell (deploy long-vol only when vol is cheap)
#
# RESULTS AS TESTED (2017-2026, 1831 days, gross of costs; avg pairwise corr 0.09):
#   standalone Sharpe / maxDD  (skew, COVID-capture for the convex/regime ones):
#     SPY +0.81/-34  IEF +0.10/-24  GLD +0.93/-26  DBC +0.57/-35  DBA +0.67/-21
#     CRACK +1.12/-24  BORE +0.44/-23  TREND +0.72/-16  CAMPROT +0.86/-36  DDBOUNCE +1.00/-40
#     BLOCK +0.74/-17 (4-block cross-asset trend incl. FX; corr to TREND +0.84 — mostly redundant)
#     REGIME +0.78/-20  GAMMA_REG +1.13/-24 (corr 0.88, skew +0.14, COVID -8%; flags 2% of days, catches 67% of COVID)
#     BARBELL -0.23/-32 (skew +1.87, COVID +19%)  CURVEBALL -0.79/-86 (skew +1.36)
#   optimized book        Sharpe   CAGR   vol  maxDD
#     risk-parity          +1.66    5.6%   3%   -5%
#     max-diversification  +1.64    4.8%   3%   -4%
#     min-variance         +1.62    4.5%   3%   -5%
#     min-CVaR             +1.57    4.5%   3%   -4%
#     HRP                  +1.50    5.4%   4%   -6%
#     equal-weight         +1.43   10.3%   7%  -11%
#   best SINGLE ingredient: GAMMA_REG +1.13 at -24% DD.
#   risk-parity weights: BARBELL 29% | IEF 13% | BLOCK 10% | TREND 8% | REGIME 6% | BORE 5% | ... | CAMPROT 2%
# The honest read: three lessons. (1) The RETURN-earning keepers (CRACK/BORE/TREND/CAMPROT/DDBOUNCE)
# push the diversified book past the best single sleeve; the risk budget flows to the genuinely
# uncorrelated fragments (TREND corr -0.14, BORE -0.06), not the high-Sharpe beta sleeves. Folding in
# BLOCK (Block's 4-block cross-asset trend) shows the same point from the other side: it is 0.84-
# correlated to TREND, so the optimizer just SPLITS the trend budget between the two (BLOCK 10% + TREND
# 8%) and the book lifts only +1.60 -> +1.66 — that lift is the FX/dollar block, the single new axis
# Block carries; redundant sleeves don't earn new weight. (2) The two REGIME timers behave differently:
# the live drawdown brake (REGIME +0.78) catches slow drawdowns but whipsaws (skew -1.00); the actual
# Gamma-ARMA crisis detector (GAMMA_REG) flags only 2% of days yet catches 67% of the COVID crash, and
# is the BEST single ingredient (+1.13, COVID -8% vs SPY -33%) — it TIMES the tail cheaply rather than
# paying for it. Caveat: corr 0.88 to SPY (down-weighted as beta, ~4%), and its thresholds catch COVID
# IN-SAMPLE on one path — no forward proof, which is why the framework stays research and the LIVE spine
# trusts the simpler drawdown brake. (3) The PAID-convexity keepers (BARBELL/CURVEBALL) are negative-
# carry insurance (CURVEBALL alone a -86% ruin) that a variance/Sharpe objective MISPRICES: risk-parity
# hands BARBELL ~29% because it is low-vol and anti-correlated. Convexity must be BUDGETED, not optimized
# in — free convexity (TREND/BLOCK) the book earns; PAID convexity (long-vol) is a sizing decision, and
# timed convexity (GAMMA_REG) is seductive in-sample. (See hedge_saturation.jl for the convexity budget
# and negentropy_ranking.jl for why the optimizer weights independence, not standalone Sharpe.)
#
# Read-only (data only). Run:  julia --project=. scripts/research/multi_sleeve_portfolio.jl
# =============================================================================
using Statistics, LinearAlgebra, Printf
include(joinpath(@__DIR__, "keeper_ingredients.jl"))   # shared builder; also brings PortfolioOpt into scope

ing = build_ingredients()
labels, Rp, cvd, covid, gamma_crisis = ing.labels, ing.Rp, ing.cvd, ing.covid, ing.gamma_crisis
K = size(Rp, 2)

println("\n", "="^80, "\nMULTI-SLEEVE PORTFOLIO — engine PortfolioOpt on the FULL KEEPER SET\n", "="^80)
println("\nstandalone ingredients (5 asset classes + 10 keeper sleeves; last 2 are PAID convexity):")
@printf("  %-9s %7s %5s %6s %8s %6s %8s\n", "", "Sharpe", "vol", "maxDD", "corr-SPY", "skew", "COVID")
for j in 1:K
    r = Rp[:, j]
    @printf("  %-9s %+7.2f %4.0f%% %5.0f%% %+8.2f %+6.2f %7.0f%%\n",
            labels[j], sharpe(r), ann_vol(r)*100, max_drawdown(r)*100, cor(r, Rp[:,1]), skewf(r), covidret(r, covid)*100)
end
avgcorr = (sum(cor(Rp)) - K) / (K*(K-1))
@printf("\n  average pairwise correlation across ingredients: %.2f  (low = lots to diversify)\n", avgcorr)
gflag = gamma_crisis
@printf("\n  GAMMA_REG (real detector): flagged crisis on %d of %d days (%.0f%%); of the COVID-crash window it caught %.0f%%\n",
        sum(gflag), length(gflag), 100*mean(gflag), isempty(covid) ? 0.0 : 100*mean(gflag[covid]))
jb = findfirst(==("BLOCK"), labels); jt = findfirst(==("TREND"), labels)
@printf("  BLOCK vs TREND correlation: %+.2f  (high = the FX block adds little the spine-trend didn't already carry)\n",
        cor(Rp[:, jb], Rp[:, jt]))

Σ = cov(Rp)
books = [
    ("equal-weight",        fill(1/K, K)),
    ("risk-parity",         risk_parity(Σ)),
    ("min-variance",        min_variance(Σ)),
    ("max-diversification", max_diversification(Σ)),
    ("HRP",                 hrp_weights(Σ)),
    ("min-CVaR",            min_cvar(Rp)),
]
println("\noptimized books (long-only, full-invested; gross of costs):")
@printf("  %-20s %8s %7s %7s %8s\n", "optimizer", "Sharpe", "CAGR", "vol", "maxDD")
for (nm, wv) in books
    r = Rp * wv
    @printf("  %-20s %+8.2f %6.1f%% %6.0f%% %7.0f%%\n", nm, sharpe(r), ann_return(r)*100, ann_vol(r)*100, max_drawdown(r)*100)
end
best = argmax([sharpe(Rp[:, j]) for j in 1:K])
@printf("\n  best SINGLE ingredient: %s at Sharpe %+.2f, maxDD %.0f%%\n", labels[best], sharpe(Rp[:,best]), max_drawdown(Rp[:,best])*100)

println("\nrisk-parity weights (where the risk budget actually goes):")
for (l, wv) in sort(collect(zip(labels, risk_parity(Σ))), by = x -> -x[2])
    @printf("    %-9s %5.1f%%\n", l, wv*100)
end
println("\nread: three lessons. (1) The return keepers (CRACK/BORE/TREND/CAMPROT/DDBOUNCE) push the book")
println("past the best single sleeve; the risk budget flows to the uncorrelated fragments (TREND/BORE), not")
println("the high-Sharpe beta sleeves. Folding in BLOCK (Block's 4-block cross-asset trend) is 0.84-corr to")
println("TREND, so the optimizer just SPLITS the trend budget; the only new axis is the FX/dollar block")
println("(book +1.60 -> +1.66) — redundant sleeves don't earn new weight. (2) The two regime timers differ:")
println("the LIVE drawdown brake (REGIME) catches slow drawdowns but whipsaws; the Gamma-ARMA detector")
println("wired in here (GAMMA_REG, from module 4 tail-index/vol + module 5 detect_crisis_regime) flags")
println("~2% of days but catches ~67% of the COVID crash, and is the best single ingredient (+1.13) — it")
println("TIMES the tail cheaply. But it is 0.88 corr to SPY (down-weighted as beta) and its thresholds fit")
println("COVID IN-SAMPLE — no forward proof, which is why it stays research and the live spine trusts the")
println("simpler brake. (3) The PAID-convexity hedges (BARBELL/CURVEBALL) are negative-carry insurance a")
println("variance objective MISPRICES (BARBELL gets ~29%). Convexity must be BUDGETED: free (TREND) the")
println("book earns; PAID (long-vol) you size; TIMED (GAMMA_REG) is seductive in-sample. Diversification")
println("is the engine's edge, not manufactured alpha.")
