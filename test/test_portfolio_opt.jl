module TestPortfolioOpt

# Gate tests for the module-13 PortfolioOpt optimizers (src/module_13_portfolio):
# the Markowitz family (min_variance, max_sharpe, mean_variance), the risk-based
# allocators (risk_parity, max_diversification, inverse_variance, risk_contributions),
# and Black-Litterman blending. Each test anchors the solver output to a closed-form
# ground truth, not to historical numbers. Deterministic: no network, no market data.
#
# Closed forms used:
#   diagonal Sigma => min_variance (unconstrained) == inverse_variance (w ~ 1/sigma_i^2)
#   diagonal Sigma => max_diversification == risk_parity == inverse-vol (w ~ 1/sigma_i)
#   2-asset        => min_variance == Sigma^-1 1 / (1' Sigma^-1 1)
#   diagonal Sigma => max_sharpe tangency w ~ mu_i / sigma_i^2
#   Black-Litterman: no-confidence views => posterior mean -> prior; a confident
#                    absolute view => posterior mean -> the view.

using Test, LinearAlgebra, Random

include("../src/module_13_portfolio/module_13_portfolio.jl")
using .PortfolioOptModule

const ATOL = 1e-4   # Clarabel converges well inside this on these small problems

# A clean diagonal world with three distinct vols.
const SIG  = [0.10, 0.20, 0.40]
const SD   = Diagonal(SIG .^ 2) |> Matrix          # diagonal covariance
const INVV = (1 ./ SIG .^ 2) ./ sum(1 ./ SIG .^ 2) # inverse-variance weights
const INVS = (1 ./ SIG)       ./ sum(1 ./ SIG)     # inverse-vol weights

@testset "budget + simplex: every optimizer returns a valid weight vector" begin
    for w in (min_variance(SD), max_diversification(SD), risk_parity(SD),
              inverse_variance(SD), max_sharpe([0.05, 0.08, 0.12], SD),
              mean_variance([0.05, 0.08, 0.12], SD; risk_aversion = 3.0))
        @test sum(w) ≈ 1.0 atol = ATOL
        @test all(w .>= -ATOL)                # long-only by default
        @test length(w) == 3
    end
end

@testset "min_variance — closed forms" begin
    # Diagonal, long-only inactive => global MV equals inverse-variance weights.
    @test min_variance(SD; long_only = false) ≈ INVV atol = ATOL
    # 2-asset analytic: w = Σ⁻¹𝟙 / 𝟙ᵀΣ⁻¹𝟙 (correlated case).
    Σ2 = [0.04 0.01; 0.01 0.09]
    z  = Σ2 \ ones(2); analytic = z ./ sum(z)
    @test min_variance(Σ2; long_only = false) ≈ analytic atol = ATOL
    # MV is the lowest-variance budgeted portfolio: no equal-weight beats it.
    w_mv = min_variance(SD; long_only = false)
    ew   = fill(1/3, 3)
    @test dot(w_mv, SD * w_mv) <= dot(ew, SD * ew) + ATOL
end

@testset "inverse_variance / max_diversification / risk_parity — diagonal ground truth" begin
    @test inverse_variance(SD)   ≈ INVV atol = ATOL     # exact, no solver
    @test max_diversification(SD) ≈ INVS atol = 1e-3    # MDP on uncorrelated == inverse-vol
    @test risk_parity(SD)         ≈ INVS atol = 1e-3    # ERC on uncorrelated == inverse-vol
end

@testset "risk_contributions — equalized under risk parity, and sum to vol" begin
    w  = risk_parity(SD)
    rc = risk_contributions(w, SD)
    @test sum(rc) ≈ sqrt(dot(w, SD * w)) atol = ATOL    # contributions sum to portfolio vol
    shares = rc ./ sum(rc)
    @test all(abs.(shares .- 1/3) .< 1e-2)              # each asset ~ equal risk share
end

@testset "max_sharpe — diagonal tangency direction + guard" begin
    μ = [0.06, 0.10, 0.20]
    w = max_sharpe(μ, SD; long_only = false)
    tangency = (SD \ μ); tangency ./= sum(tangency)     # w ∝ Σ⁻¹μ
    @test w ≈ tangency atol = 1e-3
    # Undefined when no asset clears the risk-free rate.
    @test_throws ErrorException max_sharpe([0.01, 0.02, 0.03], SD; rf = 0.05)
end

@testset "mean_variance — formulations behave" begin
    μ = [0.05, 0.08, 0.12]
    # target_return: constraint is met (within solver tol) ...
    wt = mean_variance(μ, SD; target_return = 0.09, long_only = false)
    @test dot(μ, wt) >= 0.09 - ATOL
    # ... and no args reduces to the minimum-variance portfolio.
    @test mean_variance(μ, SD; long_only = false) ≈ min_variance(SD; long_only = false) atol = ATOL
    # Large risk aversion pushes the solution toward min-variance.
    wλ = mean_variance(μ, SD; risk_aversion = 1e6, long_only = false)
    @test wλ ≈ min_variance(SD; long_only = false) atol = 1e-3
end

@testset "black_litterman — prior/posterior limits" begin
    w_mkt = fill(1/3, 3)
    Π = implied_equilibrium_returns(SD, w_mkt; δ = 2.5)
    @test Π ≈ 2.5 .* (SD * w_mkt) atol = ATOL           # exact reverse-optimization

    P, q = make_view(3, [1], 0.25)                      # absolute view: asset 1 returns 25%
    Pmat = reshape(P, 1, 3); Q = [q]

    # No confidence (huge Ω): posterior mean collapses to the prior.
    μ_weak, _ = black_litterman(SD, Π, Pmat, Q; Ω = fill(1e6, 1, 1))
    @test μ_weak ≈ Π atol = 1e-3

    # Full confidence (tiny Ω): posterior mean for the viewed asset -> the view.
    μ_strong, _ = black_litterman(SD, Π, Pmat, Q; Ω = fill(1e-10, 1, 1))
    @test μ_strong[1] ≈ 0.25 atol = 1e-3
end

end # module TestPortfolioOpt
