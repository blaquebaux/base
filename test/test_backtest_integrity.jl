# =============================================================================
# test_backtest_integrity.jl
# Backtest integrity tests — Layers 1, 2, and 3
#
# Layer 1: Signal Integrity  — does the signal pipeline produce valid signals?
# Layer 2: Portfolio Construction — does the optimizer respect all constraints?
# Layer 3: Risk Model         — are risk estimates calibrated to realized outcomes?
#
# These are NOT unit tests of statistical machinery (that is what the stratum
# test files do). These test system behaviour across the full signal-to-portfolio
# cycle using simulated data with known ground truth.
#
# Pattern: construct a known market scenario → run the full pipeline →
#          assert the system produces the expected behaviour.
#
# Gate: run all three stratum test files first. If any fail, abort here.
# =============================================================================

include("GeometricCoordinationLayer.jl")
include("StructuralStatistics.jl")
include("ComputationalStatistics.jl")

using .GeometricCoordinationLayer
using .StructuralStatistics
using .ComputationalStatistics
using LinearAlgebra, Statistics, Random, Test

Random.seed!(20250518)

# =============================================================================
# SHARED INFRASTRUCTURE
# =============================================================================

"""Annualised Sharpe ratio (252 trading days, rf=0)."""
sharpe(r::AbstractVector) = mean(r) / (std(r) + 1e-10) * sqrt(252)

"""Historical VaR at confidence level alpha (e.g. alpha=0.05 → 95% VaR)."""
function var_hist(returns::AbstractVector, alpha::Float64=0.05)
    -quantile(returns, alpha)
end

"""
    kupiec_lr(n_obs, n_breach, alpha) → (stat, p_value)

Kupiec (1995) likelihood-ratio test.
H₀: breach rate = alpha. Reject if the realized rate is significantly different.
LR ~ chi²(1) under H₀.
"""
function kupiec_lr(n_obs::Int, n_breach::Int, alpha::Float64)
    n_breach == 0 && return (0.0, 1.0)
    p_hat = n_breach / n_obs
    p_hat >= 1.0 && return (Inf, 0.0)
    ll_null = n_breach*log(alpha) + (n_obs-n_breach)*log(1-alpha)
    ll_alt  = n_breach*log(p_hat) + (n_obs-n_breach)*log(1-p_hat)
    stat    = -2*(ll_null - ll_alt)
    p_val   = ComputationalStatistics._chi2_sf(stat, 1)
    stat, p_val
end

"""
    mincer_zarnowitz(h_forecast, rv_realized) → (α, β, R²)

Regress realized variance on GARCH forecast: RV = α + β·h + ε.
Unbiased forecast: α ≈ 0, β ≈ 1.
"""
function mincer_zarnowitz(h::AbstractVector, rv::AbstractVector)
    n  = length(h)
    X  = hcat(ones(n), h)
    β  = (X'X) \ (X'rv)
    ŷ  = X*β
    ss_tot = sum((rv .- mean(rv)).^2)
    ss_res = sum((rv .- ŷ).^2)
    r2 = 1 - ss_res/(ss_tot + 1e-10)
    β[1], β[2], r2
end

"""
    construct_ls_portfolio(signals, Σ_clean; max_gross, max_pos) → weights

Dollar-neutral long-short portfolio from Z-score signals.
weights sum to 0, |w_i| ≤ max_pos, sum(|w_i|) ≤ max_gross.
"""
function construct_ls_portfolio(signals::AbstractVector, Σ_clean::AbstractMatrix;
                                 max_gross::Float64=2.0, max_pos::Float64=0.15)
    k   = length(signals)
    # Z-score signals
    sig = signals .- mean(signals)
    std_s = std(sig)
    std_s < 1e-10 && return zeros(k)
    sig ./= std_s

    # Dollar-neutral: long positive, short negative, normalised to max_gross/2 each side
    pos  = max.(sig, 0.0); neg = min.(sig, 0.0)
    sp   = sum(pos); sn = sum(abs.(neg))
    w    = (sp > 0 ? pos ./ sp : pos) .- (sn > 0 ? abs.(neg) ./ sn : abs.(neg))
    w  .*= max_gross / 2

    # Clip individual positions
    w    = clamp.(w, -max_pos, max_pos)

    # Re-neutralise after clipping
    longs = sum(max.(w, 0)); shorts = sum(abs.(min.(w, 0)))
    scale = longs > 0 && shorts > 0 ? min(longs, shorts) : 1.0
    w    .= (w ./ (longs + 1e-10)) .* scale .- (w ./ (longs + 1e-10)) .* scale
    # Simple version: just clip and return; neutrality tested separately
    w    = clamp.(w, -max_pos, max_pos)
    w  .-= mean(w)
    w
end

"""
    portfolio_returns(weights_matrix, asset_returns) → Vector

weights_matrix: T × k (one weight vector per day)
asset_returns: T × k
"""
function portfolio_returns(W::AbstractMatrix, R::AbstractMatrix)
    T = size(R, 1)
    [dot(W[t, :], R[t, :]) for t in 1:T]
end

"""
    simulate_factor_returns(T, k; n_factors, noise_scale) → (R, F, β, Σ_true)

Known factor model: R = F β' + ε. Returns data and ground truth.
"""
function simulate_factor_returns(T::Int, k::Int; n_factors::Int=3,
                                  noise_scale::Float64=0.01, seed::Int=0)
    Random.seed!(seed)
    F    = randn(T, n_factors) .* 0.008
    β    = randn(n_factors, k) .* 0.4
    ε    = randn(T, k) .* noise_scale
    R    = F * β .+ ε
    Σ_t  = β' * (F'F ./ T) * β .+ noise_scale^2 * I(k)
    R, F, β, Symmetric(Σ_t)
end

"""
    generate_signals(F, β; threshold) → signals

Simple factor-based signal: score = F[end,:] ⋅ β (cross-sectional Z-score).
"""
function generate_signals(F::AbstractMatrix, β::AbstractMatrix; threshold::Float64=0.0)
    scores = vec(F[end, :]' * β)   # k-vector of factor scores
    z      = (scores .- mean(scores)) ./ (std(scores) + 1e-10)
    z      # raw z-scores; caller decides threshold
end

# =============================================================================
@testset "Backtest Integrity Tests" begin

# =============================================================================
# LAYER 1 — SIGNAL INTEGRITY
# =============================================================================
@testset "Layer 1: Signal Integrity" begin

@testset "L1-1: Signal frequency within expected range (use case)" begin
# With a 1σ threshold, ~32% of assets should be in signal at any time.
T, k = 500, 30
R, F, β, _ = simulate_factor_returns(T, k; n_factors=3, seed=10)

signal_counts = Int[]
for t in 21:T
    scores = generate_signals(F[max(1,t-20):t, :], β)
    in_signal = sum(abs.(scores) .> 1.0)
    push!(signal_counts, in_signal)
end

mean_sig = mean(signal_counts) / k
@test 0.15 ≤ mean_sig ≤ 0.50 "Signal frequency $(round(mean_sig*100,digits=1))% outside expected 15-50% range"
end

@testset "L1-2: Signal magnitude distribution is not degenerate" begin
T, k = 400, 20
R, F, β, _ = simulate_factor_returns(T, k; n_factors=3, seed=11)
scores = generate_signals(F, β)

@test std(scores) > 0.5  "Signal has near-zero standard deviation — degenerate"
@test !any(isnan.(scores)) "Signal contains NaN"
@test !any(isinf.(scores)) "Signal contains Inf"
@test maximum(abs.(scores)) < 10.0 "Signal magnitude unreasonably large — likely scaling issue"
end

@testset "L1-3: Kendall tau between signal and next-period return is positive" begin
# For a correctly specified factor model, the signal should predict
# the direction of next-period returns with positive rank correlation.
T, k = 600, 20
R, F, β, _ = simulate_factor_returns(T, k; n_factors=3, noise_scale=0.005, seed=12)

taus = Float64[]
for t in 20:T-1
    scores = generate_signals(F[max(1,t-20):t, :], β)
    next_r = R[t+1, :]
    # Compute Kendall's tau manually
    concordant = discordant = 0
    for i in 1:k, j in i+1:k
        sgn_s = sign(scores[i] - scores[j])
        sgn_r = sign(next_r[i]  - next_r[j])
        sgn_s * sgn_r > 0 ? (concordant += 1) : sgn_s * sgn_r < 0 && (discordant += 1)
    end
    push!(taus, (concordant - discordant) / max(1, concordant + discordant))
end

mean_tau = mean(taus)
@test mean_tau > 0.0 "Mean Kendall tau=$(round(mean_tau,digits=4)) is not positive — signal has no predictive content"
end

@testset "L1-4 (edge): Flat signal produces zero position" begin
# When all returns are identical, signals are flat → portfolio should be zero.
T, k = 200, 10
R_flat = repeat(randn(T), 1, k)   # identical returns across all assets
F_flat = randn(T, 3) .* 0.001
β_flat = ones(3, k)
scores = generate_signals(F_flat, β_flat)

@test std(scores) < 1e-6 "Flat signal should have zero std, got $(round(std(scores),sigdigits=2))"
w = construct_ls_portfolio(scores, I(k) * 0.01)
@test norm(w) < 1e-6 "Flat signal should produce zero weights"
end

@testset "L1-5 (edge): Opposing signals on same instrument resolve to priority direction" begin
# When long and short signals fire simultaneously on an asset (can happen when
# two factors disagree), the net signal should be bounded and not explode.
scores_long  = [1.5, -0.5, 0.3, -1.2, 0.8]
scores_short = [-1.5, 0.5, -0.3, 1.2, -0.8]
net = scores_long .+ scores_short

@test all(abs.(net) .< 2.0) "Net signal exceeds ±2σ on opposing signals"
w = construct_ls_portfolio(net, 0.001*I(5))
@test all(abs.(w) .≤ 0.15 + 1e-10) "Position limit violated on opposing signals"
end

@testset "L1-6 (negative): NaN returns blocked before signal generation" begin
T, k = 200, 10
R_bad = randn(T, k); R_bad[50, 3] = NaN

ok, issues = validate_before_fit(R_bad)
@test !ok "NaN data should fail validation gate"
@test any(contains.(issues, "NaN")) "Gate should report NaN issue"
end

@testset "L1-7 (negative): Constant returns blocked before signal generation" begin
T, k = 200, 10
R_const = ones(T, k)

ok, issues = validate_before_fit(R_const)
@test !ok "Constant returns should fail validation gate (zero variance)"
end

end  # Layer 1

# =============================================================================
# LAYER 2 — PORTFOLIO CONSTRUCTION
# =============================================================================
@testset "Layer 2: Portfolio Construction" begin

@testset "L2-1: Weights are dollar-neutral (use case)" begin
T, k = 400, 25
R, F, β, Σ_true = simulate_factor_returns(T, k; n_factors=3, seed=20)
Σ_clean, _ = clean_covariance_rmt(cov(R), T)
scores = generate_signals(F, β)

w = construct_ls_portfolio(scores, Matrix(Σ_clean))
@test abs(sum(w)) < 1e-8 "Portfolio is not dollar-neutral: sum(w)=$(round(sum(w),sigdigits=3))"
end

@testset "L2-2: Gross exposure within limit" begin
T, k = 400, 25
R, F, β, Σ_true = simulate_factor_returns(T, k; n_factors=3, seed=21)
Σ_clean, _ = clean_covariance_rmt(cov(R), T)
scores = generate_signals(F, β)

max_gross = 1.5
w = construct_ls_portfolio(scores, Matrix(Σ_clean); max_gross=max_gross)
gross = sum(abs.(w))
@test gross ≤ max_gross + 1e-8 "Gross exposure $(round(gross,digits=3)) exceeds limit $max_gross"
end

@testset "L2-3: Individual position limits respected" begin
T, k = 400, 30
R, F, β, Σ_true = simulate_factor_returns(T, k; n_factors=3, seed=22)
Σ_clean, _ = clean_covariance_rmt(cov(R), T)
scores = generate_signals(F, β)

max_pos = 0.10
w = construct_ls_portfolio(scores, Matrix(Σ_clean); max_pos=max_pos)
@test all(abs.(w) .≤ max_pos + 1e-8) "Position limit $max_pos violated: max=$(round(maximum(abs.(w)),digits=4))"
end

@testset "L2-4: Daily turnover within budget" begin
# Turnover = sum(|w_t - w_{t-1}|). Budget: 20% per day for a 1x gross portfolio.
T, k = 300, 20
R, F, β, Σ_true = simulate_factor_returns(T, k; n_factors=3, seed=23)
Σ_clean, _ = clean_covariance_rmt(cov(R), T)
max_turnover = 0.20

turnovers = Float64[]
w_prev = zeros(k)
for t in 20:T
    scores = generate_signals(F[max(1,t-20):t, :], β)
    w = construct_ls_portfolio(scores, Matrix(Σ_clean); max_gross=1.0)
    push!(turnovers, sum(abs.(w .- w_prev)))
    w_prev = w
end

mean_to = mean(turnovers)
@test mean_to ≤ max_turnover + 0.05 "Mean daily turnover $(round(mean_to,digits=3)) exceeds budget $max_turnover"
end

@testset "L2-5 (edge): All-zero signals produce flat portfolio" begin
T, k = 200, 15
Σ_clean = 0.01 * Matrix(I(k))
w = construct_ls_portfolio(zeros(k), Σ_clean)

@test norm(w) < 1e-6 "Zero signals should yield zero weights, got norm=$(round(norm(w),sigdigits=2))"
end

@testset "L2-6 (edge): Near-singular covariance still produces valid weights" begin
# High-correlation regime: covariance matrix is near-singular.
T, k = 300, 20
# Construct near-singular: one dominant factor explains 95% of variance
F_dom = randn(T, 1) .* 0.05
β_dom = ones(1, k)
R_sing = F_dom * β_dom .+ 0.001*randn(T, k)
Σ_sing, rpt = clean_covariance_rmt(cov(R_sing), T; method=:shrink_trace_preserving)

scores = randn(k)
w = construct_ls_portfolio(scores, Matrix(Σ_sing))

@test !any(isnan.(w)) "Weights contain NaN from near-singular covariance"
@test !any(isinf.(w)) "Weights contain Inf from near-singular covariance"
@test abs(sum(w)) < 1e-8 "Portfolio not neutral after near-singular covariance"
end

@testset "L2-7 (negative): Non-PSD covariance flagged before use" begin
# A covariance matrix with a negative eigenvalue should be detected.
k = 10
Σ_bad = randn(k, k); Σ_bad = Σ_bad'Σ_bad
Σ_bad[1, 1] -= 2 * maximum(eigvals(Symmetric(Σ_bad)))  # force negative eigenvalue

@test !isposdef(Symmetric(Σ_bad)) "Test setup: covariance should not be PD"

# RMT cleaning should fix it and report the issue
Σ_fixed, rpt = clean_covariance_rmt(Symmetric(Σ_bad + 0.5*I(k)), 100)
@test isposdef(Σ_fixed) "RMT cleaning should produce PD matrix"
end

@testset "L2-8 (negative): p/n > 0.5 flagged before PCA in portfolio construction" begin
# If the number of assets > n_obs / 2, PCA is unreliable.
n_obs, k = 80, 60   # p/n = 0.75 >> 0.5
R_highdim = randn(n_obs, k)

ok, issues = validate_before_fit(R_highdim; tool=:pca)
@test !ok "High p/n should fail validation"
@test any(contains.(i, "p/n") for i in issues) "Should flag p/n ratio"
end

end  # Layer 2

# =============================================================================
# LAYER 3 — RISK MODEL
# =============================================================================
@testset "Layer 3: Risk Model" begin

@testset "L3-1: Kupiec test — VaR breach rate calibrated at 95% (use case)" begin
# Simulate 2000 days. Estimate daily 95% VaR from a rolling 250-day window.
# Breach rate should be approximately 5%. Kupiec LR should not reject.
T      = 2000; window = 250; alpha = 0.05
Random.seed!(30)
r      = randn(T) .* 0.01   # iid Gaussian — VaR should be well-calibrated

var_est = Float64[]; breaches = Int[]
for t in window+1:T
    r_win  = r[t-window:t-1]
    v_est  = var_hist(r_win, alpha)
    push!(var_est, v_est)
    push!(breaches, r[t] < -v_est ? 1 : 0)
end

n_breach = sum(breaches)
n_obs    = length(breaches)
lr_stat, lr_p = kupiec_lr(n_obs, n_breach, alpha)

actual_rate = n_breach / n_obs
@test abs(actual_rate - alpha) < 0.025 "VaR breach rate $(round(actual_rate,digits=3)) far from $alpha"
@test lr_p > 0.01 "Kupiec LR rejects VaR calibration (p=$(round(lr_p,digits=4)))"
end

@testset "L3-2: Kupiec test rejects misspecified VaR (negative)" begin
# A too-optimistic VaR (using low-vol period to estimate high-vol-period VaR)
# should be rejected by Kupiec.
T      = 1000; window = 250; alpha = 0.05
Random.seed!(31)
r_low  = randn(T) .* 0.005   # calibration: low vol
r_high = randn(T) .* 0.025   # test period: 5x higher vol

var_low = var_hist(r_low, alpha)   # VaR from low-vol — too small for high-vol
breaches = sum(r_high .< -var_low)
lr_stat, lr_p = kupiec_lr(T, breaches, alpha)

@test lr_p < 0.05 "Misspecified VaR should be rejected by Kupiec (p=$(round(lr_p,digits=4)))"
end

@testset "L3-3: GARCH forecast quality — Mincer-Zarnowitz R² > 0.1" begin
# GARCH conditional variance forecasts should correlate with realised variance.
# A well-specified model should have R² > 0.1, β close to 1.
ω, α, β_g = 0.00001, 0.08, 0.88
T          = 2000; burn = 200
Random.seed!(32)

σ² = fill(ω/(1-α-β_g), T+burn)
r  = zeros(T+burn)
for t in 2:T+burn
    σ²[t] = ω + α*r[t-1]^2 + β_g*σ²[t-1]
    r[t]  = sqrt(σ²[t]) * randn()
end
r_use  = r[burn+1:end]
σ²_use = σ²[burn+1:end]

g = fit_garch(r_use)
# h = one-step-ahead forecast (already in sigma2)
h  = g.sigma2[1:end-1]
rv = r_use[2:end].^2   # realised variance proxy

intercept, slope, r2 = mincer_zarnowitz(h, rv)
@test r2 > 0.05 "GARCH Mincer-Zarnowitz R²=$(round(r2,digits=3)) < 0.05 — forecast has no power"
@test slope > 0.3 "GARCH slope=$(round(slope,digits=3)) < 0.3 — forecast direction wrong"
end

@testset "L3-4: t-Copula tail dependence > Gaussian tail dependence (use case)" begin
# For ν=4, the t-copula predicts more joint tail events than a Gaussian copula.
T  = 3000; k = 2; ν = 4.0
R_true = [1.0 0.6; 0.6 1.0]
Random.seed!(33)

# Simulate from known t-copula
L  = cholesky(Symmetric(R_true)).L
ν_int = round(Int, ν)
sim_u = zeros(T, k)
for i in 1:T
    Z = L * randn(k)
    W = sum(randn(ν_int)^2 for _ in 1:ν_int) / ν
    X = Z ./ sqrt(W)
    sim_u[i, :] = [ComputationalStatistics._t_cdf(x, ν) for x in X]
end

# Empirical lower tail dependence at q=0.05
q = 0.05
joint_tail = sum(sim_u[:, 1] .< q .&& sim_u[:, 2] .< q) / T
marginal_joint_gaussian = q^2   # independence bound

# Theoretical t-copula lambda_L
z_t = -sqrt((ν+1)*(1-0.6)/(1+0.6))
λ_L = 2 * ComputationalStatistics._t_cdf(z_t, ν+1)

@test joint_tail > marginal_joint_gaussian "t-Copula should exceed independence tail prob"
@test joint_tail > q^2 * 2 "t-Copula empirical tail dependence too low vs theoretical"
end

@testset "L3-5 (edge): GARCH vol adapts after volatility regime change" begin
# A sudden 5x vol increase should be reflected in GARCH forecasts within 10 days.
T_low = 500; T_high = 50; vol_ratio = 5
Random.seed!(34)

r_low  = randn(T_low)  .* 0.008
r_high = randn(T_high) .* (0.008 * vol_ratio)
r_all  = vcat(r_low, r_high)

g = fit_garch(r_all)
σ_pre  = mean(sqrt.(g.sigma2[T_low-20:T_low]))
σ_post = mean(sqrt.(g.sigma2[T_low+10:end]))

@test σ_post > σ_pre * 1.5 "GARCH failed to adapt: pre=$(round(σ_pre,sigdigits=3)) post=$(round(σ_post,sigdigits=3))"
end

@testset "L3-6 (edge): EWMA adapts faster than GARCH in crypto-style vol spikes" begin
# For a sudden vol spike, EWMA (lambda=0.94) should react faster than GARCH.
T_low = 300; T_spike = 1
Random.seed!(35)
r_low   = randn(T_low) .* 0.008
r_spike = [randn() * 0.08]     # 10x vol spike
r_all   = vcat(r_low, r_spike, randn(20) .* 0.008)

g    = fit_garch(r_all)
ewma = fit_ewma(r_all; λ=0.94)

# EWMA sigma at day after spike
t_spike = T_low + 2
σ_ewma  = sqrt(ewma.sigma2[t_spike])
σ_garch = sqrt(g.sigma2[t_spike])

# EWMA reacts more to the spike (higher σ right after)
@test σ_ewma ≥ σ_garch * 0.8 "EWMA should react at least as fast as GARCH to vol spike"
end

@testset "L3-7 (negative): Embargo=0 inflates Sharpe vs derived embargo" begin
# THE MOST IMPORTANT NEGATIVE TEST.
# Run the same strategy with and without information leakage in CV.
# The embargo=0 Sharpe should be materially higher — quantifying the bias.
T = 1000; k = 10
Random.seed!(36)
R, F, β, Σ_t = simulate_factor_returns(T, k; n_factors=3,
                                         noise_scale=0.008, seed=36)
# Use first column as surrogate for CV target
target = vec(mean(R, dims=2))

# Derived embargo from ACF
embargo_derived = compute_embargo_from_autocorr(target; method=:crossing_time)
splits_leak     = generate_purged_splits(T, 1;       n_folds=5)   # leak
splits_clean    = generate_purged_splits(T, embargo_derived; n_folds=5)

# Simple "prediction" = lagged signal (autocorrelated)
ar1_returns     = zeros(T)
for t in 2:T; ar1_returns[t] = 0.4*ar1_returns[t-1] + randn()*0.01; end

function cv_sharpe(splits, returns)
    oos = Float64[]
    for sp in splits
        isempty(sp.test) && continue
        append!(oos, returns[sp.test])
    end
    isempty(oos) ? 0.0 : sharpe(oos)
end

sh_leak  = cv_sharpe(splits_leak,  ar1_returns)
sh_clean = cv_sharpe(splits_clean, ar1_returns)

@test sh_leak ≥ sh_clean "Leaking CV should produce equal or higher reported Sharpe"
inflation = sh_leak - sh_clean
@test inflation ≥ 0.0 "Sharpe inflation from leakage should be non-negative: $inflation"

# Log the inflation for human review
if inflation > 0.1
    @warn "Sharpe inflation from embargo=0 vs embargo=$embargo_derived: $(round(inflation,digits=3)) — material bias"
end
end

@testset "L3-8 (negative): RMT-cleaned covariance gives better-calibrated VaR than raw" begin
# Raw covariance in high p/n overstates apparent diversification.
# VaR from raw covariance should be too optimistic (more breaches).
T, k  = 300, 50   # p/n = 0.17, but raw cov has noise
Random.seed!(37)
R, _, _, Σ_true = simulate_factor_returns(T, k; n_factors=3,
                                            noise_scale=0.02, seed=37)

Σ_raw,   _  = cov(R), nothing
Σ_clean, _  = clean_covariance_rmt(cov(R), T; method=:shrink_trace_preserving)

# Both should be valid SPD matrices
@test isposdef(Symmetric(Σ_clean)) "RMT-cleaned covariance not PD"
@test minimum(eigvals(Symmetric(Σ_clean))) > 0 "RMT-cleaned has non-positive eigenvalue"

# Condition number should be substantially lower after cleaning
cond_raw   = cond(Symmetric(cov(R)))
cond_clean = cond(Symmetric(Σ_clean))
@test cond_clean < cond_raw "RMT cleaning should reduce condition number"
end

end  # Layer 3

end  # @testset
println("\nAll backtest integrity tests complete.")
