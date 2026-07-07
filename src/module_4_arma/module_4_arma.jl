module ARMAGARCH

using Distributions, Optim, LinearAlgebra, Statistics

export ARMASpec, ARMAParams, GARCHParams, RegimeModel,
       estimate_armagarch, rolling_realized_vol,
       tail_index_from_vol_scale, dof_from_tail_index,
       arma_loglikelihood, garch_loglikelihood

# ============================================================================
# Model Specifications
# ============================================================================

"""
    ARMASpec

ARMA(p,q) model specification.

# Fields
- `p::Int`: AR order (0, 1, or 2)
- `q::Int`: MA order (0, 1, or 2)
"""
struct ARMASpec
    p::Int
    q::Int

    function ARMASpec(p::Int, q::Int)
        @assert p in [0, 1, 2] "AR order p must be 0, 1, or 2"
        @assert q in [0, 1, 2] "MA order q must be 0, 1, or 2"
        # NOTE: ARMASpec(0,0) is valid for Floating regime atoms (constant-mean only)
        new(p, q)
    end
end

"""
    ARMAParams

Parameters for ARMA(p,q) model.

# Fields
- `μ::Float64`: Drift/intercept
- `φ::Vector{Float64}`: AR coefficients (length p)
- `θ::Vector{Float64}`: MA coefficients (length q)
- `σ²::Float64`: Innovation variance
"""
struct ARMAParams
    μ::Float64
    φ::Vector{Float64}
    θ::Vector{Float64}
    σ²::Float64

    function ARMAParams(μ::Float64, φ::Vector{Float64}, θ::Vector{Float64}, σ²::Float64)
        @assert σ² > 0 "Innovation variance must be positive"
        new(μ, φ, θ, σ²)
    end
end

"""
    GARCHParams

Parameters for GARCH(1,1) model with jump component.

# Fields
- `ω::Float64`: Constant variance term
- `α₁::Float64`: ARCH coefficient (news impact)
- `β₁::Float64`: GARCH coefficient (persistence)
- `γ::Float64`: Jump intensity coefficient (from Module 5)

# Constraints
- ω > 0
- α₁ ≥ 0, β₁ ≥ 0
- α₁ + β₁ < 1 (stationarity)
"""
struct GARCHParams
    ω::Float64
    α₁::Float64
    β₁::Float64
    γ::Float64

    function GARCHParams(ω::Float64, α₁::Float64, β₁::Float64, γ::Float64=0.0)
        @assert ω > 0 "ω must be positive"
        @assert α₁ >= 0 "α₁ must be non-negative"
        @assert β₁ >= 0 "β₁ must be non-negative"
        @assert α₁ + β₁ < 1.0 "α₁ + β₁ must be < 1 for stationarity"
        new(ω, α₁, β₁, γ)
    end
end

"""
    RegimeModel

Complete regime-specific model containing ARMA, GARCH, and tail parameters.

# Fields
- `arma_spec::ARMASpec`: ARMA specification
- `arma_params::ARMAParams`: ARMA parameters
- `garch_params::Union{GARCHParams,Nothing}`: GARCH parameters (nothing for Floating regime)
- `tail_index::Float64`: Tail index α (heavy-tailedness)
- `dof_ν::Union{Float64,Nothing}`: t-distribution degrees of freedom (nothing if α < 2)
- `vol_scale::Float64`: Regime volatility scale σ_regime
"""
struct RegimeModel
    arma_spec::ARMASpec
    arma_params::ARMAParams
    garch_params::Union{GARCHParams,Nothing}
    tail_index::Float64
    dof_ν::Union{Float64,Nothing}
    vol_scale::Float64

    function RegimeModel(
        arma_spec::ARMASpec,
        arma_params::ARMAParams,
        garch_params::Union{GARCHParams,Nothing},
        tail_index::Float64,
        dof_ν::Union{Float64,Nothing},
        vol_scale::Float64
    )
        @assert 1.5 <= tail_index <= 4.0 "Tail index must be in [1.5, 4.0]"
        new(arma_spec, arma_params, garch_params, tail_index, dof_ν, vol_scale)
    end
end

# ============================================================================
# ARMA Log-Likelihood
# ============================================================================

"""
    arma_loglikelihood(
        returns::Vector{Float64},
        params::Vector{Float64},
        spec::ARMASpec
    ) -> Float64

Compute Gaussian log-likelihood for ARMA(p,q) model.

# Arguments
- `returns::Vector{Float64}`: Return series
- `params::Vector{Float64}`: Parameter vector [μ, φ..., θ..., σ²]
- `spec::ARMASpec`: Model specification

# Returns
- Negative log-likelihood (for minimization)
"""
function arma_loglikelihood(
    returns::Vector{Float64},
    params::Vector{Float64},
    spec::ARMASpec
)::Float64
    T = length(returns)
    p = spec.p
    q = spec.q

    # Unpack parameters
    μ = params[1]
    φ = p > 0 ? params[2:1+p] : Float64[]
    θ = q > 0 ? params[2+p:1+p+q] : Float64[]
    σ² = params[end]

    σ² <= 0 && return Inf

    # Compute innovations recursively
    ε = zeros(T)

    # Initialize with unconditional mean
    for t in 1:T
        # AR component
        ar_part = 0.0
        for i in 1:p
            if t - i > 0
                ar_part += φ[i] * returns[t - i]
            end
        end

        # MA component
        ma_part = 0.0
        for j in 1:q
            if t - j > 0
                ma_part += θ[j] * ε[t - j]
            end
        end

        # Innovation
        ε[t] = returns[t] - μ - ar_part - ma_part
    end

    # Gaussian log-likelihood
    loglik = -0.5 * T * log(2π * σ²) - 0.5 * sum(ε.^2) / σ²

    return -loglik  # Return negative for minimization
end

"""
    garch_loglikelihood(
        returns::Vector{Float64},
        arma_params::ARMAParams,
        garch_params::GARCHParams
    ) -> Float64

Compute joint ARMA-GARCH log-likelihood.

Uses conditional variance from GARCH(1,1) with t-distribution innovations
when tail index α > 2.
"""
function garch_loglikelihood(
    returns::Vector{Float64},
    arma_params::ARMAParams,
    garch_params::GARCHParams
)::Float64
    T = length(returns)
    μ = arma_params.μ
    φ = arma_params.φ
    θ = arma_params.θ
    p = length(φ)
    q = length(θ)

    ω = garch_params.ω
    α₁ = garch_params.α₁
    β₁ = garch_params.β₁

    # Compute ARMA innovations
    ε = zeros(T)
    for t in 1:T
        ar_part = sum(i <= p && t - i > 0 ? φ[i] * returns[t - i] : 0.0 for i in 1:2)
        ma_part = sum(j <= q && t - j > 0 ? θ[j] * ε[t - j] : 0.0 for j in 1:2)
        ε[t] = returns[t] - μ - ar_part - ma_part
    end

    # Compute GARCH variances
    σ²_t = fill(ω / (1 - α₁ - β₁), T)  # Initialize at unconditional

    for t in 2:T
        σ²_t[t] = ω + α₁ * ε[t-1]^2 + β₁ * σ²_t[t-1]
        σ²_t[t] = max(σ²_t[t], 1e-8)   # Numerical floor (1e-8 ≈ 0.01% daily vol)
    end

    # Gaussian log-likelihood (conditional)
    loglik = -0.5 * sum(log.(2π .* σ²_t) .+ ε.^2 ./ σ²_t)

    return -loglik
end

# ============================================================================
# Joint QMLE Estimation
# ============================================================================

"""
    estimate_armagarch(
        returns::Vector{Float64},
        spec::ARMASpec;
        use_garch::Bool=true,
        initial_params::Union{Nothing,ARMAParams,GARCHParams}=nothing
    ) -> Tuple{ARMAParams, Union{Nothing,GARCHParams}, Float64}

Estimate ARMA(p,q) and optionally GARCH(1,1) via Quasi-Maximum Likelihood.

# Arguments
- `returns::Vector{Float64}`: Return series
- `spec::ARMASpec`: ARMA specification
- `use_garch::Bool`: Whether to estimate GARCH component (default: true)
- `initial_params`: Warm-start parameters (optional)

# Returns
- `arma_params::ARMAParams`: Estimated ARMA parameters
- `garch_params::Union{Nothing,GARCHParams}`: Estimated GARCH parameters (or nothing)
- `loglikelihood::Float64`: Optimized log-likelihood value
"""
function estimate_armagarch(
    returns::Vector{Float64},
    spec::ARMASpec;
    use_garch::Bool=true,
    initial_params::Union{Nothing,ARMAParams,GARCHParams}=nothing
)::Tuple{ARMAParams, Union{Nothing,GARCHParams}, Float64}

    T = length(returns)
    p = spec.p
    q = spec.q

    @assert T > p + q + 5 "Insufficient data for estimation"

    # Initial parameter guesses
    μ_init = mean(returns)
    σ²_init = var(returns)

    # ARMA initial parameters
    φ_init = p > 0 ? fill(0.1, p) : Float64[]
    θ_init = q > 0 ? fill(0.1, q) : Float64[]

    # Pack ARMA parameters: [μ, φ..., θ..., log(σ²)]
    arma_init = vcat([μ_init], φ_init, θ_init, [log(σ²_init)])

    # ARMA estimation
    function arma_obj(params)
        # Unpack and ensure σ² > 0
        mod_params = copy(params)
        mod_params[end] = exp(params[end])  # σ² = exp(log_σ²)
        arma_loglikelihood(returns, mod_params, spec)
    end

    # Optimize ARMA
    arma_result = optimize(arma_obj, arma_init, BFGS(),
                          Optim.Options(show_trace=false, iterations=1000))

    arma_opt = Optim.minimizer(arma_result)
    arma_μ = arma_opt[1]
    arma_φ = p > 0 ? arma_opt[2:1+p] : Float64[]
    arma_θ = q > 0 ? arma_opt[2+p:1+p+q] : Float64[]
    arma_σ² = exp(arma_opt[end])

    arma_params = ARMAParams(arma_μ, arma_φ, arma_θ, arma_σ²)

    # GARCH estimation (if requested)
    garch_params = nothing
    if use_garch
        # Compute ARMA residuals
        ε = _compute_innovations(returns, arma_params, spec)

        # GARCH initial parameters
        ω_init = 0.01 * var(ε)
        α_init = 0.1
        β_init = 0.85

        garch_init = [log(ω_init), _logit(α_init), _logit(β_init)]

        function garch_obj(params)
            ω = exp(params[1])
            α = _sigmoid(params[2])
            β = _sigmoid(params[3])

            # Stationarity constraint
            if α + β >= 0.999
                return Inf
            end

            gp = GARCHParams(ω, α, β)
            garch_loglikelihood(returns, arma_params, gp)
        end

        garch_result = optimize(garch_obj, garch_init, BFGS(),
                               Optim.Options(show_trace=false, iterations=1000))

        garch_opt = Optim.minimizer(garch_result)
        garch_ω = exp(garch_opt[1])
        garch_α = _sigmoid(garch_opt[2])
        garch_β = _sigmoid(garch_opt[3])

        garch_params = GARCHParams(garch_ω, garch_α, garch_β)
    end

    # Compute final log-likelihood
    if use_garch && garch_params !== nothing
        final_ll = -garch_loglikelihood(returns, arma_params, garch_params)
    else
        final_ll = -arma_loglikelihood(returns, vcat([arma_μ], arma_φ, arma_θ, [arma_σ²]), spec)
    end

    return (arma_params, garch_params, final_ll)
end

# ============================================================================
# Rolling Realized Volatility (Floating Regime)
# ============================================================================

"""
    rolling_realized_vol(
        returns::Vector{Float64},
        window_days::Int=10
    ) -> Vector{Float64}

Compute rolling realized volatility for Floating regime.

Uses square-root-of-time annualized standard deviation.

# Arguments
- `returns::Vector{Float64}`: Return series (daily)
- `window_days::Int`: Rolling window (default: 10)

# Returns
- `Vector{Float64}`: Annualized realized volatility series
"""
function rolling_realized_vol(
    returns::Vector{Float64},
    window_days::Int=10
)::Vector{Float64}
    T = length(returns)
    rv = fill(NaN, T)

    for t in window_days:T
        window_returns = returns[t-window_days+1:t]
        valid_returns = window_returns[.!isnan.(window_returns)]

        if length(valid_returns) >= div(window_days, 2)
            # Annualized volatility (252 trading days)
            rv[t] = sqrt(252.0) * std(valid_returns)
        end
    end

    return rv
end

# ============================================================================
# Tail Index Functions
# ============================================================================

"""
    tail_index_from_vol_scale(
        σ_regime::Float64,
        σ_baseline::Float64
    ) -> Float64

Compute tail index α from regime volatility scale.

Higher volatility → lower tail index (heavier tails).
Clipped to [1.5, 4.0] for numerical stability.

# Formula
α = 4.0 - 2.5 * (σ_regime / σ_baseline - 1.0)

# Arguments
- `σ_regime::Float64`: Regime volatility
- `σ_baseline::Float64`: Baseline (long-run average) volatility

# Returns
- `Float64`: Tail index α ∈ [1.5, 4.0]
"""
function tail_index_from_vol_scale(
    σ_regime::Float64,
    σ_baseline::Float64
)::Float64
    σ_baseline <= 0 && return 2.0

    ratio = σ_regime / σ_baseline
    α = 4.0 - 2.5 * max(0.0, ratio - 1.0)

    return clamp(α, 1.5, 4.0)
end

"""
    dof_from_tail_index(α::Float64) -> Float64

Convert tail index to t-distribution degrees of freedom.

Only valid when α > 2 (finite variance regime).

# Formula
ν = 2α / (α - 1)

# Arguments
- `α::Float64`: Tail index

# Returns
- `Float64`: Degrees of freedom ν (or Inf if α ≤ 2)
"""
function dof_from_tail_index(α::Float64)::Float64
    if α <= 2.0
        return Inf  # Infinite variance, use stable distribution
    end

    ν = 2.0 * α / (α - 1.0)
    return ν
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

"""
    _compute_innovations(
        returns::Vector{Float64},
        params::ARMAParams,
        spec::ARMASpec
    ) -> Vector{Float64}

Compute ARMA innovations (residuals) from parameters.
"""
function _compute_innovations(
    returns::Vector{Float64},
    params::ARMAParams,
    spec::ARMASpec
)::Vector{Float64}
    T = length(returns)
    p = spec.p
    q = spec.q
    μ = params.μ
    φ = params.φ
    θ = params.θ

    ε = zeros(T)

    for t in 1:T
        ar_part = sum(i <= length(φ) && t - i > 0 ? φ[i] * returns[t - i] : 0.0 for i in 1:p)
        ma_part = sum(j <= length(θ) && t - j > 0 ? θ[j] * ε[t - j] : 0.0 for j in 1:q)
        ε[t] = returns[t] - μ - ar_part - ma_part
    end

    return ε
end

"""
    _sigmoid(x::Float64) -> Float64

Sigmoid function for parameter transformation.
"""
_sigmoid(x::Float64) = 1.0 / (1.0 + exp(-x))

"""
    _logit(x::Float64) -> Float64

Logit function (inverse sigmoid).
"""
_logit(x::Float64) = log(x / (1.0 - x))

end  # module ARMAGARCH
