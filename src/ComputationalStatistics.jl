# =============================================================================
# ComputationalStatistics.jl  — Stratum I
# Computational Statistics: validated algorithmic implementations of
# PCA, GARCH(1,1), VAR(p), and t-Copula.
#
# Core principle: "Stratum I answers 'Can the algorithm run?' not
# 'Should the algorithm be trusted?' Libraries give estimators.
# This layer gives validation wrappers that test core assumptions
# before trusting output." — ChatGPT
#
# Architecture: validate_before_fit → fit → validate_after_fit → output
# Every estimator runs pre-checks, enforces constraints during optimisation,
# then audits the output before passing to Stratum II.
#
# Cherry-pick attribution:
#   Special functions (self-contained)    → K2
#   Parallel analysis selection           → K2 (unique; not in any other model)
#   Scree elbow via log-curvature         → K2
#   GeometryContext linking to Stratum III → ZAI
#   Projected-gradient GARCH              → K2
#   Half-life of volatility shocks        → ZAI (unique)
#   Itô/Stratonovich convention flag      → ZAI
#   Ljung-Box via chi2_sf                 → K2
#   VAR via QR decomposition              → ZAI
#   AIC/BIC/HQ lag table                  → K2
#   Granger causality exact p-values      → K2
#   Companion matrix IRFs                 → K2
#   Curse of dimensionality check         → ZAI
#   Mid-rank pseudo-observations          → QWEN
#   Kendall τ → ρ conversion              → K2
#   Profile-likelihood ν estimation       → K2
#   t-Copula exact sampling (Z/√W)        → K2
#   Tail dependence formula               → K2/ZAI
#   Marginal/joint contradiction check    → ZAI
#   run_stratum_i_audit structure         → QWEN
#   Python→Julia package mapping (comments) → Le Chat
#
# Dependencies: LinearAlgebra, Statistics, Random (stdlib only)
# Replaces: sklearn.PCA, arch, statsmodels.VAR, copulae (see table below)
#
# Python package    │ Julia equivalent (production)   │ This file
# ──────────────────┼─────────────────────────────────┼────────────────────
# sklearn.PCA       │ MultivariateStats.jl            │ fit_pca
# arch (GARCH)      │ ARCHModels.jl                   │ fit_garch
# statsmodels.VAR   │ VARModels.jl                    │ fit_var
# copulae           │ Copulas.jl                      │ fit_tcopula
#
# Freeze warning: financial libraries change default assumptions between
# releases. Lock package versions in Project.toml. This module is
# a self-contained fallback that never changes defaults silently.
# =============================================================================

module ComputationalStatistics

using LinearAlgebra, Statistics, Random

# =============================================================================
# PART 0 — SELF-CONTAINED SPECIAL FUNCTIONS  (K2)
#
# No SpecialFunctions.jl or Distributions.jl required. Needed for:
#   - student_t_cdf / _quantile: copula CDF transforms, Granger p-values
#   - regularized_beta:          t-CDF construction
#   - chi2_sf:                   Ljung-Box residual test
#   - lanczos_loggamma:          base for all of the above
# =============================================================================

"""Lanczos approximation to log-Gamma. 15-digit accuracy."""
function _loggamma(z::Float64)
    z < 0.5 && return log(π) - log(abs(sin(π*z))) - _loggamma(1-z)
    z -= 1
    g  = 7; c = (0.99999999999980993, 676.5203681218851, -1259.1392167224028,
                  771.32342877765313, -176.61502916214059, 12.507343278686905,
                  -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7)
    x  = c[1]; for i in 2:9; x += c[i]/(z+i-1); end
    0.5*log(2π) + (z+0.5)*log(z+g+0.5) - (z+g+0.5) + log(x)
end

"""Regularized incomplete beta I_x(a,b) via continued fraction + series."""
function _betai(x::Float64, a::Float64, b::Float64)
    (x < 0 || x > 1) && error("x=$x not in [0,1]")
    x == 0 && return 0.0; x == 1 && return 1.0
    lbeta = _loggamma(a) + _loggamma(b) - _loggamma(a+b)
    if x < (a+1)/(a+b+2)
        return exp(a*log(x) + b*log1p(-x) - lbeta) * _betacf(x, a, b) / a
    else
        return 1.0 - exp(b*log1p(-x) + a*log(x) - lbeta) * _betacf(1-x, b, a) / b
    end
end

function _betacf(x::Float64, a::Float64, b::Float64)
    MAXITER = 200; EPS = 3e-7
    c = 1.0; d = 1.0 - (a+b)*x/(a+1); abs(d) < 1e-30 && (d = 1e-30); d = 1/d; h = d
    for m in 1:MAXITER
        m2 = 2m
        aa = m*(b-m)*x/((a+m2-1)*(a+m2))
        d = 1 + aa*d; abs(d) < 1e-30 && (d=1e-30); c = 1 + aa/c; abs(c)<1e-30&&(c=1e-30)
        d = 1/d; h *= d*c
        aa = -(a+m)*(a+b+m)*x/((a+m2)*(a+m2+1))
        d = 1 + aa*d; abs(d) < 1e-30 && (d=1e-30); c = 1 + aa/c; abs(c)<1e-30&&(c=1e-30)
        d = 1/d; δ = d*c; h *= δ
        abs(δ-1) < EPS && break
    end
    h
end

"""Student-t CDF P(T ≤ t) for ν degrees of freedom."""
function _t_cdf(t::Float64, ν::Float64)
    x = ν/(ν + t^2)
    p = 0.5 * _betai(x, ν/2, 0.5)
    t ≥ 0 ? 1-p : p
end

"""Student-t inverse CDF via bisection with adaptive bracketing for small ν."""
function _t_quantile(p::Float64, ν::Float64)
    (p ≤ 0 || p ≥ 1) && error("p=$p must be in (0,1)")
    # For small ν (heavy tails), quantiles can exceed ±40.
    # The t(2) distribution has tails proportional to x^(-3), so
    # P(T > 40) ≈ 0 for ν≥4 but non-trivial for ν=2. Use ±200 to be safe.
    lo = ν < 4 ? -200.0 : -40.0
    hi = ν < 4 ?  200.0 :  40.0
    for _ in 1:80    # 80 bisection steps → ~24 digits of precision
        mid = 0.5*(lo+hi)
        _t_cdf(mid, ν) < p ? (lo = mid) : (hi = mid)
    end
    0.5*(lo+hi)
end

"""chi-squared survival function P(X > x) for df degrees of freedom."""
function _chi2_sf(x::Float64, df::Int)
    x ≤ 0 && return 1.0
    # Wilson-Hilferty approximation (accurate to 4 sig figs)
    if df > 30
        z = ((x/df)^(1/3) - (1 - 2/(9df))) / sqrt(2/(9df))
        return 0.5*erfc(z/sqrt(2))
    end
    # Regularized upper incomplete gamma via series
    a = df/2.0; xi = x/2.0
    t = s = 1.0
    for n in 1:200
        t *= xi/(a+n); s += t
        abs(t) < abs(s)*1e-12 && break
    end
    max(0.0, min(1.0, 1.0 - s*exp(-xi + a*log(xi) - _loggamma(a))))
end

# =============================================================================
# PART 0b — VALIDATION FRAMEWORK
# =============================================================================

"""
    ValidationReport

Pre- and post-fit validation summary. Every estimator returns one.
The `blocking` flag prevents downstream use when critical assumptions fail.
"""
struct ValidationReport
    tool::Symbol
    pre_checks::Vector{String}    # issues found before fitting
    post_checks::Vector{String}   # issues found after fitting
    blocking::Bool                # if true, do NOT use this output
    notes::Vector{String}         # informational (not blocking)
end

function Base.show(io::IO, r::ValidationReport)
    tag = r.blocking ? "BLOCKED" : (isempty(r.pre_checks) && isempty(r.post_checks) ? "PASS" : "WARN")
    println(io, "ValidationReport [:$(r.tool)]  [$tag]")
    for c in r.pre_checks;  println(io, "  [pre]  $c"); end
    for c in r.post_checks; println(io, "  [post] $c"); end
    for n in r.notes;       println(io, "  [note] $n"); end
end

"""
    validate_before_fit(data; tool) → (ok, issues)

Pre-fit data quality gate — run this BEFORE calling any estimator.

Implements the required validation pattern from the architecture specification:
    assert p/n ratio        (tool=:pca)
    assert not NaN
    assert all finite
    assert no zero-variance columns

Returns `(ok::Bool, issues::Vector{String})`. When `ok=false`, do not call `fit_*`.
Mirrors the pseudocode:
    validate_before_use(model, data):
        if model == PCA: assert data.shape[1] / data.shape[0] < 0.5
        assert not np.isnan(data).any()
        assert np.isfinite(data).all()
        return model.fit(data)
"""
function validate_before_fit(data::AbstractMatrix{Float64}; tool::Symbol=:generic)
    n, p = size(data)
    issues = String[]

    any(isnan.(data))  && push!(issues, "Data contains NaN values.")
    any(isinf.(data))  && push!(issues, "Data contains Inf values.")
    any(std(data, dims=1) .< 1e-12) && push!(issues, "One or more columns have zero variance.")

    if tool == :pca
        p/n > 0.5 && push!(issues, "p/n = $(round(p/n,digits=3)) > 0.5: PCA is unreliable in this regime. Apply RMT cleaning (Stratum II) first.")
    elseif tool == :var
        # Checked more carefully inside fit_var
    end

    (isempty(issues), issues)
end

# =============================================================================
# PART 1 — PCA
# =============================================================================

"""
    GeometryContext — which manifold the data lives on.  (ZAI)

EuclideanPCA: standard Euclidean PCA (scores feed into flat-space operations)
RiemannianSPDPCA: output feeds into Stratum III manifold operations — warn
  that Euclidean truncation of a covariance matrix does not preserve the SPD
  constraint and that parallel transport is needed before handing to
  AffineInvariant or BuresWasserstein modules.
"""
abstract type GeometryContext end
struct EuclideanPCA    <: GeometryContext end
struct RiemannianSPDPCA <: GeometryContext end

"""
    PCAConfig

Selection method options:
  :kaiser      — eigenvalue > mean(eigenvalues); or > 1 for standardized data
  :scree       — elbow in log-scree curve via maximum second derivative
  :cumulative  — retain until cumulative explained variance ≥ threshold
  :parallel    — parallel analysis: keep components whose eigenvalue exceeds the
                 95th percentile of eigenvalues from n_parallel random datasets
                 of the same dimensions. (K2 — unique; not in sklearn)
"""
struct PCAConfig
    standardize::Bool
    selection_method::Symbol
    cumvar_threshold::Float64
    n_parallel::Int           # for :parallel analysis
    mp_upper::Union{Nothing,Float64}  # MP bound from Stratum II (optional)
    geometry::GeometryContext
end

PCAConfig(; standardize::Bool=true, selection_method::Symbol=:cumulative,
            cumvar_threshold::Float64=0.90, n_parallel::Int=100,
            mp_upper::Union{Nothing,Float64}=nothing,
            geometry::GeometryContext=EuclideanPCA()) =
    PCAConfig(standardize, selection_method, cumvar_threshold, n_parallel, mp_upper, geometry)

struct PCAResult
    loadings::Matrix{Float64}         # p × k eigenvectors
    scores::Matrix{Float64}           # n × k projections
    eigenvalues::Vector{Float64}      # sorted descending
    explained_var::Vector{Float64}    # fraction per component
    center::Vector{Float64}
    scale::Vector{Float64}
    n_components::Int
    config::PCAConfig
    validation::ValidationReport
end

function transform_pca(r::PCAResult, X::AbstractMatrix)
    n, p = size(X)
    Xc = (X .- r.center') ./ r.scale'
    Xc * r.loadings[:, 1:r.n_components]
end

function inverse_transform_pca(r::PCAResult, Z::AbstractMatrix)
    (Z * r.loadings[:, 1:r.n_components]') .* r.scale' .+ r.center'
end

"""
    fit_pca(X, config) → PCAResult

SVD-based PCA with four component selection methods.
Pre-checks: NaN, Inf, p/n ratio, zero-variance columns.
Post-checks: reconstruction error, orthonormality, single-component dominance.
"""
function fit_pca(X::AbstractMatrix{Float64}, config::PCAConfig=PCAConfig())
    n, p    = size(X)
    ok, pre = validate_before_fit(X; tool=:pca)
    notes   = String[]

    # Standardise
    μ = vec(mean(X, dims=1))
    σ = vec(std(X, dims=1, corrected=true))
    σ[σ .< 1e-10] .= 1.0
    Xs = config.standardize ? (X .- μ') ./ σ' : X .- μ'

    # SVD (numerically superior to eigendecomp of cov for small n)
    U, sv, Vt = svd(Xs; full=false)
    sv  = max.(sv, 0.0)
    ev  = sv.^2 ./ (n-1)         # eigenvalues of cov matrix
    exp_var = sv.^2 ./ sum(sv.^2)

    # Component selection
    k = _select_n_components(ev, exp_var, Xs, config, notes)

    # MP bound check from Stratum II
    post = String[]
    if config.mp_upper !== nothing
        n_noise = count(ev .≤ config.mp_upper)
        noise_in_top_k = count(ev[1:k] .≤ config.mp_upper)
        noise_in_top_k > 0 && push!(post, "RMT: $noise_in_top_k of top-$k components within MP noise bulk (λ_max=$(round(config.mp_upper,digits=4))). Apply Stratum II RMT cleaning first.")
    end

    # Geometry warning
    if config.geometry isa RiemannianSPDPCA
        push!(notes, "RiemannianSPDPCA: Euclidean truncation of a covariance does not preserve SPD. " *
                     "Feed output into GeometricCoordinationLayer parallel transport before using with AffineInvariant/BuresWasserstein modules.")
    end

    # Post-fit validation
    loadings   = Vt'[:, 1:k]
    scores_mat = U[:, 1:k] .* sv[1:k]'
    Xr         = scores_mat * loadings' .* σ' .+ μ'
    recon_err  = norm(X - Xr, 2) / (norm(X, 2) + 1e-10)
    recon_err > 0.5 && push!(post, "Reconstruction error = $(round(recon_err,digits=3)) > 0.5: retained components explain little variance.")

    ortho_err = norm(loadings' * loadings - I(k), 2)
    ortho_err > 1e-8 && push!(post, "Loadings not orthonormal (err=$(round(ortho_err,sigdigits=2))): numerical issue in SVD.")

    exp_var[1] > 0.9 && push!(notes, "Component 1 explains $(round(exp_var[1]*100,digits=1))% of variance. Check for a dominant scaling factor.")

    blocking = any(contains.(pre, "NaN") .| contains.(pre, "Inf"))
    vr = ValidationReport(:pca, pre, post, blocking, notes)

    PCAResult(loadings, scores_mat, ev, exp_var, μ,
              config.standardize ? σ : ones(p), k, config, vr)
end

function _select_n_components(ev::Vector, exp_var::Vector, Xs::Matrix,
                               config::PCAConfig, notes::Vector{String})
    p = length(ev)

    if config.selection_method == :kaiser
        threshold = config.standardize ? 1.0 : mean(ev)
        k = max(1, count(ev .> threshold))
        push!(notes, "Kaiser: retained $k components (eigenvalue > $( round(threshold,digits=3))).")
        return k

    elseif config.selection_method == :scree
        # Elbow via maximum curvature of log-scree (K2)
        log_ev = log.(max.(ev, 1e-10))
        k = 1
        if length(log_ev) ≥ 3
            second_deriv = diff(diff(log_ev))
            k = argmax(second_deriv) + 1
        end
        push!(notes, "Scree elbow detected at component $k.")
        return max(1, k)

    elseif config.selection_method == :cumulative
        k = findfirst(cumsum(exp_var) .≥ config.cumvar_threshold)
        k = something(k, p)
        push!(notes, "Cumulative variance threshold $(config.cumvar_threshold): retained $k components.")
        return k

    elseif config.selection_method == :parallel
        # Parallel analysis: compare empirical eigenvalues to random-data 95th pct.
        # The only defensible way to decide how many factors to retain.  (K2)
        n, _ = size(Xs)
        parallel_ev = zeros(p, config.n_parallel)
        for sim in 1:config.n_parallel
            Xr      = randn(n, p)
            Xr    ./= std(Xr, dims=1)
            _, sv_r, _ = svd(Xr; full=false)
            parallel_ev[:, sim] = sv_r.^2 ./ (n-1)
        end
        thresh_95 = vec(mapslices(x -> quantile(x, 0.95), parallel_ev, dims=2))
        k = max(1, count(ev .> thresh_95))
        push!(notes, "Parallel analysis: retained $k components (eigenvalue > 95th pct of random).")
        return k
    else
        error("Unknown selection_method :$(config.selection_method). Choose :kaiser, :scree, :cumulative, :parallel.")
    end
end

# =============================================================================
# PART 2 — GARCH(1,1)
# =============================================================================

"""
    GARCHConfig

  convention — :ito (standard QMLE) or :stratonovich (manifold-valued processes).
               If :stratonovich, the estimated σ² is biased for Stratonovich SDEs
               and must be corrected by Stratum III before use in manifold samplers.
               (ZAI — unique cross-strata annotation)
"""
struct GARCHConfig
    max_iter::Int
    lr0::Float64           # initial learning rate
    lr_decay::Float64      # learning rate decay per epoch
    lb_lags::Int           # Ljung-Box test lag count
    convention::Symbol     # :ito or :stratonovich
    var_mismatch_threshold::Float64  # warn if |σ²_model - σ²_sample|/σ²_sample > this
end

GARCHConfig(; max_iter::Int=2000, lr0::Float64=1e-4, lr_decay::Float64=0.999,
              lb_lags::Int=10, convention::Symbol=:ito,
              var_mismatch_threshold::Float64=0.3) =
    GARCHConfig(max_iter, lr0, lr_decay, lb_lags, convention, var_mismatch_threshold)

struct GARCHResult
    ω::Float64; α::Float64; β::Float64
    sigma2::Vector{Float64}   # conditional variances
    std_resid::Vector{Float64}
    loglik::Float64; aic::Float64; bic::Float64
    config::GARCHConfig
    validation::ValidationReport
end

"""
    _garch_loglik(ω, α, β, r) → (ll, σ²)
Gaussian QMLE log-likelihood and conditional variance series.
"""
function _garch_loglik(ω::Float64, α::Float64, β::Float64, r::AbstractVector{Float64})
    T  = length(r)
    σ² = fill(ω/(1-α-β+1e-10), T)   # warm-start at unconditional variance
    ll = 0.0
    for t in 2:T
        σ²[t] = ω + α*r[t-1]^2 + β*σ²[t-1]
        σ²[t] = max(σ²[t], 1e-12)
        ll   += -0.5*(log(2π) + log(σ²[t]) + r[t]^2/σ²[t])
    end
    ll, σ²
end

"""
    _numerical_grad(f, θ; h) → gradient vector
Adaptive finite-difference gradient.
"""
function _numerical_grad(f::Function, θ::Vector{Float64}; h::Float64=1e-6)
    g = similar(θ)
    for i in eachindex(θ)
        θp = copy(θ); θp[i] += h
        θm = copy(θ); θm[i] -= h
        g[i] = (f(θp) - f(θm)) / (2h)
    end
    g
end

"""
    fit_garch(r, config) → GARCHResult

Projected gradient descent GARCH(1,1) without Optim.jl.  (K2)
Constraints enforced at every step: ω>0, α≥0, β≥0, α+β<1.
Warm-started from method-of-moments.
"""
function fit_garch(r::AbstractVector{Float64}, config::GARCHConfig=GARCHConfig())
    pre   = String[]
    any(isnan.(r)) && push!(pre, "Returns contain NaN.")
    any(isinf.(r)) && push!(pre, "Returns contain Inf.")
    length(r) < 50 && push!(pre, "n=$(length(r)) < 50: GARCH estimates unreliable.")

    rc    = r .- mean(r)          # demean
    T     = length(rc)
    σ²_s  = var(rc, corrected=true)

    # Method-of-moments warm start
    ω₀, α₀, β₀ = σ²_s*0.05, 0.05, 0.90
    θ = [ω₀, α₀, β₀]

    obj(θ_) = begin
        ω_, α_, β_ = θ_
        (ω_ ≤ 0 || α_ < 0 || β_ < 0 || α_+β_ ≥ 1) && return Inf
        -_garch_loglik(ω_, α_, β_, rc)[1]
    end

    lr = config.lr0
    for iter in 1:config.max_iter
        g  = _numerical_grad(obj, θ)
        θ .-= lr .* g
        # Project onto constraint set
        θ[1] = max(θ[1], 1e-8)
        θ[2] = max(θ[2], 0.0)
        θ[3] = max(θ[3], 0.0)
        s = θ[2] + θ[3]
        if s ≥ 0.9999
            θ[2] *= 0.9999/s; θ[3] *= 0.9999/s
        end
        lr *= config.lr_decay
    end

    ω, α, β    = θ
    ll, σ²     = _garch_loglik(ω, α, β, rc)
    std_r      = rc ./ sqrt.(σ²)
    aic = -2ll + 6; bic = -2ll + 3*log(T)

    # --- Validation ---
    post  = String[]
    notes = String[]
    α+β ≥ 1    && push!(post, "CRITICAL: α+β=$(round(α+β,digits=5)) ≥ 1. Model is non-stationary; forecasts will diverge.")
    α+β > 0.995 && push!(post, "Near-IGARCH: α+β=$(round(α+β,digits=4)) > 0.995. Shocks are near-permanent; consider IGARCH.")

    # Half-life of variance shocks: H = log(0.5)/log(α+β)  (ZAI)
    hl = α+β < 1 ? log(0.5)/log(α+β+1e-10) : Inf
    push!(notes, "Half-life of variance shock: $(round(hl,digits=1)) periods. " *
                 (hl > 100 ? "Very persistent — longer than typical trading horizons." : ""))

    # Ljung-Box on squared standardised residuals (K2)
    lb_stat = _ljung_box(std_r.^2 .- 1, config.lb_lags, 3)
    lb_p    = _chi2_sf(lb_stat, config.lb_lags - 3)
    lb_p < 0.05 && push!(post, "Ljung-Box Q($(config.lb_lags))=$(round(lb_stat,digits=2)) p=$(round(lb_p,digits=4)): remaining ARCH effects in residuals.")

    # Unconditional variance consistency (configurable threshold)
    σ²_unc = ω/(1-α-β+1e-10)
    abs(σ²_unc - σ²_s)/σ²_s > config.var_mismatch_threshold && push!(notes,
        "Unconditional variance mismatch: model=$(round(σ²_unc,sigdigits=3)) " *
        "sample=$(round(σ²_s,sigdigits=3)) (threshold=$(config.var_mismatch_threshold)).")

    # Itô/Stratonovich convention  (ZAI)
    config.convention == :stratonovich &&
        push!(notes, "Convention=:stratonovich: QMLE σ² is biased for Stratonovich SDEs. " *
                     "Apply Itô-Stratonovich correction (Stratum III) before feeding into manifold samplers.")

    blocking = !isempty(pre) || (α+β ≥ 1)
    vr = ValidationReport(:garch, pre, post, blocking, notes)
    GARCHResult(ω, α, β, σ², std_r, ll, aic, bic, config, vr)
end

function _ljung_box(x::AbstractVector, lags::Int, n_params::Int)
    n   = length(x)
    μx  = mean(x); γ0 = mean((x .- μx).^2)
    stat = 0.0
    for h in 1:lags
        γh = mean((x[1:n-h] .- μx) .* (x[h+1:n] .- μx))
        stat += (γh/γ0)^2 / (n-h)
    end
    n*(n+2)*stat
end

"""
    forecast_garch(result, h) → Vector{Float64}

Analytic h-step variance forecasts converging to unconditional variance.  (K2)
"""
function forecast_garch(result::GARCHResult, h::Int)
    σ²_unc = result.ω / (1 - result.α - result.β + 1e-10)
    σ²_T   = result.sigma2[end]
    pers   = result.α + result.β
    [(σ²_unc + (σ²_T - σ²_unc)*pers^t) for t in 1:h]
end

"""
    fit_ewma(r; λ) → (sigma2, validation)

Exponentially Weighted Moving Average volatility: σ²_t = λ σ²_{t-1} + (1-λ) r²_{t-1}.

EWMA is the robust fallback when GARCH(1,1) fails to converge — common in:
  - Crypto (regime changes cause projected-gradient oscillation)
  - Commodities (seasonal volatility violates GARCH stationarity)
  - Very short series (T < 100: GARCH has 3 parameters, EWMA has 0)

λ = 0.94 is the RiskMetrics daily default. Use λ = 0.97 for monthly data.
No optimisation required — EWMA is always well-defined and stationary by construction.
"""
function fit_ewma(r::AbstractVector{Float64}; λ::Float64=0.94)
    T   = length(r); rc = r .- mean(r)
    σ²  = fill(var(rc), T)
    for t in 2:T; σ²[t] = λ*σ²[t-1] + (1-λ)*rc[t-1]^2; end
    std_r  = rc ./ sqrt.(σ²)
    post   = String[]
    notes  = String[]
    λ < 0.8  && push!(notes, "λ=$λ < 0.8: EWMA decays fast. Suitable only for intraday data.")
    λ > 0.99 && push!(notes, "λ=$λ > 0.99: EWMA decays very slowly. Consider GARCH for proper estimation.")
    lb_stat = _ljung_box(std_r.^2 .- 1, 10, 0)
    lb_p    = _chi2_sf(lb_stat, 10)
    lb_p < 0.05 && push!(post, "Ljung-Box p=$(round(lb_p,digits=4)): ARCH effects remain. EWMA underfits; try fit_garch.")
    vr = ValidationReport(:ewma, String[], post, false, notes)
    (sigma2=σ², std_resid=std_r, lambda=λ, validation=vr)
end


# =============================================================================

struct VARConfig
    p::Int           # lag order (set to 0 for auto-selection)
    maxlag::Int      # max lag for auto-selection
    ic::Symbol       # :aic, :bic, or :hq
    method::Symbol   # :ols (default) or :ridge (L2 penalty for p*k² > T)
    ridge_lambda::Float64  # ridge penalty (only used when method=:ridge)
end

VARConfig(; p::Int=0, maxlag::Int=8, ic::Symbol=:bic,
            method::Symbol=:ols, ridge_lambda::Float64=1e-3) =
    VARConfig(p, maxlag, ic, method, ridge_lambda)

struct VARResult
    B::Matrix{Float64}            # coefficient matrix (n_regressors × k)
    A::Vector{Matrix{Float64}}    # lag coefficient matrices A[1]..A[p]
    intercept::Vector{Float64}
    Σ::Matrix{Float64}            # residual covariance
    companion::Matrix{Float64}    # companion matrix for stability
    residuals::Matrix{Float64}
    p::Int
    ic_table::Dict{Int,NamedTuple{(:aic,:bic,:hq),Tuple{Float64,Float64,Float64}}}
    config::VARConfig
    validation::ValidationReport
end

function _build_var_regressor(Y::AbstractMatrix, p::Int)
    T, k = size(Y)
    Teff = T - p
    Z    = ones(Teff, k*p + 1)   # [Y_{t-1},...,Y_{t-p}, 1]
    for lag in 1:p
        Z[:, (lag-1)*k+1:lag*k] = Y[p-lag+1:T-lag, :]
    end
    Z, Y[p+1:end, :]
end

"""
    fit_var(Y, config) → VARResult

Multivariate OLS via QR decomposition (numerically stable).  (ZAI)
Includes AIC/BIC/HQ lag table, companion matrix stability check,
curse-of-dimensionality pre-check.  (K2 + ZAI)
"""
function fit_var(Y::AbstractMatrix{Float64}, config::VARConfig=VARConfig())
    T, k = size(Y)
    pre  = String[]
    any(isnan.(Y)) && push!(pre, "Data contains NaN.")

    # Curse of dimensionality check  (ZAI)
    p_test = config.p == 0 ? config.maxlag : config.p
    n_par  = p_test*k^2 + k
    n_par > T && push!(pre, "Estimating $n_par parameters with $T obs (VAR($p_test), k=$k). " *
                             "OLS is degenerate. Apply PCA (Stratum I) or Ridge first.")

    # Lag selection via IC table
    ic_table = Dict{Int,NamedTuple{(:aic,:bic,:hq),Tuple{Float64,Float64,Float64}}}()
    if config.p == 0
        for lag in 1:config.maxlag
            lag*k^2 + k ≥ T-lag && continue
            Z, Yout = _build_var_regressor(Y, lag)
            Teff = size(Yout, 1)
            Q, R = qr(Z); B_lag = R \ (Q' * Yout)
            E_lag = Yout - Z*B_lag
            Σ_lag = E_lag'E_lag ./ Teff
            !isposdef(Σ_lag) && continue
            ll = -0.5*Teff*(logdet(Σ_lag) + k*log(2π) + k)
            np = lag*k^2 + k
            ic_table[lag] = (aic=-2ll+2np, bic=-2ll+np*log(Teff),
                             hq=-2ll+2np*log(log(Teff)))
        end
        p = isempty(ic_table) ? 1 :
            argmin(Dict(lag => getfield(ic, config.ic) for (lag,ic) in ic_table))
    else
        p = config.p
    end

    Z, Yout = _build_var_regressor(Y, p)
    Teff    = size(Yout, 1)

    # Solve via QR (:ols) or Ridge (:ridge) based on config
    if config.method == :ridge
        # L2-regularised: (Z'Z + λI)B = Z'Y — avoids singularity when n_par ≈ T
        ZtZ = Z'Z + config.ridge_lambda * I(size(Z,2))
        B   = ZtZ \ (Z' * Yout)
    else
        Q, R_ = qr(Z); B = R_ \ (Q' * Yout)
    end
    E  = Yout - Z*B
    Σ  = Symmetric(E'E ./ Teff)

    # Extract lag matrices A[1]..A[p] and intercept
    intercept = vec(B[end, :])
    A = [B[(lag-1)*k+1:lag*k, :]' for lag in 1:p]

    # Companion matrix (pk × pk)  (K2)
    companion = zeros(p*k, p*k)
    for lag in 1:p; companion[1:k, (lag-1)*k+1:lag*k] = A[lag]; end
    p > 1 && (companion[k+1:end, 1:end-k] = I((p-1)*k))

    # --- Validation ---
    post  = String[]
    notes = String[]
    ev_comp = abs.(eigvals(companion))
    max_ev  = maximum(ev_comp)
    max_ev ≥ 1.0 && push!(post, "EXPLOSIVE: max companion eigenvalue=$(round(max_ev,digits=4)) ≥ 1. Forecasts will diverge.")
    max_ev > 0.95 && max_ev < 1.0 && push!(notes, "High persistence: max eigenvalue=$(round(max_ev,digits=4)). Long-memory behaviour.")

    !isposdef(Σ) && push!(post, "Residual covariance is not PD. OLS may be ill-conditioned or T too small.")

    # Condition number check: skip for large k (O(k³p³) cost)
    if k * p ≤ 200
        cond_Z = cond(Z'Z)
        cond_Z > 1e8 && push!(post, "cond(Z'Z)=$(round(cond_Z,sigdigits=2)): severe multicollinearity. Consider method=:ridge.")
    else
        push!(notes, "Condition number check skipped (k=$k, p=$p): O((kp)³) too expensive. Use method=:ridge proactively for large systems.")
    end

    blocking = !isempty(pre) && any(contains.(pre, "degenerate"))
    vr = ValidationReport(:var, pre, post, blocking, notes)
    VARResult(B, A, intercept, Matrix(Σ), companion, E, p, ic_table, config, vr)
end

"""
    irf_var(result, h; orthogonalized) → Vector{Matrix}

Impulse response functions Ψ_h = J Fʰ J' P where P = chol(Σ).  (K2)
Returns a length-(h+1) vector of (k × k) matrices for horizons 0…h.
"""
function irf_var(result::VARResult, h::Int; orthogonalized::Bool=true)
    k  = length(result.intercept)
    F  = result.companion
    J  = [I(k) zeros(k, size(F,2)-k)]
    P  = orthogonalized ? cholesky(Symmetric(result.Σ)).L : I(k)
    Fh = Matrix(I, size(F)...)
    [J * Fh * J' * P for t in 0:h if (t == 0 || (Fh = Fh*F; true))]
end

"""
    granger_causality_var(Y, config, cause_idx, effect_idx) → report

Block-exclusion F-test with exact p-value via regularized incomplete beta.
H₀: variables at `cause_idx` do not Granger-cause variables at `effect_idx`.
                                            (K2 — self-contained p-values)
"""
function granger_causality_var(Y::AbstractMatrix{Float64}, config::VARConfig,
                                cause_idx::Vector{Int}, effect_idx::Vector{Int})
    T, k = size(Y)
    result_full = fit_var(Y, config)
    p = result_full.p

    # Restricted model: zero out cause→effect lags
    Z, Yout = _build_var_regressor(Y, p)
    Teff    = size(Yout, 1)

    # Identify which regressor columns correspond to cause_idx lags
    restrict_cols = Int[]
    for lag in 1:p
        for ci in cause_idx
            push!(restrict_cols, (lag-1)*k + ci)
        end
    end

    # Restricted OLS (set those columns to zero via column deletion)
    free_cols = setdiff(1:size(Z,2), restrict_cols)
    Zr     = Z[:, free_cols]
    Qr, Rr = qr(Zr); Br = Rr \ (Qr' * Yout[:, effect_idx])
    Er     = Yout[:, effect_idx] - Zr*Br
    SSEr   = sum(Er.^2)

    Qu, Ru = qr(Z); Bu = Ru \ (Qu' * Yout[:, effect_idx])
    Eu     = Yout[:, effect_idx] - Z*Bu
    SSEu   = sum(Eu.^2)

    q       = length(restrict_cols) * length(effect_idx)
    dfr     = Teff - size(Z,2)
    F_stat  = max(0.0, (SSEr - SSEu)/q / (SSEu/dfr))
    p_val   = 1 - _betai(dfr/(dfr + q*F_stat), dfr/2, q/2)

    (F=F_stat, df1=q, df2=dfr, p_value=p_val,
     reject=p_val < 0.05,
     note="H₀: $(cause_idx) does not Granger-cause $(effect_idx). p=$(round(p_val,digits=4)).")
end

# =============================================================================
# PART 4 — t-COPULA
# =============================================================================

struct TCopulaConfig
    df::Union{Nothing,Float64}        # nothing = estimate by profile likelihood
    correlation_method::Symbol        # :kendall or :pearson
    df_grid::AbstractVector{Float64}  # search grid for profile likelihood
end

TCopulaConfig(; df::Union{Nothing,Float64}=nothing,
                correlation_method::Symbol=:kendall,
                df_grid::AbstractVector{Float64}=2.0:0.5:30.0) =
    TCopulaConfig(df, correlation_method, df_grid)

struct TCopulaResult
    R::Matrix{Float64}    # correlation matrix
    ν::Float64            # degrees of freedom
    pseudo_obs::Matrix{Float64}   # n × d uniform [0,1]
    loglik::Float64
    config::TCopulaConfig
    validation::ValidationReport
end

"""
    _pseudo_obs(X) → Matrix

Mid-rank transform: U_{i,j} = (rank_{i,j} - 0.5) / n.  (QWEN)
Avoids boundary singularities (0 and 1) in _t_quantile.
"""
function _pseudo_obs(X::AbstractMatrix{Float64})
    n, d = size(X)
    U = zeros(n, d)
    for j in 1:d
        r = sortperm(sortperm(X[:, j]))   # ranks 1…n
        U[:, j] = (r .- 0.5) ./ n
    end
    U
end

"""
    _kendall_to_pearson(U) → R

Pairwise Kendall's τ → Pearson ρ via sin(π/2 τ).  (K2)
More robust than direct Pearson of t-transformed data in heavy-tailed samples.
"""
function _kendall_to_pearson(U::AbstractMatrix{Float64})
    n, d = size(U)
    R    = Matrix(1.0I, d, d)
    for i in 1:d, j in i+1:d
        u = U[:, i]; v = U[:, j]
        concordant = 0; discordant = 0
        for s in 1:n, t in s+1:n
            sign_uv = sign(u[s]-u[t]) * sign(v[s]-v[t])
            sign_uv > 0 ? (concordant += 1) : sign_uv < 0 && (discordant += 1)
        end
        τ = (concordant - discordant) / (n*(n-1)/2)
        ρ = sin(π/2 * τ)
        R[i, j] = R[j, i] = clamp(ρ, -0.9999, 0.9999)
    end
    R
end

"""
    _tcopula_loglik(U, R, ν) → Float64

Log-likelihood of the t-copula at (R, ν):
  ℓ = Σ_t [log f_t(z_t; R, ν) − Σ_j log f_t(z_{tj}; 1, ν)]
where z_{tj} = t_ν⁻¹(u_{tj}).  (K2)
"""
function _tcopula_loglik(U::AbstractMatrix, R::AbstractMatrix, ν::Float64)
    ν ≤ 2 && return -Inf
    n, d = size(U)
    Rc   = cholesky(_positive_definite_approx(R))
    ldR  = 2*sum(log.(diag(Rc.L)))   # log det R

    # Transform pseudo-obs to t-variates
    Z = [_t_quantile(U[i,j], ν) for i in 1:n, j in 1:d]

    # Log-likelihood of multivariate t minus sum of univariate t log-densities
    ll = 0.0
    for i in 1:n
        z  = Z[i, :]
        q  = dot(z, Rc \ z)
        # Multivariate t log-density
        ll += _loggamma((ν+d)/2) - _loggamma(ν/2) - 0.5*(d*log(ν*π) + ldR) -
              (ν+d)/2*log1p(q/ν)
        # Subtract univariate t log-densities
        for j in 1:d
            ll -= _loggamma((ν+1)/2) - _loggamma(ν/2) - 0.5*log(ν*π) -
                  (ν+1)/2*log1p(z[j]^2/ν)
        end
    end
    ll
end

function _positive_definite_approx(R::AbstractMatrix)
    R2 = Symmetric(0.5*(R + R'))
    F  = eigen(R2); ev = F.values
    if any(ev .< 1e-6)
        ev_clipped = max.(ev, 1e-6)
        R2 = F.vectors * Diagonal(ev_clipped) * F.vectors'
        # Rescale to unit diagonal
        d  = sqrt.(diag(R2))
        R2 = R2 ./ (d * d')
    end
    cholesky(Symmetric(R2))
end

"""
    fit_tcopula(X, config) → TCopulaResult

Full t-copula estimation pipeline:
  1. Mid-rank pseudo-observations (QWEN)
  2. Kendall's τ → ρ or Pearson correlation (K2)
  3. PSD projection with unit-diagonal rescaling
  4. Profile-likelihood ν estimation (K2) or fixed df
"""
function fit_tcopula(X::AbstractMatrix{Float64}, config::TCopulaConfig=TCopulaConfig())
    n, d = size(X)
    pre  = String[]
    any(isnan.(X)) && push!(pre, "Data contains NaN.")
    n < 50 && push!(pre, "n=$n < 50: copula parameter estimates unreliable.")

    # Step 1: pseudo-observations
    U = _pseudo_obs(X)

    # Step 2: correlation
    if config.correlation_method == :kendall
        R = _kendall_to_pearson(U)
    else
        # Pearson of t-transformed quantiles using initial ν=5
        Z = [_t_quantile(U[i,j], 5.0) for i in 1:n, j in 1:d]
        R = cor(Z)
        R = Symmetric(0.5*(R+R')); R[diagind(R)] .= 1.0
    end

    # PSD projection
    F  = eigen(Symmetric(R))
    any(F.values .< 1e-6) && (R = F.vectors * Diagonal(max.(F.values, 1e-6)) * F.vectors')
    di = sqrt.(diag(R)); R = R ./ (di * di'); R[diagind(R)] .= 1.0

    # Step 3: ν estimation via profile likelihood  (K2)
    ν, ll = if config.df === nothing
        best_ll = -Inf; best_ν = 5.0
        for ν_try in config.df_grid
            ll_try = _tcopula_loglik(U, R, ν_try)
            ll_try > best_ll && (best_ll = ll_try; best_ν = ν_try)
        end
        best_ν, best_ll
    else
        config.df, _tcopula_loglik(U, R, config.df)
    end

    # --- Validation ---
    post  = String[]
    notes = String[]
    !isposdef(Symmetric(R)) && push!(post, "Correlation matrix not PD after projection — check for near-collinear variables.")
    ν < 2  && push!(post, "ν=$(round(ν,digits=2)) < 2: t-copula has infinite variance marginals.")
    ν > 30 && push!(notes, "ν=$(round(ν,digits=1)) > 30: t-copula is indistinguishable from Gaussian. Use Gaussian copula.")

    # Tail dependence: λ_L = 2·t_{ν+1}(-√((ν+1)(1-ρ)/(1+ρ)))  (K2)
    n_pairs = 0; λ_L_sum = 0.0
    for i in 1:d, j in i+1:d
        ρ = R[i,j]
        ρ < 1.0 || continue
        z   = -sqrt((ν+1)*(1-ρ)/(1+ρ+1e-10))
        λ   = 2*_t_cdf(z, ν+1)
        λ_L_sum += λ; n_pairs += 1
    end
    λ_L = n_pairs > 0 ? λ_L_sum/n_pairs : 0.0
    λ_L < 0.02 && push!(notes, "Mean lower tail dependence λ_L=$(round(λ_L,digits=4)) < 0.02: " *
                                 "t-copula provides negligible crash-dependence over Gaussian.")
    push!(notes, "Theoretical mean λ_L = $(round(λ_L,digits=4)) at ν=$(round(ν,digits=1)).")

    # Marginal/joint contradiction check  (ZAI)
    # If marginals are estimated as Gaussian but λ_L is high, the model is
    # self-contradictory: Gaussian marginals + heavy-tailed joint is inconsistent.
    if λ_L > 0.1
        push!(notes, "λ_L=$(round(λ_L,digits=3)) > 0.1: if you fit Gaussian marginals, " *
                     "the joint tail dependence contradicts the marginal assumption. " *
                     "Use Student-t marginals or a hierarchical copula.")
    end

    blocking = !isempty(pre)
    vr = ValidationReport(:tcopula, pre, post, blocking, notes)
    TCopulaResult(R, ν, U, ll, config, vr)
end

"""
    sample_tcopula(result, n) → Matrix (n × d)

Exact simulation via the mixture representation (K2):
  Z ~ N(0, R)          via Cholesky
  W ~ χ²_ν / ν         via sum of ν squared normals (exact for integer ν)
  X = Z / √W           → multivariate t
  U = t_ν(X)           → uniform [0,1] on t-copula
"""
function sample_tcopula(result::TCopulaResult, n_samples::Int)
    d  = size(result.R, 1)
    ν  = result.ν
    L  = cholesky(Symmetric(result.R)).L

    samples = zeros(n_samples, d)
    ν_int   = max(2, round(Int, ν))

    for i in 1:n_samples
        Z  = L * randn(d)
        W  = sum(randn(ν_int)^2 for _ in 1:ν_int) / ν
        X  = Z ./ sqrt(W)
        samples[i, :] = [_t_cdf(x, ν) for x in X]
    end
    samples
end

# =============================================================================
# PART 5 — PIPELINE COORDINATOR
# =============================================================================

"""
    StratumIAuditReport
"""
struct StratumIAuditReport
    pca::ValidationReport
    garch::ValidationReport
    var::ValidationReport
    tcopula::ValidationReport
    overall_severity::Symbol    # :ok | :warning | :blocked
    summary::String
end

function Base.show(io::IO, r::StratumIAuditReport)
    bar = "=" ^ 65
    println(io, bar); println(io, "STRATUM I AUDIT  [$(r.overall_severity)]"); println(io, bar)
    for (name, vr) in [("PCA",r.pca),("GARCH",r.garch),("VAR",r.var),("t-Copula",r.tcopula)]
        tag = vr.blocking ? "BLOCKED" : (isempty(vr.pre_checks) && isempty(vr.post_checks) ? "PASS" : "WARN")
        println(io, "\n[$name]  [$tag]")
        for c in vr.pre_checks;  println(io, "  [pre]  $c"); end
        for c in vr.post_checks; println(io, "  [post] $c"); end
        for n in vr.notes[1:min(2,end)]; println(io, "  [note] $n"); end
    end
    println(io, "\n[Summary]\n  $(r.summary)"); println(io, bar)
end

"""
    run_stratum_i_audit(returns; pca_config, garch_idx, var_config, copula_config)
    → StratumIAuditReport

Coordinating audit function. Runs all four components with validation.
Output feeds directly into Stratum II:
  - pca.scores       → RMT cleaning, manifold projection
  - garch.sigma2     → volatility filtering for RPCA
  - var.residuals    → structural break detection, HMM
  - tcopula.pseudo_obs → copula-based stress testing
"""
function run_stratum_i_audit(returns::AbstractMatrix{Float64};
                              pca_config::PCAConfig=PCAConfig(),
                              garch_idx::Int=1,
                              var_config::VARConfig=VARConfig(),
                              copula_config::TCopulaConfig=TCopulaConfig())
    T, k = size(returns)

    pca_r    = fit_pca(returns, pca_config)
    garch_r  = fit_garch(returns[:, garch_idx])
    var_r    = fit_var(returns, var_config)
    cop_r    = fit_tcopula(returns, copula_config)

    reports  = [pca_r.validation, garch_r.validation, var_r.validation, cop_r.validation]
    n_blocked = count(r.blocking for r in reports)
    n_warn    = count(!isempty(r.post_checks) || !isempty(r.pre_checks) for r in reports)

    sev = n_blocked > 0 ? :blocked : n_warn > 0 ? :warning : :ok
    summary = "T=$T, k=$k assets. $n_blocked blocked, $n_warn with warnings. " * (
        sev == :ok      ? "All estimators pass assumptions." :
        sev == :blocked ? "BLOCKED outputs must not feed into Stratum II." :
                          "Review warnings before production deployment.")

    StratumIAuditReport(pca_r.validation, garch_r.validation, var_r.validation,
                         cop_r.validation, sev, summary)
end

# =============================================================================
# DEMONSTRATION
# =============================================================================

function run_demo()
    println("\n" * "=" ^ 65)
    println("ComputationalStatistics (Stratum I) — Demonstration")
    println("=" ^ 65)
    Random.seed!(42)

    T, p = 300, 15
    # Factor model: 3 true factors
    F = randn(T, 3); β = randn(p, 3)*0.4
    R = F * β' .+ 0.1*randn(T, p)

    println("\n--- Part 1: PCA (parallel analysis) ---")
    cfg_pca = PCAConfig(; standardize=true, selection_method=:parallel, n_parallel=50)
    pca_r   = fit_pca(R, cfg_pca)
    display(pca_r.validation)
    println("  n_components=$(pca_r.n_components)  cumvar=$(round(sum(pca_r.explained_var[1:pca_r.n_components]),digits=3))")

    println("\n--- Part 2: GARCH(1,1) ---")
    ret1  = randn(T)*0.01 .+ 0.003
    g_r   = fit_garch(ret1; )
    display(g_r.validation)
    fc    = forecast_garch(g_r, 5)
    println("  α=$(round(g_r.α,digits=4))  β=$(round(g_r.β,digits=4))  α+β=$(round(g_r.α+g_r.β,digits=4))")
    println("  5-step vol forecasts: $(round.(sqrt.(fc),sigdigits=3))")

    println("\n--- Part 3: VAR(p) with Granger causality ---")
    var_r = fit_var(R, VARConfig(; ic=:bic))
    display(var_r.validation)
    gc    = granger_causality_var(R, VARConfig(; p=var_r.p), [1,2], [3])
    println("  Selected lag p=$(var_r.p)  max_eigenvalue=$(round(maximum(abs.(eigvals(var_r.companion))),digits=4))")
    println("  Granger: F=$(round(gc.F,digits=3)) p=$(round(gc.p_value,digits=4)) reject=$(gc.reject)")

    println("\n--- Part 4: t-Copula ---")
    cop_r = fit_tcopula(R, TCopulaConfig(; correlation_method=:kendall))
    display(cop_r.validation)
    sim   = sample_tcopula(cop_r, 500)
    println("  ν=$(round(cop_r.ν,digits=2))  ll=$(round(cop_r.loglik,digits=1))")
    println("  Sample min correlation: $(round(minimum(cor(sim)),digits=3))")

    println("\n--- Full Pipeline Audit ---")
    rpt = run_stratum_i_audit(R)
    display(rpt)

    println("Demonstration complete.")
end

end # module ComputationalStatistics
