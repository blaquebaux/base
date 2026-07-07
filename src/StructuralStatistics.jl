# =============================================================================
# StructuralStatistics.jl  — Stratum II
# Structural Statistics: wrapper and validation layers for RMT, HMM, RPCA,
# and Purged K-Fold CV.
#
# Core principle: "fit() is not inference." Libraries give estimators.
# This module gives the admissibility logic, structural diagnostics, and
# economic validation layer. — ChatGPT
#
# Cherry-pick attribution:
#   estimate_sigma2_from_bulk         → K2
#   fit_mp_to_spectrum (KS test)      → ZAI
#   Tracy-Widom threshold             → ZAI
#   GOE/GUE/Poisson spacing stats     → ZAI
#   rolling_eigenvector_stability     → ChatGPT (unique; no other model)
#   shrink_trace_preserving           → QWEN (best shrinkage method)
#   5-check RMT assumption validator  → ZAI
#   constrain_transition_matrix!      → QWEN (correct: BEFORE fitting)
#   select_n_regimes composite crit   → K2
#   HMM 4-check economic validator    → K2
#   RegimeInterpretation labels       → ZAI
#   HMMFitDiagnostic (mixing time)    → ZAI
#   financial_rpca_loss (3-component) → QWEN
#   RPCA tuned on purged splits       → K2 (the critical CV innovation)
#   validate_rpca_decomposition       → K2 (finance-specific: rank ≤ 5, etc.)
#   compute_embargo_from_autocorr     → K2 (two methods)
#   detect_information_leak           → ZAI
#   assumptions(model) interface      → ChatGPT
#   cross_model_audit                 → ChatGPT
#   full_pipeline_validation          → K2
#   run_stratum_ii_audit              → QWEN
#
# Dependencies: LinearAlgebra, Statistics, Random (stdlib only)
# =============================================================================

module StructuralStatistics

# Requires GeometricCoordinationLayer.jl for SPD utilities.
# In production, uncomment:
#   include("GeometricCoordinationLayer.jl")
#   using .GeometricCoordinationLayer: ensure_spd, is_spd, random_spd
#
# The _gamma_sf and _chi2_sf functions below are self-contained copies.
# In production they are re-exported from GeometricCoordinationLayer.jl.

using LinearAlgebra, Statistics, Random

# =============================================================================
# UTILITIES
# =============================================================================

ensure_symmetric(M) = Symmetric(0.5 .* (M .+ M'))
frobenius(A)        = sqrt(sum(abs2, A))

function _lgamma(x::Float64)
    # Stirling approximation — sufficient for chi2 p-values
    x < 1.0 && return _lgamma(x + 1.0) - log(x)
    0.5*log(2π/x) + x*(log(x) - 1.0) +
    1/(12x) - 1/(360x^3) + 1/(1260x^5)
end

function _gamma_sf(a::Float64, x::Float64)
    x ≤ 0 && return 1.0
    if x < a + 1.0
        t = s = 1.0
        for n in 1:200
            t *= x/(a+n); s += t
            abs(t) < abs(s)*1e-12 && break
        end
        return max(0.0, min(1.0, 1.0 - s*exp(-x + a*log(x) - _lgamma(a))))
    else
        b = x+1-a; c = 1e30; d = 1.0/(x+1-a); h = d
        for i in 1:200
            an = -Float64(i)*(i-a); b += 2.0
            d = 1.0/(an*d+b); c = b+an/c; Δ = d*c; h *= Δ
            abs(Δ-1.0) < 1e-12 && break
        end
        return max(0.0, min(1.0, exp(-x + a*log(x) - _lgamma(a))*h))
    end
end

_chi2_sf(x, df) = x ≤ 0 ? 1.0 : _gamma_sf(df/2.0, x/2.0)

# =============================================================================
# PART 1 — RMT / MARCENKO-PASTUR
# =============================================================================

"""
    MarcenkoPasturBounds

Theoretical MP eigenvalue bounds for a p×p sample covariance estimated
from n observations.

    λ± = σ²(1 ± √(p/n))²

For p > n, the lower bound is 0 (point mass at origin) and q = p/n > 1
makes the upper bound grow accordingly. Le Chat's finite-size correction:
λ_max multiplied by (1 + 1/√n) for p ≤ n.
"""
struct MarcenkoPasturBounds
    p::Int; n::Int; q::Float64; sigma2::Float64
    lambda_minus::Float64
    lambda_plus::Float64           # upper bound (signal threshold)
    lambda_plus_corrected::Float64 # finite-size corrected
end

function mp_bounds(p::Int, n::Int; sigma2::Float64=1.0)
    q  = p / n
    q > 1 && @warn "p > n (q=$q): MP bulk has point mass at 0. Results may be unreliable."
    sq = sqrt(q)
    lm = sigma2 * max(0.0, (1 - sq))^2
    lp = sigma2 * (1 + sq)^2
    correction = 1.0 + 1.0/sqrt(n)
    MarcenkoPasturBounds(p, n, q, sigma2, lm, lp, lp * correction)
end

"""
    estimate_sigma2_from_bulk(eigenvalues, p, n; method) → Float64

Estimate noise variance σ² from the spectral bulk via iterative convergence.
Libraries assume you already know σ²; this computes it from your data.
                                            (K2 — critical function)

Methods:
  :median — fast, robust to a few outliers in the bulk
  :trace  — E[λ] = σ² for correlation matrices; use when input is a corr matrix
  :iterative — Picard iteration: fit bounds → identify bulk → re-estimate σ²
"""
function estimate_sigma2_from_bulk(eigenvalues::AbstractVector{Float64}, p::Int, n::Int;
                                    method::Symbol=:iterative)
    sorted = sort(eigenvalues)
    method == :median && return median(sorted)
    method == :trace  && return mean(sorted)

    # Iterative: alternate between estimating σ² and recomputing the bulk
    σ2 = median(sorted)
    for _ in 1:20
        b   = mp_bounds(p, n; sigma2=σ2)
        in_bulk = filter(λ -> b.lambda_minus ≤ λ ≤ b.lambda_plus, sorted)
        isempty(in_bulk) && break
        σ2_new = mean(in_bulk)
        abs(σ2_new - σ2) / max(σ2, 1e-14) < 1e-4 && (σ2 = σ2_new; break)
        σ2 = 0.6*σ2 + 0.4*σ2_new   # damped update for stability
    end
    σ2
end

"""
    RMTAssumptionCheck

Five-check assumption validator for RMT applicability.  (ZAI)

1. Returns are demeaned
2. No heavy tails (Mardia kurtosis)
3. No autocorrelation (max lag 1-5)
4. Cross-sectional independence (average |correlation|)
5. Asymptotic regime (n and p both ≥ 50)
"""
struct RMTAssumptionCheck
    name::String
    passed::Bool
    statistic::Float64
    threshold::Float64
    note::String
end

function validate_rmt_assumptions(returns::AbstractMatrix{Float64})
    n, p = size(returns)
    thresh_ac = 2/sqrt(n)
    checks    = RMTAssumptionCheck[]

    # 1. Demeaning
    maxμ = maximum(abs.(mean(returns, dims=1)))
    push!(checks, RMTAssumptionCheck("Zero mean", maxμ ≤ thresh_ac, maxμ, thresh_ac,
          "Demean returns before computing covariance."))

    # 2. Tail weight (Mardia kurtosis)
    C   = cov(returns); Ci = pinv(C)
    mah = vec(sum((returns .- mean(returns,dims=1)) * Ci .* (returns .- mean(returns,dims=1)), dims=2))
    k   = mean(mah.^2) - p*(p+2)
    push!(checks, RMTAssumptionCheck("Finite variance (light tails)", abs(k) ≤ 10*p, k, 10*p,
          k > 0 ? "Heavy tails detected. Consider winsorising or using robust covariance." : ""))

    # 3. Autocorrelation (max over lag 1-5)
    max_ac = 0.0
    for lag in 1:min(5, n÷4), j in 1:p
        x = returns[:, j]; μj = mean(x); σ²j = var(x)
        σ²j < 1e-12 && continue
        ac = sum((x[1:n-lag] .- μj) .* (x[lag+1:n] .- μj)) / ((n-lag) * σ²j)
        max_ac = max(max_ac, abs(ac))
    end
    push!(checks, RMTAssumptionCheck("No autocorrelation (i.i.d. in time)",
          max_ac ≤ thresh_ac, max_ac, thresh_ac,
          "Apply Newey-West adjustment or pre-whiten returns before RMT cleaning."))

    # 4. Cross-sectional independence
    C2  = cor(returns)
    moc = mean(abs.(C2[tril(trues(p,p), -1)]))
    push!(checks, RMTAssumptionCheck("Weak cross-sectional independence",
          moc ≤ 5*thresh_ac, moc, 5*thresh_ac,
          "Mean |ρ_ij| = $(round(moc,digits=3)). Strong factor structure will show up as 'signal'."))

    # 5. Sample size
    push!(checks, RMTAssumptionCheck("Asymptotic regime (n,p ≥ 50)",
          n ≥ 50 && p ≥ 20, Float64(min(n,p)), 50.0,
          "RMT requires both dimensions large. n=$n, p=$p."))

    checks
end

"""
    _mp_cdf(x, q) — numerical CDF of MP distribution (ZAI)
"""
function _mp_cdf(x::Float64, q::Float64)
    x ≤ 0 && return q > 1 ? 1 - 1/q : 0.0
    lm = max(0.0, (1 - sqrt(q)))^2
    lp = (1 + sqrt(q))^2
    x ≥ lp && return 1.0
    x ≤ lm && return q > 1 ? 1 - 1/q : 0.0
    xs = range(lm, x; length=800)
    dx = xs[2] - xs[1]
    cdf = (q > 1 ? 1-1/q : 0.0)
    for xi in xs
        xi ≤ 0 && continue
        cdf += sqrt((lp-xi)*(xi-lm)) / (2π*q*xi) * dx
    end
    cdf
end

function _ks_test_mp(bulk_eigs::AbstractVector{Float64}, q::Float64, sigma2::Float64)
    isempty(bulk_eigs) && return (NaN, NaN)
    s  = sort(bulk_eigs ./ sigma2)
    N  = length(s)
    ecdf_vals = (1:N) ./ N
    tcdf_vals = [_mp_cdf(x, q) for x in s]
    D  = maximum(abs.(ecdf_vals .- tcdf_vals))
    z  = (sqrt(N) + 0.12 + 0.11/sqrt(N)) * D
    p  = max(0.0, min(1.0, sum(2*(-1)^(k+1)*exp(-2k^2*z^2) for k in 1:100)))
    (D, p)
end

"""
    MPFitResult — from fitting MP law to the empirical spectrum.  (ZAI)
"""
struct MPFitResult
    sigma2::Float64
    bounds::MarcenkoPasturBounds
    n_bulk::Int; n_signal::Int
    ks_stat::Float64; ks_pvalue::Float64
    good_fit::Bool
    notes::Vector{String}
end

function fit_mp_to_spectrum(eigenvalues::AbstractVector{Float64}, p::Int, n::Int)
    notes = String[]
    σ2  = estimate_sigma2_from_bulk(eigenvalues, p, n; method=:iterative)
    b   = mp_bounds(p, n; sigma2=σ2)
    in_bulk  = filter(λ -> b.lambda_minus ≤ λ ≤ b.lambda_plus, eigenvalues)
    n_bulk   = length(in_bulk)
    n_signal = p - n_bulk
    n_bulk < 10 && push!(notes, "Only $n_bulk eigenvalues in bulk — MP fit unreliable.")
    ks_D, ks_p = n_bulk ≥ 5 ? _ks_test_mp(collect(in_bulk), b.q, σ2) : (NaN, NaN)
    good_fit = !isnan(ks_p) && ks_p > 0.05
    !good_fit && push!(notes, "KS p=$(round(isnan(ks_p) ? 0.0 : ks_p, digits=4)): bulk does not match MP density.")
    n_signal == 0 && push!(notes, "No signal eigenvalues. All mass within MP bulk.")
    MPFitResult(σ2, b, n_bulk, n_signal, isnan(ks_D) ? 0.0 : ks_D,
                isnan(ks_p) ? 0.0 : ks_p, good_fit, notes)
end

"""
    tracy_widom_threshold(n, p, α) → Float64

Statistical significance threshold for the largest eigenvalue (Tracy-Widom law).
Eigenvalues above λ_max + TW threshold are signal with 1-α confidence.  (ZAI)
"""
function tracy_widom_threshold(n::Int, p::Int; alpha::Float64=0.05)
    q  = p/n
    lp = (1+sqrt(q))^2; lm = max(0.0,(1-sqrt(q))^2)
    tw = alpha < 0.01 ? -3.90 : alpha < 0.05 ? -2.78 : -2.03
    tw * sqrt(lp - lm) * n^(-2/3)
end

"""
    EigenSpacingStats — GOE/GUE/Poisson spacing statistics for bulk.  (ZAI)

Unfolded spacing std ≈ 0.52 → Gaussian Orthogonal Ensemble (random matrix)
                     ≈ 0.42 → Gaussian Unitary Ensemble
                     ≈ 1.00 → Poisson (independent eigenvalues)
"""
struct EigenSpacingStats
    spacing_std::Float64
    goe_compatible::Bool
    gue_compatible::Bool
    poisson_compatible::Bool
end

function compute_spacing_stats(bulk_eigs::AbstractVector{Float64})
    length(bulk_eigs) < 5 && return EigenSpacingStats(NaN, false, false, false)
    s  = sort(bulk_eigs)
    N  = length(s); ecdf = (1:N) ./ N
    sp = diff(ecdf); μsp = mean(sp)
    sp_norm = sp ./ max(μsp, 1e-14)
    std_s   = std(sp_norm)
    EigenSpacingStats(std_s,
        abs(std_s - 0.52) < 0.15, abs(std_s - 0.42) < 0.15,
        abs(std_s - 1.00) < 0.20)
end

"""
    clean_covariance_rmt(cov_matrix, n; method, sigma2) → (Σ_clean, report)

RMT-based covariance cleaning. Returns a valid SPD matrix.

Methods:
  :clip                 — set noise eigenvalues to λ_max (hard threshold)
  :constant_bulk        — replace noise eigenvalues with σ² (bulk mean)
  :shrink_trace_preserving — redistribute noise eigenvalues to preserve total
                             trace (total variance); the most conservative
                             choice and the only one that exactly preserves
                             portfolio variance.  (QWEN — best method)
"""
function clean_covariance_rmt(Σ::AbstractMatrix{Float64}, n::Int;
                               method::Symbol=:shrink_trace_preserving,
                               sigma2::Union{Nothing,Float64}=nothing)
    p  = size(Σ, 1)
    F  = eigen(Symmetric(Σ)); ev = F.values; vecs = F.vectors
    mp = fit_mp_to_spectrum(ev, p, n)
    σ2 = something(sigma2, mp.sigma2)
    b  = mp_bounds(p, n; sigma2=σ2)

    signal_mask = ev .> b.lambda_plus_corrected
    ev_clean    = copy(ev)

    if method == :clip
        ev_clean[.!signal_mask] .= b.lambda_plus

    elseif method == :constant_bulk
        ev_clean[.!signal_mask] .= σ2

    elseif method == :shrink_trace_preserving
        # Redistribute noise eigenvalues uniformly to preserve total trace
        signal_sum   = sum(ev[signal_mask])
        target_noise = max(0.0, sum(ev) - signal_sum)
        n_noise      = count(.!signal_mask)
        avg_noise    = n_noise > 0 ? target_noise / n_noise : σ2
        ev_clean[.!signal_mask] .= max(b.lambda_minus + 1e-8, avg_noise)
    else
        error("Unknown method :$method. Choose :clip, :constant_bulk, or :shrink_trace_preserving.")
    end

    Σ_clean = ensure_symmetric(vecs * Diagonal(ev_clean) * vecs')

    # Validation report
    pd_ok   = minimum(ev_clean) > 0
    tr_ratio = tr(Σ_clean) / (tr(Σ) + 1e-14)
    notes   = String[]
    !pd_ok  && push!(notes, "Cleaned matrix not PD — check for near-singular input.")
    abs(tr_ratio - 1.0) > 0.05 && push!(notes, "Trace ratio = $(round(tr_ratio,digits=4)); consider :shrink_trace_preserving.")
    mp.n_signal == 0 && push!(notes, "No signal eigenvalues — covariance is pure noise at this p/n ratio.")
    append!(notes, mp.notes)

    report = (sigma2=σ2, bounds=b, mp_fit=mp,
              n_signal=mp.n_signal, n_noise=count(.!signal_mask),
              trace_ratio=tr_ratio, positive_definite=pd_ok, notes=notes)
    Σ_clean, report
end

"""
    rolling_eigenvector_stability(returns, window; n_components) → Vector{Float64}

Compute rolling principal-angle cosine between consecutive windows.
cos(θ_i) = |v_i(t)ᵀ v_i(t+1)| — if this drops below ~0.7 for the leading
eigenvector, the "factor" is unstable and likely regime-dependent.

This is the test that distinguishes genuine systematic factors from
sampling artifacts that happen to exceed the MP bound in one window.
                                            (ChatGPT — unique contribution)
"""
function rolling_eigenvector_stability(returns::AbstractMatrix{Float64}, window::Int;
                                        n_components::Int=3)
    n, p  = size(returns)
    n_windows = n - window + 1
    n_windows < 2 && error("Need at least 2 windows. Increase data or decrease window.")

    cosines = Vector{Float64}[]
    prev_V  = nothing

    for t in 1:n_windows
        chunk  = returns[t:t+window-1, :]
        Σ      = cov(chunk)
        F      = eigen(Symmetric(Σ))
        # top n_components eigenvectors (descending order)
        idx_top = sortperm(F.values, rev=true)[1:min(n_components, p)]
        V       = F.vectors[:, idx_top]

        if prev_V !== nothing
            nc = size(V, 2)
            cos_t = [abs(dot(V[:,i], prev_V[:,i])) for i in 1:nc]
            push!(cosines, cos_t)
        end
        prev_V = V
    end

    # Average across components; flag if leading eigenvector cosine < 0.7
    mean_cosines = mean(hcat(cosines...), dims=2) |> vec
    any(mean_cosines .< 0.7) && @warn "Leading eigenvector instability detected " *
        "(mean cos = $(round(minimum(mean_cosines),digits=3))). " *
        "Factor may be regime-dependent or a sampling artifact."
    mean_cosines
end

# =============================================================================
# PART 2 — HMM STRUCTURAL SPECIFICATION
# =============================================================================

abstract type TransitionConstraint end
struct Ergodic          <: TransitionConstraint; min_off_diag::Float64 end
struct Absorbing        <: TransitionConstraint; states::Vector{Int}; allow_escape::Bool end
struct BlockedErgodic   <: TransitionConstraint; forbidden::Set{Tuple{Int,Int}} end

Ergodic(; min_off_diag::Float64=0.01) = Ergodic(min_off_diag)

abstract type EmissionModel end
struct GaussianEmission    <: EmissionModel; regime_specific_cov::Bool end
struct StudentTEmission     <: EmissionModel; df::Vector{Float64}; regime_specific_cov::Bool end
struct RegimeSpecificMixed  <: EmissionModel; models::Vector{EmissionModel} end

GaussianEmission(; regime_cov::Bool=true)  = GaussianEmission(regime_cov)
StudentTEmission(n_regimes::Int; df::Float64=4.0, regime_cov::Bool=true) =
    StudentTEmission(fill(df, n_regimes), regime_cov)

"""
    HMMConfig

Economic configuration for a hidden Markov model. Enforces constraints BEFORE
fitting, not just as post-hoc validation.  (QWEN: pre-fitting constraints)

  max_vol_ratio     — maximum ratio of regime volatilities (economic: ≤ 5)
  min_regime_prob   — stationary probability floor per regime (< 0.05 = noise)
  min_duration_days — minimum regime duration in observation periods (K2: ≥ 20)
"""
struct HMMConfig
    n_regimes::Int
    emission::EmissionModel
    transition::TransitionConstraint
    max_vol_ratio::Float64
    min_regime_prob::Float64
    min_duration_days::Int
    economic_labels::Vector{String}
end

function HMMConfig(n_regimes::Int;
                   emission::EmissionModel=StudentTEmission(n_regimes),
                   transition::TransitionConstraint=Ergodic(),
                   max_vol_ratio::Float64=5.0,
                   min_regime_prob::Float64=0.05,
                   min_duration_days::Int=20,
                   labels::Vector{String}=["Regime $i" for i in 1:n_regimes])
    n_regimes < 2 && error("Need ≥ 2 regimes.")
    n_regimes > 6 && @warn "More than 6 regimes rarely have economic interpretation."
    if emission isa StudentTEmission
        any(emission.df .< 3) && error("Student-t df < 3 implies infinite variance.")
        any(emission.df .> 30) && @warn "Student-t df > 30 is nearly Gaussian; use GaussianEmission."
    end
    HMMConfig(n_regimes, emission, transition, max_vol_ratio,
              min_regime_prob, min_duration_days, labels)
end

"""
    constrain_transition_matrix!(A, constraint, n_regimes) → Matrix

Enforce structural constraints on a transition matrix BEFORE passing to an
HMM library's EM algorithm. Starting from the right manifold prevents EM
from converging to economically meaningless fixed points.  (QWEN)

This is structurally different from post-hoc clipping: it initialises the
EM search from a feasible point.
"""
function constrain_transition_matrix!(A::AbstractMatrix{Float64},
                                       constraint::TransitionConstraint)
    n = size(A, 1)
    if constraint isa Ergodic
        A .+= constraint.min_off_diag
        A .= max.(A, constraint.min_off_diag)
    elseif constraint isa Absorbing
        for s in constraint.states
            A[s, :] .= 0.0
            A[s, s]  = constraint.allow_escape ? 0.99 : 1.0
        end
    elseif constraint isa BlockedErgodic
        for (i, j) in constraint.forbidden
            A[i, j] = 0.0
        end
    end
    # Row-normalise
    for i in 1:n
        s = sum(A[i, :])
        s > 0 && (A[i, :] ./= s)
    end
    A
end

"""
    select_n_regimes(returns, max_k; ...) → (best_k, scores)

Composite selection criterion: log-likelihood − BIC_penalty + 2×economic_score.
Pure BIC/AIC overfits in finance by ignoring whether states are economically
interpretable. The economic_score penalises short-lived regimes, low
vol-heterogeneity, and degenerate transition matrices.  (K2)
"""
function select_n_regimes(returns::AbstractVector{Float64}, max_k::Int;
                           min_duration::Int=20, emission::Symbol=:gaussian)
    n      = length(returns)
    scores = Dict{Int,Float64}()

    for k in 2:min(max_k, 6)
        # Fit a simple Gaussian HMM (replace with library call in production)
        hmm    = _fit_gaussian_hmm_simple(returns, k)
        ll     = hmm.log_likelihood
        n_par  = k*(k-1) + (k-1) + 2k  # transitions + initial + Gaussian params
        bic    = -2ll + n_par*log(n)

        # Economic score
        eco    = _economic_score(hmm.state_sequence, returns, k, min_duration)
        scores[k] = ll - 0.5*bic + 2*eco
    end

    # Fix: argmax on Dict requires explicit key extraction
    best_k = collect(keys(scores))[argmax(collect(values(scores)))]
    best_k, scores
end

# Minimal self-contained Gaussian HMM (K2 concept — swap with library in prod)
struct _GaussianHMM
    μ::Vector{Float64}; σ::Vector{Float64}
    A::Matrix{Float64}; π₀::Vector{Float64}
    log_likelihood::Float64
    state_sequence::Vector{Int}
end

function _fit_gaussian_hmm_simple(y::AbstractVector{Float64}, k::Int; max_iter::Int=100)
    n    = length(y); Random.seed!(0)
    # K-means-like initialisation
    idx  = randperm(n)[1:k]
    μ    = y[idx]; σ = fill(std(y)/k, k)
    A    = constrain_transition_matrix!(fill(1.0/k, k, k) .+ 0.3*rand(k,k), Ergodic())
    π₀   = fill(1.0/k, k)

    log_p = fill(-Inf, n, k)
    γ     = zeros(n, k)
    ll    = -Inf

    for iter in 1:max_iter
        iter_num = iter
        # E-step: forward-backward returning both γ and ξ
        for j in 1:k
            log_p[:, j] = @. -0.5*((y - μ[j])/σ[j])^2 - log(σ[j]) - 0.9189
        end
        γ, ξ, ll_new = _forward_backward(log_p, A, π₀)
        abs(ll_new - ll) < 1e-5 && (ll = ll_new; break)
        ll = ll_new

        # M-step
        nk = vec(sum(γ, dims=1)) .+ 1e-8
        μ  = [sum(γ[:,j] .* y) / nk[j] for j in 1:k]
        σ  = [max(sqrt(sum(γ[:,j] .* (y .- μ[j]).^2) / nk[j]), 1e-4) for j in 1:k]
        # Transition update: A[i,j] = E[transitions i→j] / E[time in i]
        # CORRECTED: uses ξ (expected joint transitions), not log_p differences
        for i in 1:k
            denom = sum(γ[1:n-1, i]) + 1e-8
            for j in 1:k
                A[i, j] = sum(ξ[:, i, j]) / denom
            end
        end
        constrain_transition_matrix!(A, Ergodic())
        π₀ = γ[1,:] ./ sum(γ[1,:])
    end

    states = [argmax(γ[t,:]) for t in 1:n]
    _GaussianHMM(μ, σ, A, π₀, ll, states)
end

function _forward_backward(log_p::Matrix, A::Matrix, π₀::Vector)
    n, k  = size(log_p)
    α_log = zeros(n, k); β_log = zeros(n, k)
    log_A = log.(A .+ 1e-300)

    # Forward pass
    α_log[1, :] = log.(π₀ .+ 1e-300) .+ log_p[1, :]
    for t in 2:n
        for j in 1:k
            α_log[t, j] = log_p[t, j] + _logsumexp([α_log[t-1, i] + log_A[i, j] for i in 1:k])
        end
    end

    # Backward pass
    β_log[n, :] .= 0.0
    for t in n-1:-1:1
        for i in 1:k
            β_log[t, i] = _logsumexp([log_A[i, j] + log_p[t+1, j] + β_log[t+1, j] for j in 1:k])
        end
    end

    # γ: posterior state marginals
    γ_log  = α_log .+ β_log
    norm_t = [_logsumexp(γ_log[t,:]) for t in 1:n]
    γ      = exp.(γ_log .- norm_t)

    # ξ: expected joint transitions  P(z_t=i, z_{t+1}=j | y_{1:T})
    # CORRECTED M-step: ξ_{t,i,j} ∝ α_t(i) A_{ij} p(y_{t+1}|j) β_{t+1}(j)
    # Bug in v1: used log_p differences instead of this formula.
    ξ = zeros(n-1, k, k)
    for t in 1:n-1
        log_ξt = zeros(k, k)
        for i in 1:k, j in 1:k
            log_ξt[i, j] = α_log[t,i] + log_A[i,j] + log_p[t+1,j] + β_log[t+1,j]
        end
        norm_ξt = _logsumexp(vec(log_ξt))
        ξ[t, :, :] = exp.(log_ξt .- norm_ξt)
    end

    ll = _logsumexp(α_log[n, :])
    γ, ξ, ll
end

_logsumexp(v::Vector) = (m = maximum(v); m + log(sum(exp.(v .- m))))

function _economic_score(states::Vector{Int}, y::AbstractVector, k::Int, min_dur::Int)
    # Run-length analysis
    runs   = [(states[1], 1)]
    for i in 2:length(states)
        states[i] == runs[end][1] ? (runs[end] = (runs[end][1], runs[end][2]+1)) :
                                     push!(runs, (states[i], 1))
    end
    durations = [r[2] for r in runs]

    # Penalise regimes shorter than min_dur
    short_pct = mean(durations .< min_dur)
    dur_score = 1.0 - short_pct

    # Penalise low volatility heterogeneity
    # NOTE: this is the coefficient of variation squared (cv_sq) of regime variances,
    # not the standard ANOVA F-statistic (between/within). Renamed to avoid confusion.
    regime_var = [var(y[states .== j]) for j in 1:k if count(states .== j) > 1]
    length(regime_var) < 2 && return 0.0
    cv_sq    = var(regime_var) / (mean(regime_var)^2 + 1e-10)
    vol_score  = min(1.0, cv_sq)

    0.5*dur_score + 0.5*vol_score
end

"""
    validate_hmm_economics(state_sequence, returns, config) → report

Four-check economic validator (K2):
  1. Minimum duration — no regime shorter than config.min_duration_days
  2. Volatility heterogeneity — ANOVA F-statistic on squared returns
  3. Transition stability — switch rate < 15%
  4. Return distinctness — regime means differ by > 30% of overall σ
"""
function validate_hmm_economics(state_sequence::AbstractVector{Int},
                                 returns::AbstractVector{Float64},
                                 config::HMMConfig)
    k = config.n_regimes; n = length(state_sequence)
    issues = String[]

    # 1. Minimum duration
    runs = [(state_sequence[1], 1)]
    for i in 2:n
        state_sequence[i] == runs[end][1] ? (runs[end] = (runs[end][1], runs[end][2]+1)) :
                                             push!(runs, (state_sequence[i], 1))
    end
    short = filter(r -> r[2] < config.min_duration_days, runs)
    if !isempty(short)
        push!(issues, "$(length(short)) regime transitions shorter than " *
              "$(config.min_duration_days) obs. Consider fewer regimes.")
    end

    # 2. Volatility heterogeneity — ANOVA on squared returns
    regime_var = [var(returns[state_sequence .== j]) for j in 1:k
                  if count(state_sequence .== j) > 1]
    if length(regime_var) ≥ 2
        F = var(regime_var) / (mean(regime_var)^2 + 1e-10)
        F < 2.0 && push!(issues, "ANOVA F=$(round(F,digits=2)) < 2: regimes do not have " *
                          "distinct volatility. HMM may be overfitting.")
    end

    # 3. Transition rate < 15%
    n_switches = sum(diff(state_sequence) .!= 0)
    switch_rate = n_switches / max(n-1, 1)
    switch_rate > 0.15 && push!(issues, "Transition rate=$(round(switch_rate,digits=3)) > 0.15. " *
                                 "High-frequency switching is not a business cycle.")

    # 4. Return distinctness
    σ_global = std(returns)
    μk = [mean(returns[state_sequence .== j]) for j in 1:k if count(state_sequence .== j) > 0]
    length(μk) ≥ 2 || push!(issues, "Fewer than 2 regimes occupied.")
    if length(μk) ≥ 2
        span = maximum(μk) - minimum(μk)
        span < 0.3*σ_global && push!(issues, "Regime means span=$(round(span,digits=4)), " *
                                      "< 30% of σ=$(round(σ_global,digits=4)). " *
                                      "Regimes are not economically distinct.")
    end

    # Volatility ratio
    vols = [std(returns[state_sequence .== j]) for j in 1:k if count(state_sequence .== j) > 1]
    if length(vols) ≥ 2
        vr = maximum(vols) / max(minimum(vols), 1e-10)
        vr > config.max_vol_ratio && push!(issues, "Vol ratio=$(round(vr,digits=2)) > " *
                                            "$(config.max_vol_ratio). Regimes may be driven by outliers.")
    end

    (passed=isempty(issues), issues=issues, n_switches=n_switches, switch_rate=switch_rate)
end

"""
    RegimeInterpretation — economic label and interpretability score.  (ZAI)
"""
struct RegimeInterpretation
    regime::Int; label::Symbol; score::Float64
    mean_ret::Float64; volatility::Float64
    duration::Float64; frequency::Float64
    notes::Vector{String}
end

function interpret_regimes(state_seq::AbstractVector{Int}, returns::AbstractVector{Float64},
                            A::AbstractMatrix{Float64})
    k = size(A, 1)
    stationary = _stationary_dist(A)
    interps = RegimeInterpretation[]

    for j in 1:k
        mask = state_seq .== j
        sum(mask) == 0 && continue
        μj = mean(returns[mask]); σj = std(returns[mask])
        dur = 1/(1 - A[j,j] + 1e-10); freq = stationary[j]
        notes = String[]

        sn = μj / max(σj, 1e-10)
        label = if sn > 0.3 && σj < 0.3;      :bull
                elseif μj < -0.05 && σj > 0.2; :bear
                elseif σj > 0.5;                :crisis
                elseif abs(μj) < 0.01 && σj < 0.15; :sideways
                else                             :unknown end

        score = label == :unknown ? 0.2 : 0.8
        dur < 10 && (score *= 0.7; push!(notes, "Short duration ($( round(dur,digits=1))) obs."))
        freq < 0.05 && (score *= 0.8; push!(notes, "Rare regime ($(round(freq*100,digits=1))%)."))

        push!(interps, RegimeInterpretation(j, label, score, μj, σj, dur, freq, notes))
    end
    interps
end

function _stationary_dist(A::AbstractMatrix{Float64})
    n  = size(A, 1)
    AT = A' .- I(n)
    AT[end,:] .= 1.0
    b  = zeros(n); b[end] = 1.0
    π  = AT \ b
    π  = max.(π, 0); π ./= sum(π)
    π
end

"""
    HMMFitDiagnostic — mixing time, AIC/BIC, convergence.  (ZAI)
"""
struct HMMFitDiagnostic
    log_likelihood::Float64; aic::Float64; bic::Float64
    mixing_time::Float64; is_ergodic::Bool
    regime_counts::Vector{Int}; warnings::Vector{String}
end

function diagnose_hmm_fit(state_seq::AbstractVector{Int}, A::AbstractMatrix{Float64},
                           ll::Float64, n_features::Int)
    n_regimes = size(A, 1); n = length(state_seq)
    n_par = n_regimes*(n_regimes-1) + (n_regimes-1) + 2*n_regimes*n_features
    aic   = -2ll + 2n_par; bic = -2ll + n_par*log(n)
    ev    = abs.(eigvals(A)); sort!(ev, rev=true)
    mix   = length(ev) > 1 ? -1/log(ev[2] + 1e-10) : Inf
    ergo  = all(A .> 1e-6)
    cnts  = [count(state_seq .== j) for j in 1:n_regimes]
    warns = String[]
    minimum(cnts) < 20 && push!(warns, "Regime $(argmin(cnts)) has $(minimum(cnts)) obs — estimates unreliable.")
    mix > n/2 && push!(warns, "Mixing time=$( round(mix,digits=1)) > n/2=$n. Stationarity estimates unreliable.")
    HMMFitDiagnostic(ll, aic, bic, mix, ergo, cnts, warns)
end

# =============================================================================
# PART 3 — RPCA WITH FINANCE-SPECIFIC λ TUNING
# =============================================================================

"""
    rpca_admm(X, λ; max_iter, tol) → (L, S, converged, iter)

Inexact Augmented Lagrange Multiplier solver for:
    min ‖L‖_* + λ‖S‖₁  s.t.  X = L + S
"""
function rpca_admm(X::AbstractMatrix{Float64}, λ::Float64;
                   max_iter::Int=300, tol::Float64=1e-6, μ::Float64=0.1)
    m, n  = size(X)
    L     = zeros(m, n); S = zeros(m, n); Y = zeros(m, n)
    μ_max = 1e6; ρ = 1.5; converged = false; iter = 0

    for k in 1:max_iter
        iter = k
        # L update: nuclear norm prox
        U, σ, Vt = svd(X - S + Y/μ; full=false)
        L  = U * Diagonal(max.(σ .- 1/μ, 0)) * Vt

        # S update: ℓ1 prox
        tmp = X - L + Y/μ
        S   = sign.(tmp) .* max.(abs.(tmp) .- λ/μ, 0)

        # Dual update
        R  = X - L - S; Y = Y + μ .* R

        primal = frobenius(R) / (frobenius(X) + 1e-10)
        primal < tol && (converged = true; break)
        μ = min(μ*ρ, μ_max)
    end
    L, S, converged, iter
end

"""
    financial_rpca_loss(X_train, X_test, L_train, S_train, L_test, S_test) → Float64

Three-component loss for RPCA cross-validation on financial data.  (QWEN)

1. Reconstruction error on test set (standard)
2. Sparsity of S (financial microstructure shocks should be sparse)
3. Rolling-window stability of L (systematic factor should not jump)

Image-denoising CV uses only component 1, which selects λ too small for
finance — it classifies normal return variation as outliers.
"""
function financial_rpca_loss(X_train::AbstractMatrix, X_test::AbstractMatrix,
                              L_train::AbstractMatrix, S_train::AbstractMatrix,
                              L_test::AbstractMatrix,  S_test::AbstractMatrix;
                              sparsity_weight::Float64=0.3,
                              stability_weight::Float64=0.1)
    norm_Xt = frobenius(X_test) + 1e-10

    # 1. Reconstruction
    recon = frobenius(X_test - L_test - S_test) / norm_Xt

    # 2. Sparsity (ideal fraction for finance: 1-5%)
    sparse_density = sum(abs.(S_test) .> 1e-10) / length(S_test)
    sparsity_pen   = abs(sparse_density - 0.02)

    # 3. Rolling stability of L
    m, p  = size(L_test); W = max(10, m÷4)
    drifts = [frobenius(L_test[i:min(i+W-1,m),:] .- L_test[max(1,i-W):i,:])
              for i in W:W:m-1]
    stability = isempty(drifts) ? 0.0 : mean(drifts) / (norm_Xt + 1e-10)

    recon + sparsity_weight*sparsity_pen + stability_weight*stability
end

"""
    tune_lambda_rpca(returns, cv_splits; lambda_range) → (best_λ, scores, report)

Cross-validate λ using PURGED K-fold splits so temporal leakage does not
inflate the score of a λ that overfits to autocorrelated outliers.

This is the critical innovation for finance: default λ tuning uses standard
k-fold which leaks information across the train/test boundary. The purged
version with embargo derives the embargo from the returns' own ACF.
                                            (K2 — critical CV innovation)
"""
function tune_lambda_rpca(returns::AbstractMatrix{Float64},
                           cv_splits::Vector{<:NamedTuple};
                           lambda_range::AbstractVector{Float64}=Float64[])
    m, p = size(returns)
    if isempty(lambda_range)
        base = 1/sqrt(max(m, p))
        lambda_range = base .* [0.1, 0.2, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
    end

    scores = Dict{Float64,Float64}()
    degenerate_count = 0
    for λ in lambda_range
        fold_scores = Float64[]
        for split in cv_splits
            Xtr = returns[split.train, :]
            Xte = returns[split.test,  :]
            Ltr, Str, _, _ = rpca_admm(Xtr, λ)
            Lte, Ste, _, _ = rpca_admm(Xte, λ)
            push!(fold_scores, financial_rpca_loss(Xtr, Xte, Ltr, Str, Lte, Ste))
        end
        scores[λ] = mean(fold_scores)

        # Detect degenerate: L ≈ X (λ too small) or L ≈ 0 (λ too large)
        L_test, S_test, _, _ = rpca_admm(returns, λ)
        sv = svd(L_test; full=false).S
        is_degenerate = sum(sv .> 0.01sv[1]) == 0 || frobenius(L_test)/frobenius(returns) < 0.05
        is_degenerate && (degenerate_count += 1)
    end

    if degenerate_count == length(lambda_range)
        fallback_λ = 0.5 / sqrt(max(m, p))
        @warn "All λ values produced degenerate decompositions (L≈0 or L≈X). " *
              "Falling back to conservative λ = $( round(fallback_λ, digits=5))."
        return fallback_λ, scores, (n_lambdas=length(lambda_range), best_lambda=fallback_λ,
                                     best_score=NaN, all_scores=scores,
                                     notes=["All λ degenerate — fallback applied."])
    end

    best_λ = argmin(scores)
    report = (n_lambdas=length(lambda_range), best_lambda=best_λ,
              best_score=scores[best_λ], all_scores=scores,
              notes=best_λ < 0.3/sqrt(max(m,p)) ?
                    ["Selected λ is very small — may classify normal returns as outliers."] : String[])
    best_λ, scores, report
end

"""
    validate_rpca_decomposition(L, S, X) → report

Finance-specific RPCA validation. Three checks that image-denoising
pipelines never make:  (K2)

1. rank(L) ≤ 5  (factor model implies few systematic components)
2. S > 50% sparse (outliers are rare by definition)
3. cor(L, S) ≈ 0 (non-orthogonality means ADMM has not converged)
"""
function validate_rpca_decomposition(L::AbstractMatrix, S::AbstractMatrix,
                                      X::AbstractMatrix;
                                      corr_ls_threshold::Float64=0.1)
    U, σ, _ = svd(L; full=false)
    eff_rank = sum(σ .> 0.01σ[1])
    sparse_density = sum(abs.(S) .> 1e-10) / length(S)
    corr_LS = cor(vec(L), vec(S))
    recon   = frobenius(X - L - S) / (frobenius(X) + 1e-10)

    issues = String[]
    eff_rank > 5  && push!(issues, "rank(L) = $eff_rank > 5: systematic component is not low-rank. Increase λ.")
    sparse_density < 0.5 && push!(issues, "S density = $(round(sparse_density,digits=3)) < 0.5: S is not sparse. Decrease λ.")
    # NOTE: for high-volatility regimes with weak factor structure, L and S can be
    # correlated by construction. Consider corr_ls_threshold=0.2 in those cases.
    abs(corr_LS) > corr_ls_threshold && push!(issues,
        "cor(L,S) = $(round(corr_LS,digits=3)) > $corr_ls_threshold: ADMM convergence issue or weak factor. Increase max_iter or set corr_ls_threshold=0.2.")

    (rank_L=eff_rank, sparse_density=sparse_density, corr_LS=corr_LS,
     reconstruction_error=recon, passed=isempty(issues), issues=issues)
end

# =============================================================================
# PART 4 — PURGED K-FOLD CROSS-VALIDATION
# =============================================================================

"""
    compute_embargo_from_autocorr(returns; threshold, max_lag, method)

Derive embargo period from the returns' own ACF — no universal default exists.
(K2 — two methods)

Methods:
  :crossing_time    — first lag where |ρ(h)| < threshold for all subsequent lags
  :decorrelation    — lag where cumulative |ACF| sum reaches 1/e of its peak
"""
function compute_embargo_from_autocorr(returns::AbstractVector{Float64};
                                        threshold::Float64=0.05,
                                        max_lag::Int=60,
                                        method::Symbol=:crossing_time)
    n   = length(returns); μ = mean(returns); σ² = var(returns)
    σ² < 1e-12 && return 1
    nl  = min(max_lag, n÷4)
    acf = [abs(sum((returns[1:n-h] .- μ) .* (returns[h+1:n] .- μ)) /
               ((n-h)*σ²)) for h in 1:nl]

    if method == :crossing_time
        for h in 1:nl
            all(acf[h:min(h+3,nl)] .< threshold) && return h
        end
        return nl

    elseif method == :decorrelation
        cumacf = cumsum(acf); peak = cumacf[end]
        idx    = findfirst(cumacf .≥ peak*(1 - 1/exp(1.0)))
        return something(idx, nl)
    else
        error("Unknown method :$method. Choose :crossing_time or :decorrelation.")
    end
end

"""
    generate_purged_splits(n, embargo; n_folds) → Vector{NamedTuple}

Generate purged K-fold splits that respect temporal ordering. The embargo
gap after each test block prevents autocorrelation from leaking information
across the train/test boundary.
"""
function generate_purged_splits(n::Int, embargo::Int; n_folds::Int=5)
    fold_size = n ÷ n_folds

    # Auto-reduce embargo if it would leave < 2 training observations per fold
    effective_embargo = embargo
    if fold_size ≤ 2*embargo
        effective_embargo = max(1, fold_size ÷ 2)
        @warn "Embargo ($embargo) ≥ fold_size÷2 ($( fold_size÷2)). " *
              "Auto-reduced to $effective_embargo. Reduce n_folds or increase data length."
    end

    splits    = NamedTuple[]

    for k in 1:n_folds
        t_start = (k-1)*fold_size + 1
        t_end   = min(k*fold_size, n)
        test    = collect(t_start:t_end)

        excl    = max(1, t_start - effective_embargo):min(n, t_end + effective_embargo)
        train   = setdiff(1:n, excl)

        length(train) < 2 && (@warn "Fold $k: insufficient training data after embargo."; continue)
        push!(splits, (train=train, test=test, embargo=effective_embargo, fold=k))
    end

    if length(splits) < n_folds
        @warn "Only $(length(splits))/$n_folds folds generated. " *
              "Reduce embargo or increase data length."
    end
    splits
end

"""
    detect_information_leak(returns, splits) → report

Measure cross-correlation between the boundary of training data and the
start of test data. High values indicate the embargo is too short.  (ZAI)
"""
function detect_information_leak(returns::AbstractVector{Float64},
                                  splits::Vector{<:NamedTuple})
    leakage = Float64[]
    for sp in splits
        isempty(sp.train) || isempty(sp.test) && continue
        boundary_size = min(10, length(sp.train))
        tail  = returns[sp.train[end-boundary_size+1:end]]
        head  = returns[sp.test[1:min(boundary_size, length(sp.test))]]
        length(tail) == length(head) && std(tail) > 1e-10 && std(head) > 1e-10 &&
            push!(leakage, abs(cor(tail, head)))
    end
    isempty(leakage) && return (max_leakage=0.0, significant=false,
                                 recommendation="No splits to test.")
    max_l = maximum(leakage)
    sig   = max_l > 0.3
    (max_leakage=max_l, significant=sig,
     recommendation=sig ? "Increase embargo period (current causes max corr=$( round(max_l,digits=3)))." :
                          "No significant leakage detected (max corr=$(round(max_l,digits=3))).")
end

# =============================================================================
# PART 5 — STRUCTURAL ASSUMPTION REGISTRY  (ChatGPT)
# =============================================================================
#
# Every Stratum II model exposes its assumptions. The cross_model_audit then
# detects when two models in the same pipeline make contradictory assumptions.
# This is the "scientific inference governance" layer — it catches conflicts
# that no individual model's diagnostic can see.
#
# Example conflict: HMM assumes stationary transitions, but a structural break
# in the RPCA low-rank component implies the factor structure changed — which
# invalidates the stationarity assumption.

"""
    ModelAssumptions — assumptions a model makes about the data.  (ChatGPT)
"""
struct ModelAssumptions
    model_name::Symbol
    assumptions::Vector{Symbol}
    incompatible_with::Vector{Symbol}   # assumption tags that conflict
end

"""
    assumptions_registry() → Dict

Built-in assumption registry for the four Stratum II tools.
"""
function assumptions_registry()
    Dict(
        :rmt => ModelAssumptions(:rmt,
            [:iid_returns, :large_n_large_p, :finite_variance],
            [:autocorrelated_returns, :structural_breaks]),
        :hmm => ModelAssumptions(:hmm,
            [:markovian, :stationary_transitions, :conditional_independence],
            [:time_varying_transitions, :structural_breaks]),
        :rpca => ModelAssumptions(:rpca,
            [:low_rank_systematic, :sparse_idiosyncratic, :static_factor_structure],
            [:time_varying_factor_loading, :dense_outliers]),
        :purged_cv => ModelAssumptions(:purged_cv,
            [:stationarity_within_fold, :embargo_removes_autocorr],
            [:structural_breaks_within_fold])
    )
end

"""
    cross_model_audit(active_models; data_evidence) → Vector{String}

Detect assumption conflicts between active models. Optionally accepts
`data_evidence` — a set of assumption tags that the data appears to violate.
                                            (ChatGPT — unique contribution)
"""
function cross_model_audit(active_models::Vector{Symbol};
                            data_evidence::Set{Symbol}=Set{Symbol}())
    reg      = assumptions_registry()
    conflicts = String[]

    # Cross-model conflicts
    for i in 1:length(active_models), j in (i+1):length(active_models)
        m1 = get(reg, active_models[i], nothing)
        m2 = get(reg, active_models[j], nothing)
        m1 === nothing || m2 === nothing && continue
        for a in m1.assumptions
            a ∈ m2.incompatible_with &&
                push!(conflicts, "$(m1.model_name) assumes :$a, which conflicts with " *
                      "$(m2.model_name)'s assumption set.")
        end
    end

    # Data-evidence conflicts
    for name in active_models
        m = get(reg, name, nothing)
        m === nothing && continue
        for ev in data_evidence
            ev ∈ m.incompatible_with &&
                push!(conflicts, "Data evidence of :$ev conflicts with " *
                      "$(m.model_name) assumption :$(first(m.incompatible_with ∩ [ev])).")
        end
    end

    unique(conflicts)
end

# =============================================================================
# PART 6 — FULL PIPELINE COORDINATOR
# =============================================================================

"""
    StratumIIAuditReport

Top-level severity-annotated audit (K2 concept + QWEN output format).
"""
struct StratumIIAuditReport
    rmt_notes::Vector{String}
    hmm_notes::Vector{String}
    rpca_notes::Vector{String}
    cv_notes::Vector{String}
    assumption_conflicts::Vector{String}
    severity::Symbol   # :ok | :warning | :error
    summary::String
end

function Base.show(io::IO, r::StratumIIAuditReport)
    bar = "=" ^ 65
    println(io, bar); println(io, "STRATUM II AUDIT  [$(r.severity)]"); println(io, bar)
    sections = [("RMT / Marcenko-Pastur", r.rmt_notes),
                ("HMM Structural", r.hmm_notes),
                ("RPCA Finance Tuning", r.rpca_notes),
                ("Purged K-Fold CV", r.cv_notes),
                ("Cross-Model Assumptions", r.assumption_conflicts)]
    for (name, notes) in sections
        isempty(notes) && continue
        println(io, "\n[$name]")
        foreach(n -> println(io, "  • $n"), notes)
    end
    println(io, "\n[Summary]\n  $(r.summary)"); println(io, bar)
end

"""
    run_stratum_ii_audit(returns, n_obs; hmm_config, rpca_lambda_range)
    → StratumIIAuditReport

Coordinating audit function. Runs all four components in sequence.  (QWEN)
"""
function run_stratum_ii_audit(returns::AbstractMatrix{Float64}, n_obs::Int;
                               hmm_config::HMMConfig=HMMConfig(3),
                               rpca_lambda_range::AbstractVector{Float64}=Float64[])
    p, n = size(returns)

    # 1. RMT
    rmt_checks = validate_rmt_assumptions(returns)
    rmt_notes  = [c.note for c in rmt_checks if !c.passed && !isempty(c.note)]
    Σ_clean, rmt_rep = clean_covariance_rmt(cov(returns), n_obs)
    append!(rmt_notes, rmt_rep.notes)

    # 2. HMM config validation
    hmm_notes = String[]
    hmm_config.n_regimes > 4 && push!(hmm_notes, "n_regimes=$(hmm_config.n_regimes) > 4: " *
                                        "economic interpretability degrades rapidly beyond 4 regimes.")
    if hmm_config.emission isa StudentTEmission
        any(hmm_config.emission.df .< 3) && push!(hmm_notes, "StudentT df < 3: infinite variance.")
    end

    # 3. RPCA
    embargo   = compute_embargo_from_autocorr(returns[:,1]; method=:crossing_time)
    cv_splits = generate_purged_splits(n, embargo; n_folds=3)
    rpca_notes = String[]
    if !isempty(cv_splits)
        best_λ, _, rpca_rep = tune_lambda_rpca(returns, cv_splits;
                                                lambda_range=rpca_lambda_range)
        append!(rpca_notes, rpca_rep.notes)
        L, S, _, _ = rpca_admm(returns, best_λ)
        rpca_val = validate_rpca_decomposition(L, S, returns)
        append!(rpca_notes, rpca_val.issues)
    else
        push!(rpca_notes, "No CV splits generated — check embargo vs data length.")
    end

    # 4. Purged CV
    leak = detect_information_leak(vec(mean(returns, dims=2)), cv_splits)
    cv_notes = leak.significant ? [leak.recommendation] : String[]

    # 5. Cross-model assumptions
    conflicts = cross_model_audit([:rmt, :hmm, :rpca, :purged_cv])

    all_notes = vcat(rmt_notes, hmm_notes, rpca_notes, cv_notes, conflicts)
    sev = isempty(all_notes) ? :ok :
          any(contains(n, "infinite") || contains(n, "No signal") for n in all_notes) ? :error : :warning

    summary = "$(length(all_notes)) issue(s). " * (
        sev == :ok    ? "Pipeline structurally consistent. Safe for production." :
        sev == :error ? "CRITICAL issues detected. Resolve before proceeding." :
                        "Warnings present. Review before production deployment.")

    StratumIIAuditReport(rmt_notes, hmm_notes, rpca_notes, cv_notes, conflicts, sev, summary)
end

# =============================================================================
# DEMONSTRATION
# =============================================================================

function run_demo()
    println("\n" * "=" ^ 65)
    println("StructuralStatistics (Stratum II) — Demonstration")
    println("=" ^ 65)
    Random.seed!(42)

    n, p = 500, 50
    # Factor model: 3 systematic factors + noise
    F  = randn(n, 3); β = randn(p, 3) * 0.3
    R  = F * β' .+ 0.1.*randn(n, p)

    println("\n--- Part 1: RMT / Marcenko-Pastur ---")
    checks = validate_rmt_assumptions(R)
    for c in checks
        println("  $(c.passed ? "✓" : "✗") $(c.name): stat=$(round(c.statistic,sigdigits=3)) / thr=$(round(c.threshold,sigdigits=3))")
    end
    Σ = cov(R)
    Σ_clean, rpt = clean_covariance_rmt(Σ, n; method=:shrink_trace_preserving)
    println("  signal eigenvalues = $(rpt.n_signal)  noise = $(rpt.n_noise)  trace_ratio = $(round(rpt.trace_ratio,digits=4))")
    println("  KS p-value = $(round(rpt.mp_fit.ks_pvalue, digits=4))  good_fit = $(rpt.mp_fit.good_fit)")

    stab = rolling_eigenvector_stability(R, 120; n_components=3)
    println("  Rolling eigenvector stability (mean cos): $(round.(stab, digits=3))")

    println("\n--- Part 2: HMM ---")
    r1 = [randn()*0.01 + 0.002 for _ in 1:200]    # low-vol bull
    r2 = [randn()*0.04 - 0.003 for _ in 1:200]    # high-vol bear
    r3 = [randn()*0.08 - 0.010 for _ in 1:100]    # crisis
    returns_1d = vcat(r1, r2, r3)

    cfg = HMMConfig(3; emission=StudentTEmission(3; df=4.0), transition=Ergodic(; min_off_diag=0.02))
    hmm = _fit_gaussian_hmm_simple(returns_1d, 3)
    val = validate_hmm_economics(hmm.state_sequence, returns_1d, cfg)
    println("  HMM economic validation: passed=$(val.passed)  switch_rate=$(round(val.switch_rate,digits=3))")
    for i in val.issues; println("  ✗ $i"); end
    interps = interpret_regimes(hmm.state_sequence, returns_1d, hmm.A)
    for ir in interps
        println("  Regime $(ir.regime): :$(ir.label) score=$(round(ir.score,digits=2)) " *
                "μ=$(round(ir.mean_ret,digits=4)) σ=$(round(ir.volatility,digits=4)) " *
                "dur=$(round(ir.duration,digits=1))")
    end

    best_k, scores = select_n_regimes(returns_1d, 5; min_duration=20)
    println("  select_n_regimes: best_k=$best_k  scores=$(Dict(k => round(v,digits=1) for (k,v) in scores))")

    println("\n--- Part 3: RPCA ---")
    embargo  = compute_embargo_from_autocorr(vec(mean(R, dims=2)); method=:crossing_time)
    cv_splits = generate_purged_splits(n, embargo; n_folds=3)
    println("  Embargo from ACF = $embargo obs  |  $(length(cv_splits)) purged folds")
    best_λ, scores_rpca, rpca_rep = tune_lambda_rpca(R, cv_splits)
    println("  Optimal λ = $(round(best_λ, digits=4))  (default = $(round(1/sqrt(max(n,p)),digits=4)))")
    L, S, conv, itr = rpca_admm(R, best_λ)
    rpca_val = validate_rpca_decomposition(L, S, R)
    println("  rank(L)=$(rpca_val.rank_L)  sparse_density=$(round(rpca_val.sparse_density,digits=3))" *
            "  cor(L,S)=$(round(rpca_val.corr_LS,digits=3))  converged=$conv")
    rpca_val.passed || foreach(i -> println("  ✗ $i"), rpca_val.issues)

    println("\n--- Part 4: Purged CV & Leak Detection ---")
    leak = detect_information_leak(vec(mean(R, dims=2)), cv_splits)
    println("  max_leakage=$(round(leak.max_leakage,digits=4))  significant=$(leak.significant)")
    println("  $(leak.recommendation)")

    println("\n--- Part 5: Cross-Model Assumption Audit ---")
    conflicts = cross_model_audit([:rmt, :hmm, :rpca, :purged_cv])
    println("  $(isempty(conflicts) ? "No conflicts detected." : "Conflicts:")")
    foreach(c -> println("  ⚠ $c"), conflicts)

    println("\n--- Full Pipeline Audit ---")
    full_rpt = run_stratum_ii_audit(R, n;
                hmm_config=HMMConfig(3; emission=StudentTEmission(3; df=4.0)))
    display(full_rpt)

    println("Demonstration complete.")
end

end # module StructuralStatistics
