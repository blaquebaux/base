# ============================================================================
# REGIME LIKELIHOOD — Multiple Dispatch (Type-stable)
# Source: Deepseek v2, integrated with fixes (May 2026)
# Replaces the single _regime_likelihood in module_5_dpm.jl
# Key fix: Dict atoms use :σ² (variance) not :σ (std) — matches _random_regime_model()
# ============================================================================

using SpecialFunctions: gamma  # already in Project.toml deps

"""
    _regime_likelihood(atom::Dict{Symbol,Any}, return_t, config) -> Float64

Likelihood for a regime represented as a Dict (initialization phase).
Dict keys: :μ (mean), :σ² (variance). Note: :σ² not :σ.
"""
function _regime_likelihood(
    atom::Dict{Symbol,Any},
    return_t::Float64,
    config::DPMConfig
)::Float64
    μ  = get(atom, :μ, 0.0)
    σ² = get(atom, :σ², 0.01)           # NOTE: :σ² (variance), not :σ (std)
    σ  = sqrt(max(σ², 1e-8))
    z  = (return_t - μ) / σ
    return exp(-0.5 * z^2) / (σ * sqrt(2π))
end

"""
    _regime_likelihood(atom::RegimeModel, return_t, config) -> Float64

Likelihood for a regime represented as a RegimeModel (post-EM phase).
Uses:
  - Gaussian approximation with vol_scale for Fixed/Growth regimes
  - Cauchy or t-distribution for Floating regime (α < 2)

Note: Production particle filter should maintain σ²_t state per particle
and call _full_conditional_likelihood instead. This is the approximation
used when that state is unavailable.
"""
function _regime_likelihood(
    atom::RegimeModel,
    return_t::Float64,
    config::DPMConfig
)::Float64
    μ = atom.arma_params.μ
    σ = max(atom.vol_scale, 1e-6)

    if !isnothing(atom.garch_params)
        # Fixed/Growth regime: Gaussian with vol_scale as proxy for σ_t
        z = (return_t - μ) / σ
        return exp(-0.5 * z^2) / (σ * sqrt(2π))
    else
        # Floating regime: tail-appropriate distribution
        if atom.tail_index < 2.0
            # Cauchy — correct for α ≈ 1
            return 1.0 / (π * σ * (1.0 + ((return_t - μ) / σ)^2))
        else
            # Student-t with ν degrees of freedom
            ν = atom.dof_ν !== nothing ? atom.dof_ν : 5.0
            ν = max(ν, 2.01)  # ensure finite variance
            factor = gamma((ν + 1.0) / 2.0) / (gamma(ν / 2.0) * sqrt(π * ν) * σ)
            return factor * (1.0 + ((return_t - μ)^2) / (ν * σ^2))^(-(ν + 1.0) / 2.0)
        end
    end
end

"""
    _full_conditional_likelihood(atom, return_t, σ²_t, lagged_ε, lagged_returns)

Full ARMA-GARCH conditional likelihood for production particle filter.
Requires per-particle state: current σ²_t, lagged innovations, lagged returns.
This replaces _regime_likelihood once the particle filter maintains full state.
"""
function _full_conditional_likelihood(
    atom::RegimeModel,
    return_t::Float64,
    σ²_t::Float64,
    lagged_ε::Vector{Float64},     # ε_{t-1}, ε_{t-2}, ... (length q)
    lagged_returns::Vector{Float64} # r_{t-1}, r_{t-2}, ... (length p)
)::Float64
    # Conditional mean from ARMA
    μ_t = atom.arma_params.μ
    for i in eachindex(atom.arma_params.φ)
        i <= length(lagged_returns) && (μ_t += atom.arma_params.φ[i] * lagged_returns[i])
    end
    for j in eachindex(atom.arma_params.θ)
        j <= length(lagged_ε) && (μ_t += atom.arma_params.θ[j] * lagged_ε[j])
    end

    z = (return_t - μ_t) / sqrt(max(σ²_t, 1e-8))

    if atom.tail_index < 2.0
        # Cauchy
        return 1.0 / (π * sqrt(σ²_t) * (1.0 + z^2))
    else
        ν = atom.dof_ν !== nothing ? atom.dof_ν : 5.0
        ν = max(ν, 2.01)
        factor = gamma((ν + 1.0) / 2.0) / (gamma(ν / 2.0) * sqrt(π * ν * σ²_t))
        return factor * (1.0 + z^2 / ν)^(-(ν + 1.0) / 2.0)
    end
end
