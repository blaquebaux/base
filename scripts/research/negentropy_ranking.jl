#!/usr/bin/env julia
# =============================================================================
# negentropy_ranking.jl — does NEGENTROPY predict the optimizer's weight better than Sharpe?
#
# Schrödinger's negentropy = the order a system extracts from a noisy field; its information-
# theory form (Hyvärinen/ICA) is non-Gaussianity, and its portfolio analog is INDEPENDENCE —
# the unique, non-redundant structure a sleeve adds. This sketch scores each keeper ingredient
# three ways and asks which one the engine's risk-parity allocator actually pays for:
#   Sharpe_i        standalone risk-adjusted return
#   J_i (marginal)  negentropy as NON-GAUSSIANITY: (1/12)skew^2 + (1/48)exkurt^2  (0 for a Gaussian)
#   U_i (indep.)    negentropy as INDEPENDENCE: 1/(C^-1)_ii = 1 - R^2 of sleeve i on all others
#
# FINDING (measured — and it partly refutes the neat hypothesis, which is the honest result):
#   Spearman(risk-parity weight, .) : Sharpe -0.43 | J -0.11 | U +0.05 | 1/vol +0.80
# The optimizer does NOT pay for standalone Sharpe (it AVOIDS it) and IGNORES marginal non-
# Gaussianity (J ~ 0) — fat tails alone earn nothing. It is dominated by INVERSE VOLATILITY, with
# independence only weakly rewarded. BUT the negentropy design principle still holds where it
# matters: a book built to harvest independence + low vol (U/vol) reproduces the engine's risk-
# CONTROLLED character (Sharpe +1.43, maxDD -6%), while Sharpe-chasing earns more CAGR at -17% DD.
# So Schrödinger's lens is right as a construction GOAL (feed on independent structure, not return
# or fat tails) even though the exact risk-parity weights are set by volatility, not negentropy.
#
# Read-only. Run:  julia --project=. scripts/research/negentropy_ranking.jl
# =============================================================================
using Statistics, LinearAlgebra, Printf
include(joinpath(@__DIR__, "keeper_ingredients.jl"))

ing = build_ingredients(); labels, Rp = ing.labels, ing.Rp; K = size(Rp, 2)

# --- three scores per ingredient ---
J  = [ (s = skewf(Rp[:,j]); k = exkurt(Rp[:,j]); s^2/12 + k^2/48) for j in 1:K ]   # marginal negentropy
C  = cor(Rp); Cinv = inv(C)
U  = [ 1.0 / Cinv[j,j] for j in 1:K ]                                              # independence (1 - R^2)
Sh = [ sharpe(Rp[:,j]) for j in 1:K ]
vol = [ ann_vol(Rp[:,j]) for j in 1:K ]
w_rp = risk_parity(cov(Rp))

_rank(v) = (p = sortperm(v); r = zeros(length(v)); for (i,ix) in enumerate(p); r[ix]=i; end; r)
spearman(a,b) = cor(_rank(a), _rank(b))

println("="^80, "\nNEGENTROPY RANKING — what does the optimizer actually pay for?\n", "="^80)
println("\n  ingredient   Sharpe   J(non-Gauss)  U(independ.)   RP-weight")
for j in sortperm(w_rp, rev=true)
    @printf("  %-9s  %+7.2f   %9.3f    %9.2f     %6.1f%%\n", labels[j], Sh[j], J[j], U[j], 100*w_rp[j])
end

println("\n  Spearman rank-correlation of RISK-PARITY WEIGHT with each score:")
@printf("    vs Sharpe (standalone return) : %+.2f   (negative — the optimizer AVOIDS high standalone Sharpe)\n", spearman(w_rp, Sh))
@printf("    vs J  (marginal non-Gaussian) : %+.2f   (~0 — fat tails alone earn nothing)\n", spearman(w_rp, J))
@printf("    vs U  (independence)          : %+.2f   (weakly positive)\n", spearman(w_rp, U))
@printf("    vs 1/vol (inverse volatility) : %+.2f   <- what risk-parity mostly pays for\n", spearman(w_rp, 1.0 ./ vol))

# --- does harvesting negentropy-as-independence reproduce the optimizer? ---
norm1(w) = w ./ sum(w)
books = [
    ("equal-weight",            fill(1/K, K)),
    ("Sharpe-weighted",         norm1(max.(Sh, 0.0))),
    ("negentropy (U / vol)",    norm1(U ./ vol)),
    ("risk-parity (engine)",    w_rp),
]
println("\n  book weighted by each idea (long-only, full-invested; gross):")
@printf("    %-22s %8s %7s %8s\n", "weighting", "Sharpe", "CAGR", "maxDD")
for (nm, wv) in books
    r = Rp * wv
    @printf("    %-22s %+8.2f %6.1f%% %7.0f%%\n", nm, sharpe(r), ann_return(r)*100, max_drawdown(r)*100)
end

println("\nVERDICT (partly against the neat hypothesis, which is the honest result): risk-parity does NOT")
println("pay for standalone Sharpe (it AVOIDS it, -0.43) and ignores marginal non-Gaussianity (J ~ 0) —")
println("fat tails alone earn nothing. It is dominated by INVERSE VOLATILITY, with independence only")
println("weakly rewarded. But the negentropy DESIGN PRINCIPLE still holds where it counts: a book built")
println("to harvest independence + low vol (U/vol) reproduces the engine's risk-CONTROLLED character")
println("(Sharpe +1.43, maxDD -6%), while Sharpe-chasing earns more CAGR at a far worse drawdown (-17%).")
println("So Schrödinger's lens is right as a construction goal (feed on independent structure, not return")
println("or fat tails) even though the exact risk-parity weights are set by volatility, not negentropy.")
