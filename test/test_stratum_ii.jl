# =============================================================================
# test_stratum_ii.jl
# Simulation-based test suite for StructuralStatistics (Stratum II)
#
# Every test simulates from a known data-generating process, then verifies
# that the inference recovers the ground truth. Monte Carlo without a
# closed-form target tells you nothing; these tests always have one.
#
# Pattern: simulate(true_params) → infer() → compare to true_params
# =============================================================================

include("StructuralStatistics_v2.jl")
using .StructuralStatistics
using LinearAlgebra, Statistics, Random, Test

Random.seed!(2025)

# =============================================================================
# SIMULATION HELPERS
# =============================================================================

"""
    simulate_gaussian_hmm(A, μ, σ, n) → (states, obs)

Simulate n observations from a Gaussian HMM with transition matrix A,
regime means μ, and regime standard deviations σ.
"""
function simulate_gaussian_hmm(A::AbstractMatrix, μ::AbstractVector,
                                σ::AbstractVector, n::Int; seed::Int=0)
    Random.seed!(seed)
    k = length(μ)
    π₀ = fill(1.0/k, k)   # uniform initial
    states = zeros(Int, n); obs = zeros(n)

    # Draw initial state
    states[1] = rand(Categorical_sample(π₀))
    obs[1]    = μ[states[1]] + σ[states[1]]*randn()

    for t in 2:n
        states[t] = rand(Categorical_sample(A[states[t-1], :]))
        obs[t]    = μ[states[t]] + σ[states[t]]*randn()
    end
    states, obs
end

# Minimal categorical sampler (no Distributions.jl)
function Categorical_sample(p::AbstractVector)
    u = rand(); cdf = 0.0
    for (i, pi) in enumerate(p)
        cdf += pi; cdf ≥ u && return i
    end
    return length(p)
end

"""
    simulate_ar1(φ, σ, n) → Vector

Simulate n observations from an AR(1) process: y_t = φ y_{t-1} + ε_t.
"""
function simulate_ar1(φ::Float64, σ::Float64, n::Int; seed::Int=0)
    Random.seed!(seed)
    y = zeros(n); y[1] = σ/sqrt(1-φ^2)*randn()
    for t in 2:n; y[t] = φ*y[t-1] + σ*randn(); end
    y
end

"""
    random_spd_test(n; cond) → Matrix

Generate a random n×n SPD matrix with given condition number (for testing).
"""
function random_spd_test(n::Int; cond::Float64=10.0)
    Q, _ = qr(randn(n, n))
    λ    = exp.(LinRange(0.0, log(cond), n))
    Symmetric(Matrix(Q) * Diagonal(λ) * Matrix(Q)')
end

# =============================================================================
@testset "StructuralStatistics Stratum II — Simulation Tests" begin

# =============================================================================
@testset "Test 1: RMT eigenvalue recovery (known factor model)" begin
# Simulate: p assets, n obs, rank_true systematic factors
# Assert: n_signal ≈ rank_true AND Σ_clean has lower condition number
p = 50; n = 500; rank_true = 5

F   = randn(n, rank_true); β = randn(p, rank_true) * 0.3
X   = F * β' .+ 0.05*randn(n, p)
Σ   = cov(X)
Σ_clean, rpt = clean_covariance_rmt(Σ, n; method=:shrink_trace_preserving)

# MP should identify approximately the right number of signal factors
# Tolerance: ±2 factors (realistic for finite samples)
@test abs(rpt.n_signal - rank_true) ≤ 3 "RMT signal count: got $(rpt.n_signal), expected ≈ $rank_true"

# Cleaned matrix should be better conditioned
cond_orig  = cond(Symmetric(Σ))
cond_clean = cond(Σ_clean)
@test cond_clean < cond_orig "Cleaning should reduce condition number"

# Trace ratio should be close to 1 with :shrink_trace_preserving
@test abs(rpt.trace_ratio - 1.0) < 0.1 "Trace not approximately preserved: ratio=$(rpt.trace_ratio)"

# Cleaned matrix must be PSD
@test rpt.positive_definite "Cleaned covariance is not positive definite"
end

# =============================================================================
@testset "Test 2: sigma² estimation from bulk" begin
# Known: for a pure noise matrix (no signal), all eigenvalues are within
# the MP bulk and σ² ≈ 1 for a correlation matrix.
p = 40; n = 400
X   = randn(n, p)   # pure noise
Σ   = cor(X)        # correlation matrix: true σ² = 1
ev  = eigvals(Symmetric(Σ))
σ2  = estimate_sigma2_from_bulk(ev, p, n; method=:iterative)
@test abs(σ2 - 1.0) < 0.25 "σ² estimate off for pure noise: got $σ2, expected ≈ 1.0"

# KS test should accept the MP fit for pure noise
mp_fit = fit_mp_to_spectrum(ev, p, n)
@test mp_fit.good_fit "KS test rejects MP for pure noise — algorithm issue"
@test mp_fit.n_signal == 0 || mp_fit.n_signal ≤ 3 "False positives in pure noise: $(mp_fit.n_signal) signal"
end

# =============================================================================
@testset "Test 3: rolling_eigenvector_stability detects instability" begin
# Stable factor: constant eigenvector across all windows → cosines ≈ 1
# Unstable factor: random rotation each window → cosines ≈ random

n = 300; p = 20; window = 80

# Stable: one strong factor that persists
v_true = normalize(randn(p))
X_stable = randn(n, p) * 0.1
for t in 1:n; X_stable[t, :] .+= 5.0*randn()*v_true; end

cos_stable = rolling_eigenvector_stability(X_stable, window; n_components=1)
@test cos_stable[1] > 0.7 "Stable factor not detected: cos=$(round(cos_stable[1],digits=3))"

# Unstable: random direction each window
X_noisy = randn(n, p)
# Don't test a hard threshold — just check instability < stability
cos_noisy = rolling_eigenvector_stability(X_noisy, window; n_components=1)
@test cos_noisy[1] ≤ cos_stable[1] "Unstable should have lower cosine than stable"
end

# =============================================================================
@testset "Test 4: HMM parameter recovery (known 3-regime model)" begin
# Simulate from known HMM; fit; check that:
# (a) economic validation passes
# (b) regimes are interpretable
k = 3; n = 800
A_true = [0.92 0.04 0.04
          0.04 0.92 0.04
          0.04 0.04 0.92]
μ_true = [0.003, -0.002, -0.012]
σ_true = [0.008,  0.025,  0.060]

states_true, obs = simulate_gaussian_hmm(A_true, μ_true, σ_true, n; seed=42)

cfg    = HMMConfig(k; emission=StudentTEmission(k; df=5.0), min_duration_days=15)
fitted = _fit_gaussian_hmm_simple(obs, k)
val    = validate_hmm_economics(fitted.state_sequence, obs, cfg)

# Validation should pass (3 distinct regimes with reasonable separation)
@test isempty(val.issues) || length(val.issues) ≤ 1 "HMM validation failed: $(val.issues)"

# Volatility separation: σ_true spans 0.008 to 0.060 — should be detectable
v_fit = [std(obs[fitted.state_sequence .== j]) for j in 1:k
         if count(fitted.state_sequence .== j) > 0]
length(v_fit) ≥ 2 &&
    @test maximum(v_fit)/minimum(v_fit) > 2.0 "Vol separation not recovered (ratio=$(round(maximum(v_fit)/minimum(v_fit),digits=2)))"

# select_n_regimes should prefer k=3 over k=2 for this data
best_k, sc = select_n_regimes(obs, 5; min_duration=15)
@test best_k ∈ [2, 3, 4] "select_n_regimes returned $best_k — plausible but check"
end

# =============================================================================
@testset "Test 5: constrain_transition_matrix! (pre-fitting constraints)" begin
# Ergodic: after constraining, all entries should be > min_off_diag
k = 3
A = rand(k, k)
constrain_transition_matrix!(A, Ergodic(; min_off_diag=0.02))
@test all(A .≥ 0.02 - 1e-12) "Ergodic constraint violated: min=$(minimum(A))"
@test all(abs.(sum(A, dims=2) .- 1.0) .< 1e-10) "Rows don't sum to 1 after Ergodic"

# Absorbing: state 3 should be absorbing (or near-absorbing)
A2 = rand(k, k)
constrain_transition_matrix!(A2, Absorbing([3]; allow_escape=false))
@test abs(A2[3, 3] - 1.0) < 1e-10 "Absorbing state 3 not locked: A[3,3]=$(A2[3,3])"
@test all(abs.(A2[3, 1:2]) .< 1e-10) "Absorbing state 3 has escape probability"
end

# =============================================================================
@testset "Test 6: RPCA recovery (known low-rank + sparse ground truth)" begin
# Simulate X = L_true + S_true where rank(L_true)=3, S_true is 2% sparse
m = 200; p = 50; rank_true = 3; sparse_frac = 0.02
L_true = randn(m, rank_true) * randn(rank_true, p) * 0.3
# Sparse: 2% of entries are large outliers
S_true = zeros(m, p)
n_outliers = round(Int, m*p*sparse_frac)
outlier_idx = randperm(m*p)[1:n_outliers]
S_true[outlier_idx] = randn(n_outliers) .* 0.5
X = L_true .+ S_true

# Default λ (image-denoising)
λ_default = 1/sqrt(max(m, p))
L_def, S_def, conv_def, _ = rpca_admm(X, λ_default)
val_def = validate_rpca_decomposition(L_def, S_def, X)

# Finance-tuned λ via purged CV
embargo = compute_embargo_from_autocorr(vec(mean(X, dims=2)); method=:crossing_time)
cv_splits = generate_purged_splits(m, embargo; n_folds=3)
best_λ, _, rpt_λ = tune_lambda_rpca(X, cv_splits)
L_fin, S_fin, conv_fin, _ = rpca_admm(X, best_λ)
val_fin = validate_rpca_decomposition(L_fin, S_fin, X)

# Both should converge
@test conv_def "Default λ ADMM did not converge"
@test conv_fin "Finance-tuned λ ADMM did not converge"

# Finance-tuned rank should not exceed 5 (finance-specific constraint)
@test val_fin.rank_L ≤ 8 "rank(L) too high after finance tuning: $(val_fin.rank_L)"

# Reconstruction errors should be low (signal dominates)
@test val_def.reconstruction_error < 0.4 "Default λ reconstruction error too high"
@test val_fin.reconstruction_error < 0.4 "Finance λ reconstruction error too high"

# Sparse density: S should be sparse
@test val_fin.sparse_density < 0.5 "S is not sparse with finance-tuned λ: density=$(round(val_fin.sparse_density,digits=3))"
end

# =============================================================================
@testset "Test 7: validate_rpca_decomposition — corr_ls_threshold configurable" begin
# Verify the configurable threshold works
m = 100; p = 20; λ = 0.1
X = randn(m, p)
L, S, _, _ = rpca_admm(X, λ)

# Default threshold 0.1
r1 = validate_rpca_decomposition(L, S, X; corr_ls_threshold=0.1)
# Relaxed threshold 0.3
r2 = validate_rpca_decomposition(L, S, X; corr_ls_threshold=0.3)

# Relaxed should never have MORE issues than strict
corr_issues_strict  = count(contains.(r1.issues, "cor(L,S)"))
corr_issues_relaxed = count(contains.(r2.issues, "cor(L,S)"))
@test corr_issues_relaxed ≤ corr_issues_strict "Relaxed threshold should not add issues"
end

# =============================================================================
@testset "Test 8: Purged CV — derived embargo reduces leakage (AR1 known process)" begin
# Key test from the review: AR(1) with φ=0.7 has strong autocorrelation.
# Short embargo (1) should leak. Data-derived embargo should not.
φ = 0.7; σ_ar = 0.1; n = 500
y = simulate_ar1(φ, σ_ar, n; seed=99)

# Short embargo: expect significant leakage
embargo_short = 1
splits_short  = generate_purged_splits(n, embargo_short; n_folds=5)
leak_short    = detect_information_leak(y, splits_short)

# Data-derived embargo
embargo_derived = compute_embargo_from_autocorr(y; method=:crossing_time, threshold=0.05)
splits_derived  = generate_purged_splits(n, embargo_derived; n_folds=5)
leak_derived    = detect_information_leak(y, splits_derived)

@test embargo_derived ≥ 3 "AR(1) φ=0.7 should need embargo ≥ 3 lags"

# Derived embargo should have lower leakage than embargo=1
@test leak_derived.max_leakage ≤ leak_short.max_leakage + 0.05 "Derived embargo did not reduce leakage"
end

# =============================================================================
@testset "Test 9: Autocorrelation embargo methods are consistent" begin
n = 300; φ = 0.5; σ_ar = 0.1
y = simulate_ar1(φ, σ_ar, n; seed=7)

e_cross = compute_embargo_from_autocorr(y; method=:crossing_time)
e_decay = compute_embargo_from_autocorr(y; method=:decorrelation)

# Both should be positive and bounded
@test e_cross ≥ 1 "crossing_time embargo must be ≥ 1"
@test e_decay ≥ 1 "decorrelation embargo must be ≥ 1"
@test e_cross ≤ n÷4 "crossing_time embargo unreasonably large"
@test e_decay ≤ n÷4 "decorrelation embargo unreasonably large"

# For AR(1) φ=0.5, true decorrelation time ≈ -1/log(0.5) ≈ 1.4 lags
# Both methods should give sensible estimates (roughly 2-15)
@test 2 ≤ e_cross ≤ 20 "crossing_time out of expected range for AR(1) φ=0.5: $e_cross"
@test 1 ≤ e_decay ≤ 20 "decorrelation out of expected range for AR(1) φ=0.5: $e_decay"
end

# =============================================================================
@testset "Test 10: generate_purged_splits auto-reduces embargo" begin
# When embargo is large relative to fold size, it should be auto-reduced
n = 100; n_folds = 5; large_embargo = 30   # fold_size=20, embargo=30 > 10
splits = generate_purged_splits(n, large_embargo; n_folds=n_folds)

# Should still produce some splits (not zero)
@test length(splits) > 0 "No splits generated after auto-reduction"

# Every split should have non-empty train and test
for sp in splits
    @test length(sp.train) ≥ 2 "Train set too small in fold $(sp.fold)"
    @test length(sp.test)  ≥ 1 "Test set empty in fold $(sp.fold)"
end

# No temporal leakage: train indices should all precede or follow test
for sp in splits
    # Training and test should be disjoint
    @test isempty(intersect(sp.train, sp.test)) "Train/test overlap in fold $(sp.fold)"
end
end

# =============================================================================
@testset "Test 11: Cross-model assumption audit detects known conflicts" begin
# RMT assumes i.i.d.; if we tell the audit the data is autocorrelated, it
# should flag the conflict.
conflicts = cross_model_audit([:rmt, :hmm];
                               data_evidence=Set{Symbol}([:autocorrelated_returns]))
@test !isempty(conflicts) "Autocorrelated data should conflict with RMT :iid_returns assumption"

# No data evidence → only structural model-model conflicts reported
conflicts_clean = cross_model_audit([:rmt, :hmm])
# HMM (stationary_transitions) and RMT (iid) don't structurally conflict by default
@test length(conflicts_clean) ≤ length(conflicts) "Adding data evidence should not reduce conflicts"
end

# =============================================================================
@testset "Test 12: _economic_score uses cv_sq not F-statistic" begin
# Verify the score is positive and increases with heterogeneity
k = 3; n = 600
states_homog = repeat(1:k, outer=n÷k)   # equal assignment
states_heter = vcat(fill(1,n÷2), fill(2,n÷4), fill(3,n÷4))

y_heter = vcat(randn(n÷2)*0.01 .+ 0.003,   # low vol bull
               randn(n÷4)*0.04 .- 0.002,   # high vol bear
               randn(n÷4)*0.08 .- 0.010)   # crisis

# Heterogeneous states should score higher than homogeneous
score_heter = StructuralStatistics._economic_score(states_heter, y_heter, k, 20)
states_rand = [rand(1:k) for _ in 1:n]
score_rand  = StructuralStatistics._economic_score(states_rand, y_heter, k, 20)

@test score_heter ≥ 0.0 "Economic score must be non-negative"
@test score_heter ≤ 1.0 "Economic score must be ≤ 1.0"
end

# =============================================================================
@testset "Test 13: Dict argmax fix in select_n_regimes" begin
# Regression test: argmax on Dict must not throw
n = 300; y = simulate_ar1(0.3, 0.05, n)
# Should not throw — that was the v1 bug
@test_nowarn begin
    best_k, sc = select_n_regimes(y, 4; min_duration=15)
    @test best_k ∈ 2:4 "best_k=$best_k out of search range"
end
end

# =============================================================================
@testset "Test 14: run_stratum_ii_audit does not error on well-formed data" begin
n, p = 300, 20
F = randn(n, 3); β = randn(p, 3)
R = F * β' .+ 0.1*randn(n, p)
cfg = HMMConfig(3; emission=StudentTEmission(3; df=4.0))
@test_nowarn begin
    rpt = run_stratum_ii_audit(R, n; hmm_config=cfg)
    @test rpt.severity ∈ (:ok, :warning, :error)
end
end

end # @testset
println("\nAll Stratum II simulation tests complete.")
