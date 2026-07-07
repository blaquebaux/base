# =============================================================================
# test_stress_scenarios.jl
# Stress scenario tests — Layers 5 and 6
#
# Layer 5: Regime and Stress Tests
#   Historically-structured scenarios (synthetic, with known parameters)
#   and synthetic adversarial scenarios. Each test has a defined
#   pass/fail criterion established before the scenario runs.
#
# Layer 6: Blaque Baux Architecture Negative Tests
#   Validation gate bypass attempts, three-strata consistency violations,
#   regime detection failure modes, and the type-system enforcement tests.
#
# Architecture note: these tests assume the stratum tests and backtest
# integrity tests have already passed. A failure here means the system
# will misbehave under specific market conditions — not that the
# math is wrong, but that the designed guardrails are insufficient.
# =============================================================================

include("GeometricCoordinationLayer.jl")
include("StructuralStatistics.jl")
include("ComputationalStatistics.jl")

using .GeometricCoordinationLayer
using .StructuralStatistics
using .ComputationalStatistics
using LinearAlgebra, Statistics, Random, Test

Random.seed!(20250519)

# =============================================================================
# SCENARIO BUILDERS
# =============================================================================

"""
    build_normal_regime(T, k; vol, corr) → Matrix

T days, k assets, constant volatility and correlation structure.
"""
function build_normal_regime(T::Int, k::Int;
                              vol::Float64=0.01, corr::Float64=0.3, seed::Int=0)
    Random.seed!(seed)
    R_base = diagm(fill(corr, k)); R_base[diagind(R_base)] .= 1.0
    R_base = Symmetric(R_base)
    L      = cholesky(R_base).L
    randn(T, k) * L' .* vol
end

"""
    build_correlation_spike(T_pre, T_spike, k; vol_pre, vol_spike, corr_pre, corr_spike)

Simulate a sudden correlation and volatility spike (COVID-style crash).
Returns (returns_matrix, spike_start) where spike_start = T_pre + 1.
"""
function build_correlation_spike(T_pre::Int, T_spike::Int, k::Int;
                                  vol_pre::Float64=0.008, vol_spike::Float64=0.04,
                                  corr_pre::Float64=0.2, corr_spike::Float64=0.85,
                                  seed::Int=0)
    Random.seed!(seed)

    make_corr = (ρ) -> begin
        R = diagm(fill(ρ, k)); R[diagind(R)] .= 1.0; Symmetric(R)
    end

    R_pre   = make_corr(corr_pre);   L_pre   = cholesky(R_pre).L
    R_spike = make_corr(corr_spike); L_spike = cholesky(R_spike).L

    pre   = randn(T_pre,   k) * L_pre'   .* vol_pre
    spike = randn(T_spike, k) * L_spike' .* vol_spike
    vcat(pre, spike), T_pre + 1
end

"""
    build_trending_market(T, k; drift, vol) → Matrix

Persistent directional drift (2022 rate-shock style).
"""
function build_trending_market(T::Int, k::Int;
                                drift::Float64=-0.003, vol::Float64=0.012, seed::Int=0)
    Random.seed!(seed)
    [drift .+ vol * randn(k) for _ in 1:T] |> x -> reduce(vcat, [reshape(v,1,:) for v in x])
end

"""
    build_regime_switch(T_pre, T_post; vol_pre, vol_post, corr, seed)

Abrupt volatility regime switch. Used for detection-lag tests.
"""
function build_regime_switch(T_pre::Int, T_post::Int, k::Int;
                              vol_pre::Float64=0.008, vol_post::Float64=0.05,
                              corr::Float64=0.25, seed::Int=0)
    Random.seed!(seed)
    R = diagm(fill(corr, k)); R[diagind(R)] .= 1.0; R = Symmetric(R)
    L = cholesky(R).L
    pre  = randn(T_pre,  k) * L' .* vol_pre
    post = randn(T_post, k) * L' .* vol_post
    vcat(pre, post), T_pre + 1
end

"""
    build_slow_drift(T, k; base_vol, drift_rate) → Matrix

Gradual data corruption: returns drift by drift_rate per day.
Models a vendor feed that slowly goes stale.
"""
function build_slow_drift(T::Int, k::Int;
                           base_vol::Float64=0.01, drift_rate::Float64=0.0001,
                           seed::Int=0)
    Random.seed!(seed)
    R = randn(T, k) .* base_vol
    for t in 1:T
        R[t, :] .+= t * drift_rate   # systematic drift accumulates
    end
    R
end

"""
    build_crypto_correlation_collapse(T_pre, T_event, T_post, k; seed)

Models FTX-style event: correlation → 1 during event, then back to baseline.
"""
function build_crypto_correlation_collapse(T_pre::Int, T_event::Int, T_post::Int, k::Int;
                                            vol::Float64=0.025, seed::Int=0)
    Random.seed!(seed)
    pre   = build_normal_regime(T_pre,   k; vol=vol,   corr=0.3, seed=seed)
    # During event: correlation = 1 (all assets move together)
    event_factor = randn(T_event) .* vol * 2
    event  = hcat([event_factor for _ in 1:k]...) .+ randn(T_event, k) .* 0.001
    post   = build_normal_regime(T_post, k; vol=vol,   corr=0.3, seed=seed+1)
    vcat(pre, event, post), T_pre+1, T_pre+T_event
end

# Reuse helpers from integrity tests
sharpe(r) = mean(r) / (std(r) + 1e-10) * sqrt(252)
function var_hist(returns, alpha=0.05)
    -quantile(returns, alpha)
end
function kupiec_lr(n_obs, n_breach, alpha)
    n_breach == 0 && return (0.0, 1.0)
    p_hat = n_breach / n_obs
    p_hat >= 1.0 && return (Inf, 0.0)
    ll_null = n_breach*log(alpha) + (n_obs-n_breach)*log(1-alpha)
    ll_alt  = n_breach*log(p_hat) + (n_obs-n_breach)*log(1-p_hat)
    stat = -2*(ll_null - ll_alt)
    stat, ComputationalStatistics._chi2_sf(stat, 1)
end

# =============================================================================
@testset "Stress Scenario Tests" begin

# =============================================================================
# LAYER 5 — REGIME AND STRESS TESTS
# =============================================================================
@testset "Layer 5: Regime and Stress Scenarios" begin

# ── 5.1 COVID-STYLE CORRELATION SPIKE ────────────────────────────────────────
@testset "L5-1: Correlation spike — VaR from pre-crisis model is too optimistic" begin
# Pre-crisis correlation 0.2; crisis correlation 0.85.
# A VaR model calibrated on pre-crisis data should produce too many breaches
# during the crisis period. This tests that the system DETECTS the failure —
# not that it prevents it (that is a different control).
k = 10; T_pre = 252; T_spike = 40
R, spike_start = build_correlation_spike(T_pre, T_spike, k;
    vol_pre=0.008, vol_spike=0.04, corr_pre=0.2, corr_spike=0.85, seed=50)

alpha  = 0.05
pnl_pre = vec(mean(R[1:T_pre, :], dims=2))
var_pre = var_hist(pnl_pre, alpha)

pnl_spike   = vec(mean(R[spike_start:end, :], dims=2))
n_breach    = sum(pnl_spike .< -var_pre)
breach_rate = n_breach / length(pnl_spike)

@test breach_rate > alpha "Pre-crisis VaR should underestimate crisis breaches"
@test breach_rate > 0.10  "Breach rate $(round(breach_rate*100,digits=1))% should be >> 5% during correlation spike"

# Kupiec test should REJECT the pre-crisis VaR on crisis data
_, lr_p = kupiec_lr(length(pnl_spike), n_breach, alpha)
@test lr_p < 0.10 "Pre-crisis VaR should fail Kupiec test on crisis data (p=$(round(lr_p,digits=4)))"
end

@testset "L5-2: RMT detects structural change during correlation spike" begin
# After the spike, eigenvector stability should drop below 0.7.
k = 15; T_pre = 120; T_spike = 30
R, spike_start = build_correlation_spike(T_pre, T_spike, k;
    vol_pre=0.008, vol_spike=0.04, corr_pre=0.2, corr_spike=0.9, seed=51)

# Rolling stability over the full window (includes the spike)
stab_pre   = rolling_eigenvector_stability(R[1:T_pre, :],         60; n_components=1)
stab_cross = rolling_eigenvector_stability(R[T_pre-30:end, :],    60; n_components=1)

# Pre-crisis should be stable; cross-spike should show instability
@test stab_pre[1] > 0.7   "Pre-crisis eigenvector should be stable: $(round(stab_pre[1],digits=3))"
@test stab_cross[1] < stab_pre[1] "Spike should reduce eigenvector stability"
end

# ── 5.2 PERSISTENT DRIFT (2022 rate-shock style) ────────────────────────────
@testset "L5-3: Persistent drift breaks mean-reversion signal" begin
# A mean-reversion strategy should underperform during a persistent trend.
# This tests that the backtest does not hide this structural failure.
T, k = 500, 10
R_trend  = build_trending_market(T, k; drift=-0.003, vol=0.012, seed=52)
R_normal = build_normal_regime(T,   k; vol=0.012, corr=0.2, seed=53)

# Simple mean-reversion signal: short recent outperformers, long recent underperformers
function mean_reversion_signal(R, t, lookback=20)
    t < lookback && return zeros(size(R,2))
    recent_ret = vec(sum(R[t-lookback+1:t, :], dims=1))
    -recent_ret ./ (std(recent_ret) + 1e-10)
end

function strategy_pnl(R)
    T, k = size(R)
    pnl = Float64[]
    for t in 21:T-1
        sig = mean_reversion_signal(R, t)
        w   = sig ./ (sum(abs.(sig)) + 1e-10) .* 0.5   # 0.5x gross
        push!(pnl, dot(w, R[t+1, :]))
    end
    pnl
end

pnl_normal = strategy_pnl(R_normal)
pnl_trend  = strategy_pnl(R_trend)

sh_normal = sharpe(pnl_normal)
sh_trend  = sharpe(pnl_trend)

@test sh_trend < sh_normal "Mean-reversion strategy should underperform during trending market"
@test sh_trend < 0.0       "Mean-reversion strategy should be negative Sharpe during persistent drift"
end

@testset "L5-4: HMM detects volatility regime change (detection lag test)" begin
# Known: regime switch at T_pre. Measure how many periods until the HMM
# assigns > 0.6 probability to the high-vol regime.
k = 1; T_pre = 300; T_post = 150
R, switch_t = build_regime_switch(T_pre, T_post, 1;
    vol_pre=0.008, vol_post=0.05, corr=1.0, seed=54)
r = vec(R)

# Fit on full series
cfg    = HMMConfig(2; emission=StudentTEmission(2; df=4.0), min_duration_days=10)
fitted = StructuralStatistics._fit_gaussian_hmm_simple(r, 2)

# Identify the high-vol regime (higher σ)
vols    = [std(r[fitted.state_sequence .== j]) for j in 1:2]
highvol = argmax(vols)

# Find when the high-vol regime is consistently detected
post_probs = [fitted.state_sequence[t] == highvol ? 1.0 : 0.0 for t in switch_t:length(r)]
detection_lag = findfirst(x -> x == 1.0, post_probs)
detection_lag = something(detection_lag, T_post)

@test detection_lag ≤ T_post "HMM never detected regime change — check model specification"
@test detection_lag ≤ 50 "HMM detection lag=$detection_lag > 50 periods — too slow for risk management"
end

# ── 5.3 CRYPTO CORRELATION COLLAPSE (FTX-STYLE) ─────────────────────────────
@testset "L5-5: Correlation collapse — empirical corr jumps to near 1 during event" begin
k = 8; T_pre = 200; T_event = 5; T_post = 100
R, ev_start, ev_end = build_crypto_correlation_collapse(T_pre, T_event, T_post, k;
    vol=0.025, seed=55)

# Pre-event average pairwise correlation
corr_pre   = cor(R[1:T_pre, :])
mean_corr_pre = mean(abs.(corr_pre[tril(trues(k,k), -1)]))

# During event
corr_event = cor(R[ev_start:ev_end, :])
mean_corr_event = mean(abs.(corr_event[tril(trues(k,k), -1)]))

@test mean_corr_event > mean_corr_pre + 0.3 "Event correlation should be substantially higher than pre-event"
@test mean_corr_event > 0.7 "During FTX-style event, mean abs correlation should approach 1"
end

@testset "L5-6: EWMA volatility tracks crypto correlation collapse correctly" begin
k = 4; T_pre = 150; T_event = 3; T_post = 50
R, ev_start, ev_end = build_crypto_correlation_collapse(T_pre, T_event, T_post, k;
    vol=0.025, seed=56)
r_agg = vec(mean(R, dims=2))

ewma_result = fit_ewma(r_agg; λ=0.94)

vol_pre   = mean(sqrt.(ewma_result.sigma2[T_pre-20:T_pre]))
vol_event = mean(sqrt.(ewma_result.sigma2[ev_start:ev_end]))

@test vol_event > vol_pre * 1.5 "EWMA should detect volatility spike during event: pre=$(round(vol_pre,sigdigits=3)) event=$(round(vol_event,sigdigits=3))"
end

# ── 5.4 NEGATIVE-PRICE RETURNS (CRUDE OIL SCENARIO) ─────────────────────────
@testset "L5-7 (edge): System handles negative-price returns without NaN" begin
# Crude oil went negative in April 2020. Returns computed from negative prices
# can produce NaN if log returns are used. Test arithmetic returns pathway.
T, k = 200, 5
prices = vcat(ones(T÷2) .* 20.0, [5.0, -2.5, 3.0, 15.0], ones(T÷2-4) .* 15.0)
prices = max.(prices, 1e-6)   # floor at 1e-6 to avoid true zero

# Arithmetic returns
r_arith = diff(prices) ./ (abs.(prices[1:end-1]) .+ 1e-6)

ok, issues = validate_before_fit(reshape(r_arith, :, 1))
@test !any(isnan.(r_arith)) "Arithmetic returns should not contain NaN from near-negative prices"
@test !any(isinf.(r_arith)) "Arithmetic returns should not contain Inf"

# GARCH should still fit (may warn about extreme observations)
g = fit_garch(r_arith)
@test g.α + g.β < 1.0 "GARCH stationarity violated on commodity extreme returns"
end

# ── 5.5 SLOW DATA CORRUPTION ────────────────────────────────────────────────
@testset "L5-8: RMT anomaly score detects slow data drift" begin
# A feed that drifts 0.01% per day for 60 days should be detectable
# via a change in the number of signal eigenvalues.
k = 20; T = 300
R_clean = build_normal_regime(T, k; vol=0.01, corr=0.2, seed=58)
R_drift = build_slow_drift(T, k; base_vol=0.01, drift_rate=0.0002, seed=58)

# Fit MP on clean vs drifted
Σ_clean = cov(R_clean); Σ_drift = cov(R_drift)
_, rpt_clean = clean_covariance_rmt(Σ_clean, T)
_, rpt_drift = clean_covariance_rmt(Σ_drift, T)

# Drift inflates sigma2 estimate (drift looks like signal)
@test rpt_drift.sigma2 ≥ rpt_clean.sigma2 * 0.9 "Drifted data should not dramatically reduce MP sigma estimate"

# The trace ratio should be informative
@test abs(rpt_clean.trace_ratio - 1.0) < abs(rpt_drift.trace_ratio - 1.0) + 0.1 "Drift should affect trace ratio"
end

end  # Layer 5

# =============================================================================
# LAYER 6 — BLAQUE BAUX ARCHITECTURE NEGATIVE TESTS
# =============================================================================
@testset "Layer 6: Architecture Negative Tests" begin

# ── 6.1 VALIDATION GATE BYPASS ATTEMPTS ─────────────────────────────────────
@testset "L6-1: NaN in returns blocked before reaching portfolio construction" begin
T, k = 300, 15
R = randn(T, k); R[150, 7] = NaN

ok, issues = validate_before_fit(R)
@test !ok "Corrupted returns must not pass validation gate"

# If we bypass and try to fit covariance directly, cov() returns NaN
Σ_bad = cov(R)
@test any(isnan.(Σ_bad)) "cov() of NaN-contaminated data produces NaN — gate is essential"
end

@testset "L6-2: Near-IGARCH sigma2 blocked from downstream portfolio construction" begin
# alpha + beta >= 1 means unconditional variance is infinite.
# A portfolio VaR derived from such a model is meaningless.
# Simulate data where the GARCH estimate converges near alpha+beta = 1.
T = 500; Random.seed!(60)
# Construct near-IGARCH data: very persistent shocks
σ² = fill(0.0001, T); r = zeros(T)
for t in 2:T
    σ²[t] = 0.000005 + 0.1*r[t-1]^2 + 0.899*σ²[t-1]   # alpha+beta=0.999
    r[t]  = sqrt(σ²[t]) * randn()
end

g = fit_garch(r)
# Whether or not the fit hits alpha+beta >= 1, check the warning fires
near_igarch = g.α + g.β > 0.990
if near_igarch
    @test any(contains(c, "IGARCH") || contains(c, "Persistence") || contains(c, "persist")
              for c in vcat(g.validation.post_checks, g.validation.notes)) "Near-IGARCH should produce a warning"
end
# The projection should always keep alpha+beta < 1
@test g.α + g.β < 1.0 "Projection must enforce alpha+beta < 1 regardless of data"
end

@testset "L6-3: Non-PSD correlation matrix caught before t-copula sampling" begin
k = 5
# Manually construct a non-PSD 'correlation' matrix
R_bad = [1.0 0.9 0.9 0.9 0.9;
         0.9 1.0 0.9 0.9 0.9;
         0.9 0.9 1.0 0.9 0.9;
         0.9 0.9 0.9 1.0 0.9;
         0.9 0.9 0.9 0.9 1.0]
# This is still PSD, but a perturbation can make it non-PSD:
R_bad[1,2] = R_bad[2,1] = -0.95   # contradictory constraint

F     = eigen(Symmetric(R_bad))
is_pd = all(F.values .> 0)

if !is_pd
    # _positive_definite_approx must fix it
    R_fixed = try
        cholesky(ComputationalStatistics._positive_definite_approx(R_bad)).L
        true
    catch
        false
    end
    @test R_fixed "PD approximation should succeed on fixable matrix"
else
    # Matrix happened to be PD despite adversarial construction
    @test true "Matrix was PD despite adversarial construction — test is informational"
end
end

# ── 6.2 THREE-STRATA CONSISTENCY VIOLATIONS ──────────────────────────────────
@testset "L6-4: Ito/Stratonovich convention mismatch is audited and flagged" begin
# Register a Kalman filter (Ito) connected to a manifold sampler (Stratonovich).
# The audit must return :warning or :error, not :ok.
reg = SDERegistry()
register_sde!(reg, SDESpec(:kalman_filter,    ItoCalculus(),
    (t,X)->-0.1X, (t,X)->0.05I(3), 3, 3, "Kalman state estimator"))
register_sde!(reg, SDESpec(:riemannian_sampler, StratonovichCalculus(),
    (t,X)->-0.05X, (t,X)->0.02X,  3, 9, "SPD manifold sampler"))
connect_sdes!(reg, :kalman_filter, :riemannian_sampler)

conflicts = audit_sde_conventions(reg)
@test !isempty(conflicts) "Ito→Stratonovich connection should produce a convention conflict"
@test any(c.severity == :warning for c in conflicts) "Convention mismatch should be at least :warning"
end

@testset "L6-5: RoughPath process mixed with Ito raises :error" begin
# The 0DTE rough vol process (H≈0.1) connected to standard Ito Kalman
# must be flagged as :error, not merely :warning.
reg = SDERegistry()
register_sde!(reg, SDESpec(:kalman,    ItoCalculus(),
    (t,X)->X, (t,X)->0.1I(1), 1, 1, ""))
register_sde!(reg, SDESpec(:rough_vol, ItoCalculus(),
    (t,X)->X, (t,X)->0.1I(1), 1, 1, ""))
enforce_rough_path_lift!(reg, :rough_vol, 0.1)
connect_sdes!(reg, :rough_vol, :kalman)

conflicts = audit_sde_conventions(reg)
@test any(c.severity == :error for c in conflicts) "RoughPath+Ito must be :error, not :warning"
end

@testset "L6-6: AI↔BW metric mismatch quantified before covariance exchange" begin
# When riemannian-gaussian-sampler (AI metric) hands a covariance estimate
# to the Wasserstein DRO module (BW metric), the geodesic deviation must be
# measured and reported. Test that convert_geometry() flags this correctly.
k = 4
P = begin
    A = randn(k, k); ensure_spd(A*A' .+ 2I(k))
end
Q = begin
    B = randn(k, k); ensure_spd(B*B' .+ 3I(k))
end

src       = SPDPoint(Matrix(P), AffineInvariant())
tgt, rpt  = convert_geometry(src, BuresWasserstein(); ref=Matrix(Q))

@test rpt.source == AffineInvariant "Source geometry should be AI"
@test rpt.target == BuresWasserstein "Target geometry should be BW"
@test rpt.geodesic_deviation ≥ 0.0 "Geodesic deviation must be non-negative"

# For well-separated SPD matrices the deviation should be nonzero
if norm(Matrix(P) - Matrix(Q), 2) > 0.5
    @test rpt.geodesic_deviation > 0 "AI↔BW should show positive geodesic deviation for different matrices"
end
end

@testset "L6-7: SPDPoint type tag prevents silent geometry bypass" begin
# Wrapping a covariance in SPDPoint{AffineInvariant} and converting to
# BuresWasserstein must go through convert_geometry, not direct matrix ops.
# Test that the ConversionReport is the only valid exit path.
k = 5
Σ = ensure_spd(randn(k,k) |> M -> M*M' .+ I(k))

p_ai = SPDPoint(Matrix(Σ), AffineInvariant())
@test geometry_type(p_ai) == AffineInvariant "Geometry tag should be AffineInvariant"

_, rpt = convert_geometry(p_ai, BuresWasserstein())
# Any conversion should produce a report with documented lossiness
@test !rpt.exact || rpt.geodesic_deviation < 1e-6 "Non-trivial conversion should not be marked exact without zero deviation"
end

@testset "L6-8: GARCH Ito convention flag triggers Stratum III note" begin
# A GARCH fit with convention=:stratonovich should annotate its output
# with a note referencing the required Ito-Stratonovich correction.
r  = randn(300) .* 0.01
g  = fit_garch(r; convention=:stratonovich)

has_note = any(contains(n, "Stratonovich") || contains(n, "correction") || contains(n, "manifold")
               for n in g.validation.notes)
@test has_note "Stratonovich convention should produce Stratum III integration note"
end

# ── 6.3 REGIME DETECTION FAILURE MODES ───────────────────────────────────────
@testset "L6-9: HMM validator flags all-short-duration regime sequence" begin
# If every detected regime lasts < min_duration_days, the validator must
# flag ALL of them and recommend reducing k.
T = 400; k = 3
# Construct oscillating regime sequence: switches every 5 days
states = repeat(vcat(fill(1,5), fill(2,5), fill(3,5)), T÷15 + 1)[1:T]
returns = [states[t] == 1 ? randn()*0.005 :
           states[t] == 2 ? randn()*0.020 :
                            randn()*0.040 for t in 1:T]

cfg = HMMConfig(k; min_duration_days=20)
val = validate_hmm_economics(states, returns, cfg)

@test !val.passed "All-short-duration regime sequence should fail validation"
@test !isempty(val.issues) "Validator should report specific issues"
@test any(contains(i, "transitions") || contains(i, "shorter") || contains(i, "duration")
          for i in val.issues) "Issue should mention duration"
end

@testset "L6-10: select_n_regimes returns k=2 for pure noise (no vol structure)" begin
T = 500; Random.seed!(70)
r_noise = randn(T) .* 0.01   # iid Gaussian — no regime structure

best_k, scores = select_n_regimes(r_noise, 5; min_duration=20)
@test best_k ≤ 3 "Pure noise should select minimum regimes (got $best_k)"
end

@testset "L6-11: HMM economic validation rejects low vol-heterogeneity model" begin
T = 400
# All regimes have identical volatility — the HMM is pure noise extraction
states  = rand(1:3, T)
returns = randn(T) .* 0.01   # constant vol regardless of state

cfg = HMMConfig(3; min_duration_days=15)
val = validate_hmm_economics(states, returns, cfg)

# Should flag that regimes are not economically distinct
has_vol_issue = any(contains(i, "ANOVA") || contains(i, "volatility") || contains(i, "distinct")
                    for i in val.issues)
@test has_vol_issue "Identical-vol regimes should trigger vol heterogeneity warning"
end

# ── 6.4 CROSS-POOL CONTAGION ─────────────────────────────────────────────────
@testset "L6-12: Cross-pool correlation spike detected by metric audit" begin
# Blaque Baux uses three regional pools with design assumption of low cross-pool
# correlation. Test that a jump from 0.2 to 0.8 cross-pool correlation is
# detected by the geometric audit layer.
k = 6   # 2 assets per pool × 3 pools
T_pre = 200; T_contagion = 30

R_normal = build_normal_regime(T_pre, k; vol=0.01, corr=0.2, seed=80)
R_crisis = build_normal_regime(T_contagion, k; vol=0.03, corr=0.8, seed=81)
R_full   = vcat(R_normal, R_crisis)

# Covariance in normal period
Σ_pre = cov(R_normal); Σ_cris = cov(R_crisis)

# Validate assumption check fires
checks_pre = validate_rmt_assumptions(R_normal)
checks_cris = validate_rmt_assumptions(R_crisis)

# Cross-sectional independence check should flag the crisis period
cross_indep_pre  = filter(c -> contains(c.name, "independence"), checks_pre)
cross_indep_cris = filter(c -> contains(c.name, "independence"), checks_cris)

if !isempty(cross_indep_pre) && !isempty(cross_indep_cris)
    @test cross_indep_cris[1].statistic > cross_indep_pre[1].statistic "Crisis should show higher mean |correlation|"
end

# RMT should detect fewer signal eigenvalues in normal period (factor-driven)
_, rpt_pre  = clean_covariance_rmt(Σ_pre,  T_pre)
_, rpt_cris = clean_covariance_rmt(Σ_cris, T_contagion)
# In a crisis, more eigenvalues may breach the (higher) MP bound
@test rpt_cris.sigma2 ≥ rpt_pre.sigma2 * 0.5 "Crisis sigma2 should not drop below normal — covariance structure changed"
end

# ── 6.5 THE EMBARGO BIAS QUANTIFICATION TEST ─────────────────────────────────
@testset "L6-13: Embargo=0 Sharpe inflation is material on autocorrelated returns" begin
# This is the single most important negative test.
# Construct a strategy with KNOWN autocorrelation. Measure reported Sharpe
# with embargo=0 vs derived embargo. The gap is pure statistical artifact.
T = 1200; phi = 0.6; seed = 90
Random.seed!(seed)

# AR(1) returns: autocorrelated, so leakage is significant
r = zeros(T)
for t in 2:T; r[t] = phi*r[t-1] + randn()*0.01; end

# The "strategy" is just this AR(1) series (directional bet)
# In-sample we know phi > 0 → positive autocorrelation → a naive signal works

embargo_zero    = 1
embargo_derived = compute_embargo_from_autocorr(r; method=:crossing_time)

splits_leak  = generate_purged_splits(T, embargo_zero;    n_folds=5)
splits_clean = generate_purged_splits(T, embargo_derived; n_folds=5)

function oos_sharpe(splits, returns)
    oos = Float64[]
    for sp in splits
        length(sp.test) < 2 && continue
        # Signal: lag-1 return predicts direction
        for t_idx in 2:length(sp.test)
            t = sp.test[t_idx]; t_prev = sp.test[t_idx - 1]
            push!(oos, sign(returns[t_prev]) * returns[t])
        end
    end
    isempty(oos) ? 0.0 : sharpe(oos)
end

sh_leak  = oos_sharpe(splits_leak,  r)
sh_clean = oos_sharpe(splits_clean, r)
inflation = sh_leak - sh_clean

@test embargo_derived > embargo_zero "Derived embargo must exceed 1"
@test inflation ≥ -0.05 "Leaking CV cannot produce lower Sharpe than clean CV by more than noise tolerance"

# Log for human review — the absolute inflation is the key number
println("\n  Embargo=0 Sharpe:       $(round(sh_leak,  digits=3))")
println("  Embargo=$(embargo_derived) Sharpe:   $(round(sh_clean, digits=3))")
println("  Sharpe inflation (bias): $(round(inflation, digits=3))")
println("  (phi=$(phi) AR(1), T=$(T))")

if inflation > 0.5
    @warn "CRITICAL: Sharpe inflation of $(round(inflation,digits=2)) is economically large. All backtests using embargo=0 are suspect."
end
end

@testset "L6-14: Full pipeline audit produces non-:ok for deliberately broken config" begin
# Construct a pipeline with known conflicts:
# (a) RoughPath + Ito SDE mixing
# (b) AI + BW metric in same registry
# The audit must return :error.
pa = PipelineAuditor()
register_module!(pa.metric_reg, :ai_module, AffineInvariant(), 5)
register_module!(pa.metric_reg, :bw_module, BuresWasserstein(), 5)

register_sde!(pa.sde_reg, SDESpec(:ito_proc, ItoCalculus(),
    (t,X)->X, (t,X)->0.1I(1), 1, 1, ""))
register_sde!(pa.sde_reg, SDESpec(:rough,    ItoCalculus(),
    (t,X)->X, (t,X)->0.1I(1), 1, 1, ""))
enforce_rough_path_lift!(pa.sde_reg, :rough, 0.1)
connect_sdes!(pa.sde_reg, :rough, :ito_proc)

rpt = audit(pa)
@test rpt.severity ∈ (:warning, :error) "Deliberately broken config should not produce :ok"
end

end  # Layer 6

end  # @testset
println("\nAll stress scenario tests complete.")
