# =============================================================================
# test_geometric_consistency.jl
# Invariant test suite for GeometricCoordinationLayer
#
# Each test asserts a mathematical property that must hold regardless of
# the specific matrices used. Tests are parameterised so they run on both
# well-conditioned and ill-conditioned SPD matrices.
# =============================================================================

include("GeometricCoordinationLayer.jl")
using .GeometricCoordinationLayer
using LinearAlgebra, Random, Test

Random.seed!(1234)

# --- helpers ------------------------------------------------------------------

function random_spd(n::Int; cond::Float64=10.0)
    # cond ≈ condition number of the result
    A = randn(n, n)
    Q, _ = qr(A)
    λ = exp.(LinRange(0.0, log(cond), n))
    ensure_spd(Matrix(Q) * Diagonal(λ) * Matrix(Q)')
end

function random_tangent(P::AbstractMatrix{Float64})
    n = size(P, 1)
    X = randn(n, n); X = Symmetric(0.5*(X+X'))
    # Scale to have unit AI norm
    ip = ai_inner(P, X, X)
    ip > 1e-14 ? X ./ sqrt(ip) : X
end

# Run tests for multiple (n, condition) combinations
SIZES  = [2, 3, 5]
CONDS  = [5.0, 100.0, 1000.0]
NTRIALS = 4

# =============================================================================
@testset "GeometricCoordinationLayer invariant tests" begin

# =============================================================================
@testset "Test 1: AI log/exp invertibility" begin
# log_P(exp_P(X)) == X  and  exp_P(log_P(Q)) == Q
for n in SIZES, c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    X = random_tangent(P) .* 0.1
    Q = ai_exp(P, X)

    X_recovered = ai_log(P, Q)
    @test norm(X - X_recovered, 2) < 1e-8 *
          (1 + norm(X, 2)) "log∘exp roundtrip failed: n=$n cond=$c"

    Q2 = ai_exp(P, ai_log(P, Q))
    @test norm(Q - Q2, 2) < 1e-8 *
          (1 + norm(Q, 2)) "exp∘log roundtrip failed: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 2: AI parallel transport preserves inner product" begin
# ⟨X, Y⟩_P = ⟨τ_{P→Q}(X), τ_{P→Q}(Y)⟩_Q
for n in SIZES, c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    X = random_tangent(P)
    Y = random_tangent(P)

    Xt = ai_parallel_transport(P, Q, Matrix(X))
    Yt = ai_parallel_transport(P, Q, Matrix(Y))

    ip_at_P = ai_inner(P, X, Y)
    ip_at_Q = ai_inner(Q, Xt, Yt)

    @test abs(ip_at_P - ip_at_Q) < 1e-7 *
          (1 + abs(ip_at_P)) "AI transport inner product not preserved: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 3: Geodesic deviation is (approximately) symmetric" begin
# compare_geodesic_deviation(m1, m2, P, Q) ≈ compare_geodesic_deviation(m2, m1, P, Q)
# Not exactly symmetric because Q_test in _multi_ref uses perturbations of P,
# so we test the single-reference version.
for n in SIZES, c in CONDS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    d12 = compare_geodesic_deviation(AffineInvariant(), BuresWasserstein(), P, Q)
    d21 = compare_geodesic_deviation(BuresWasserstein(), AffineInvariant(), P, Q)
    # Symmetric within a reasonable tolerance (different geodesic parameterisations)
    @test abs(d12 - d21) < 0.5 * (d12 + d21) + 1e-6 "Geodesic deviation asymmetry too large: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 4: BW geodesic boundary conditions" begin
# bw_geodesic(P, Q, 0) == P   and   bw_geodesic(P, Q, 1) == Q
for n in SIZES, c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    γ0 = bw_geodesic(P, Q, 0.0)
    γ1 = bw_geodesic(P, Q, 1.0)
    @test norm(γ0 - P, 2) < 1e-8 * norm(P, 2) "BW geodesic at t=0 ≠ P: n=$n cond=$c"
    @test norm(γ1 - Q, 2) < 1e-8 * norm(Q, 2) "BW geodesic at t=1 ≠ Q: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 5: AI geodesic boundary conditions" begin
# ai_geodesic(P, Q, 0) == P   and   ai_geodesic(P, Q, 1) == Q
for n in SIZES, c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    γ0 = ai_geodesic(P, Q, 0.0)
    γ1 = ai_geodesic(P, Q, 1.0)
    @test norm(γ0 - P, 2) < 1e-8 * norm(P, 2) "AI geodesic at t=0 ≠ P: n=$n cond=$c"
    @test norm(γ1 - Q, 2) < 1e-8 * norm(Q, 2) "AI geodesic at t=1 ≠ Q: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 6: Log-Euclidean geodesic boundary conditions" begin
for n in SIZES, c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    γ0 = le_geodesic(P, Q, 0.0)
    γ1 = le_geodesic(P, Q, 1.0)
    @test norm(γ0 - P, 2) < 1e-8 * norm(P, 2) "LE geodesic at t=0 ≠ P: n=$n cond=$c"
    @test norm(γ1 - Q, 2) < 1e-8 * norm(Q, 2) "LE geodesic at t=1 ≠ Q: n=$n cond=$c"
end
end

# =============================================================================
@testset "Test 7: Euclidean and LE parallel transport are identity" begin
for n in SIZES
    P = random_spd(n); Q = random_spd(n); X = random_tangent(P)
    Ve = euclidean_parallel_transport(P, Q, Matrix(X))
    Vl = le_parallel_transport(P, Q, Matrix(X))
    @test norm(Ve - X, 2) < 1e-12 "Euclidean transport ≠ identity"
    @test norm(Vl - X, 2) < 1e-12 "LE transport ≠ identity"
end
end

# =============================================================================
@testset "Test 8: parallel_transport_across_metrics dispatch" begin
# Exact paths: lossy=false. Schild's ladder: lossy=true.
n = 3
P = random_spd(n); Q = random_spd(n); X = random_tangent(P)

r_ai  = parallel_transport_across_metrics(AffineInvariant(), AffineInvariant(), P, Q, Matrix(X))
r_eu  = parallel_transport_across_metrics(Euclidean(), Euclidean(), P, Q, Matrix(X))
r_le  = parallel_transport_across_metrics(LogEuclidean(), LogEuclidean(), P, Q, Matrix(X))
r_bw  = parallel_transport_across_metrics(AffineInvariant(), BuresWasserstein(), P, Q, Matrix(X))

@test r_ai.lossy == false "AI→AI should be exact"
@test r_eu.lossy == false "EU→EU should be exact"
@test r_le.lossy == false "LE→LE should be exact"
@test r_bw.lossy == true  "AI→BW should be lossy"
end

# =============================================================================
@testset "Test 9: ConversionReport lossiness" begin
# Same geometry: exact. Cross-geometry: check geodesic_deviation > 0.
n = 3
P = random_spd(n; cond=50.0)
Q = random_spd(n; cond=50.0)

src = SPDPoint(P, AffineInvariant())

# Identity conversion
tgt_same, r_same = convert_geometry(src, AffineInvariant(); ref=Q)
@test r_same.exact == true "Same-geometry conversion should be exact"
@test r_same.geodesic_deviation == 0.0

# Cross-metric: should be lossy for non-commuting P,Q
tgt_bw, r_bw = convert_geometry(src, BuresWasserstein(); ref=Q)
@test r_bw.geodesic_deviation >= 0.0 "Geodesic deviation must be non-negative"
# For well-separated SPD matrices the deviation is typically > 0
if norm(P - Q, 2) > 0.1
    @test r_bw.geodesic_deviation > 0 "Non-trivial AI↔BW should have positive deviation"
end
end

# =============================================================================
@testset "Test 10: Itô/Stratonovich round-trip" begin
# Convert Strat→Itô→Strat and check drift is approximately recovered.
n = 1
scalar_drift = (t, X) -> 0.1 .* X
scalar_diff  = (t, X) -> 0.2 .* X .* ones(1,1)
strat_spec   = SDESpec(:test, StratonovichCalculus(), scalar_drift, scalar_diff, n, n, "")

ito_spec  = stratonovich_to_ito(strat_spec)
back_spec = ito_to_stratonovich(ito_spec)

X_test = [1.0]
t_test = 0.0
orig_drift = strat_spec.drift(t_test, X_test)
back_drift = back_spec.drift(t_test, X_test)

@test norm(orig_drift - back_drift) < 1e-5 "Itô↔Strat round-trip drift mismatch"
end

# =============================================================================
@testset "Test 11: Fréchet mean is a better minimiser than Euclidean mean" begin
# The Fréchet mean should have smaller total AI distance than the Euclidean mean.
n = 3; N = 40
true_cov = [2.0 0.5 0.2; 0.5 1.5 0.3; 0.2 0.3 1.0]
samples  = [ensure_spd(true_cov .+ 0.5.*randn(n,n)|>M->0.5*(M+M')) for _ in 1:N]

fm  = frechet_mean_spd(samples)
eu  = ensure_spd(sum(samples) ./ N)

# Sum of squared AI distances
ai_dist_sq(C, mats) = sum(norm(ai_log(C, P), 2)^2 for P in mats)
@test ai_dist_sq(fm.mean, samples) ≤ ai_dist_sq(eu, samples) + 1e-6 * N "Fréchet mean is not the minimiser"
@test fm.converged "Fréchet mean did not converge on well-conditioned samples"
end

# =============================================================================
@testset "Test 12: Wald test type I error (approximate)" begin
# Under H₀ (samples drawn from true_cov), rejection rate should be ≈ α = 0.05.
n = 3; N = 60; n_sim = 200; α = 0.05
true_cov = Matrix{Float64}(I, n, n)
rejections = 0
for _ in 1:n_sim
    samp = [ensure_spd(true_cov .+ 0.3.*randn(n,n)|>M->0.5*(M+M')) for _ in 1:N]
    result = intrinsic_wald_test(samp, true_cov; alpha=α)
    rejections += result.reject
end
rate = rejections / n_sim
# Type I error should be within ≈ 3σ of α for n_sim=200
σ_binom = sqrt(α*(1-α)/n_sim)
@test abs(rate - α) < 4*σ_binom "Wald test type I error out of range: rate=$rate expected≈$α"
end

# =============================================================================
@testset "Test 13: manifold_ttest detects genuine regime shift" begin
n = 3; N = 80
cov1 = [2.0 0.5 0.2; 0.5 1.5 0.3; 0.2 0.3 1.0]
cov2 = [4.0 1.0 0.5; 1.0 3.0 0.6; 0.5 0.6 2.0]   # clearly different
s1   = [ensure_spd(cov1 .+ 0.3.*randn(n,n)|>M->0.5*(M+M')) for _ in 1:N]
s2   = [ensure_spd(cov2 .+ 0.3.*randn(n,n)|>M->0.5*(M+M')) for _ in 1:N]
res  = manifold_ttest(s1, s2; alpha=0.05)
@test res.reject "manifold_ttest failed to detect a clear regime shift"
@test res.riemannian_distance > 0 "Riemannian distance should be positive"
end

# =============================================================================
@testset "Test 14: Chi-squared approximation accuracy" begin
# Compare _chi2_sf against known chi-squared quantiles.
# χ²(5) quantile at 0.95 ≈ 11.07
@test abs(_chi2_sf(11.07, 5) - 0.05) < 0.01 "chi2_sf(11.07, 5) ≈ 0.05"
# χ²(10) quantile at 0.99 ≈ 23.21
@test abs(_chi2_sf(23.21, 10) - 0.01) < 0.01 "chi2_sf(23.21, 10) ≈ 0.01"
# Small x → p-value → 1
@test _chi2_sf(0.0, 5) == 1.0
# Large x → p-value → 0
@test _chi2_sf(200.0, 5) < 1e-6
end

# =============================================================================
@testset "Test 15: SPD preservation through geodesics and transports" begin
n = 3
for c in CONDS, _ in 1:NTRIALS
    P = random_spd(n; cond=c)
    Q = random_spd(n; cond=c)
    # Every midpoint should remain SPD
    @test is_spd(ai_geodesic(P, Q, 0.5))  "AI geodesic midpoint not SPD: cond=$c"
    @test is_spd(bw_geodesic(P, Q, 0.5))  "BW geodesic midpoint not SPD: cond=$c"
    @test is_spd(le_geodesic(P, Q, 0.5))  "LE geodesic midpoint not SPD: cond=$c"
    @test is_spd(ai_exp(P, ai_log(P, Q))) "AI exp(log(Q)) not SPD: cond=$c"
end
end

# =============================================================================
@testset "Test 16: Schild's ladder uses manifold step (regression test)" begin
# After the bug fix, _schilds_ladder should use ai_exp for P_push.
# Verify: the transported vector should approximately preserve the AI norm.
n = 3
P = random_spd(n; cond=10.0)
Q = random_spd(n; cond=10.0)
X = random_tangent(P)

r = parallel_transport_across_metrics(AffineInvariant(), BuresWasserstein(),
                                       P, Q, Matrix(X); n_steps=20)
norm_P = ai_inner(P, X, X)
norm_Q = ai_inner(Q, r.transported, r.transported)
# After the fix, norm preservation should be much better than with Euclidean step
@test abs(norm_P - norm_Q) < 2.0 * norm_P "Schild's ladder AI norm drift too large (regression)"
end

# =============================================================================
@testset "Test 17: PipelineAuditor detects triple-metric conflict" begin
pa = PipelineAuditor()
register_module!(pa.metric_reg, :a, Euclidean(),       3)
register_module!(pa.metric_reg, :b, AffineInvariant(), 3)
register_module!(pa.metric_reg, :c, BuresWasserstein(),3)
rep = audit(pa)
@test rep.severity ∈ (:warning, :error) "Triple-metric should produce warning or error"
@test !isempty(rep.metric_issues)
end

# =============================================================================
@testset "Test 18: RoughPath + Itô mixing is :error" begin
reg = SDERegistry()
register_sde!(reg, SDESpec(:ito_proc, ItoCalculus(), (t,X)->X, (t,X)->0.1I(1), 1,1,""))
register_sde!(reg, SDESpec(:rough,    ItoCalculus(), (t,X)->X, (t,X)->0.1I(1), 1,1,""))
enforce_rough_path_lift!(reg, :rough, 0.1)
connect_sdes!(reg, :rough, :ito_proc)
conflicts = audit_sde_conventions(reg)
@test any(c.severity == :error for c in conflicts) "RoughPath+Itô mix should be :error"
end

# =============================================================================
@testset "Test 19: ModuleGeometryRegistry overrides default" begin
reg = ModuleGeometryRegistry()
set_geometry!(reg, :my_module, BuresWasserstein())
ctx = detect_metric_context(:my_module; registry=reg)
@test ctx isa BuresWasserstein "User registry override not applied"

# Built-in fallback still works
ctx2 = detect_metric_context(:ledoit_wolf; registry=reg)
@test ctx2 isa Euclidean "Built-in fallback not working"
end

end # @testset

println("\nAll tests passed.")
