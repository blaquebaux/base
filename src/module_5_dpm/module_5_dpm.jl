module DPM

using Distributions, SpecialFunctions, Random, LinearAlgebra, Statistics

export DPMConfig, StickBreaking, ParticleFilterConfig,
       particle_filter_estep, mstep_update, update_concentration_parameter,
       em_estimation, recursive_update, detect_crisis_regime

# ============================================================================
# Configuration Structures
# ============================================================================

"""
    DPMConfig

Configuration for Dirichlet Process Mixture with Gamma hyperprior.

# Fields
- `max_components::Int`: Truncation level for stick-breaking (20-50)
- `concentration_prior_shape::Float64`: Gamma prior shape for γ (default: 2.0)
- `concentration_prior_rate::Float64`: Gamma prior rate for γ (default: 0.5)
- `convergence_threshold::Float64`: Log-likelihood convergence tolerance (default: 1e-4)
- `max_iterations::Int`: Maximum EM iterations (default: 500)
"""
struct DPMConfig
    max_components::Int
    concentration_prior_shape::Float64
    concentration_prior_rate::Float64
    convergence_threshold::Float64
    max_iterations::Int

    function DPMConfig(
        max_components::Int=30,
        concentration_prior_shape::Float64=2.0,
        concentration_prior_rate::Float64=0.5,
        convergence_threshold::Float64=1e-4,
        max_iterations::Int=500
    )
        @assert max_components >= 5 "Need at least 5 components"
        @assert concentration_prior_shape > 0 "Shape must be positive"
        @assert concentration_prior_rate > 0 "Rate must be positive"
        new(max_components, concentration_prior_shape, concentration_prior_rate, 
            convergence_threshold, max_iterations)
    end
end

"""
    StickBreaking

Stick-breaking representation of DPM.

# Fields
- `weights::Vector{Float64}`: Component weights π_k (sum to ~1)
- `atoms::Vector{RegimeModel}`: Regime parameters per component
"""
struct StickBreaking
    weights::Vector{Float64}
    atoms::Vector{Any}  # Will hold RegimeModel objects
end

"""
    ParticleFilterConfig

Configuration for particle filter E-step.

# Fields
- `n_particles::Int`: Number of particles (1000-5000)
- `resampling_threshold::Float64`: ESS fraction for resampling (default: 0.5)
"""
struct ParticleFilterConfig
    n_particles::Int
    resampling_threshold::Float64

    function ParticleFilterConfig(
        n_particles::Int=2000,
        resampling_threshold::Float64=0.5
    )
        @assert n_particles >= 100 "Need at least 100 particles"
        @assert 0.0 < resampling_threshold <= 1.0 "Threshold must be in (0, 1]"
        new(n_particles, resampling_threshold)
    end
end

# ============================================================================
# Particle Filter E-Step
# ============================================================================

"""
    particle_filter_estep(
        returns::Vector{Float64},
        current_params::StickBreaking,
        config::ParticleFilterConfig
    ) -> Tuple{Matrix{Float64}, Vector{Float64}}

Particle filter for E-step: estimate regime probabilities.

Uses sequential importance resampling (SIR) with adaptive resampling.

# Arguments
- `returns::Vector{Float64}`: Return observations
- `current_params::StickBreaking`: Current DPM parameters
- `config::ParticleFilterConfig`: Particle filter configuration

# Returns
- `regime_probs::Matrix{Float64}`: n_obs × n_components regime probabilities
- `smoothed_weights::Vector{Float64}`: Smoothed component weights
"""
function particle_filter_estep(
    returns::Vector{Float64},
    current_params::StickBreaking,
    config::ParticleFilterConfig
)::Tuple{Matrix{Float64}, Vector{Float64}}

    T = length(returns)
    K = length(current_params.weights)
    N = config.n_particles

    # Initialize particles
    particles = zeros(Int, N, T)  # Particle trajectories (regime assignments)
    weights = fill(1.0/N, N)      # Particle weights

    # Storage for regime probabilities
    regime_probs = zeros(T, K)

    for t in 1:T
        # Propagate particles (sample regimes)
        if t == 1
            # Initial draw from prior weights
            for i in 1:N
                particles[i, t] = _categorical_sample(current_params.weights)
            end
        else
            # Transition: stick to same regime or switch
            for i in 1:N
                prev_regime = particles[i, t-1]

                # Persistence probability (high persistence for regimes)
                persistence_prob = 0.95

                if rand() < persistence_prob
                    particles[i, t] = prev_regime
                else
                    particles[i, t] = _categorical_sample(current_params.weights)
                end
            end
        end

        # Weight update by likelihood
        for i in 1:N
            regime = particles[i, t]
            atom = current_params.atoms[regime]

            # Compute likelihood under this regime's model
            lik = _regime_likelihood(returns[t], atom)
            weights[i] *= lik
        end

        # Normalize weights
        sum_weights = sum(weights)
        if sum_weights > 0
            weights ./= sum_weights
        else
            weights .= 1.0/N
        end

        # Compute effective sample size
        ess = 1.0 / sum(weights.^2)

        # Resample if ESS below threshold
        if ess < config.resampling_threshold * N
            particles = _systematic_resample(particles, weights, t)
            weights .= 1.0/N
        end

        # Estimate regime probabilities
        for k in 1:K
            regime_probs[t, k] = sum(weights[particles[:, t] .== k])
        end
    end

    # Smoothed weights (posterior mean)
    smoothed_weights = vec(mean(regime_probs, dims=1))
    smoothed_weights ./= sum(smoothed_weights)

    return (regime_probs, smoothed_weights)
end

# ============================================================================
# M-Step: Update ARMA/GARCH Parameters
# ============================================================================

"""
    mstep_update(
        returns::Vector{Float64},
        regime_probs::Matrix{Float64},
        current_atoms::Vector{Any}
    ) -> Vector{Any}

M-step: update regime parameters using weighted maximum likelihood.

Each regime's parameters are updated using observations weighted by 
posterior regime probabilities.

# Arguments
- `returns::Vector{Float64}`: Return observations
- `regime_probs::Matrix{Float64}`: n_obs × n_components posterior probabilities
- `current_atoms::Vector{Any}`: Current regime models

# Returns
- `Vector{Any}`: Updated regime models
"""
function mstep_update(
    returns::Vector{Float64},
    regime_probs::Matrix{Float64},
    current_atoms::Vector{Any}
)::Vector{Any}

    T, K = size(regime_probs)
    updated_atoms = similar(current_atoms)

    for k in 1:K
        # Weights for this regime
        w = regime_probs[:, k]

        # Skip if negligible weight
        if sum(w) < 1e-6
            updated_atoms[k] = current_atoms[k]
            continue
        end

        # Weighted parameter update (simplified)
        # In full implementation: call ARMAGARCH.estimate_armagarch with weights
        updated_atoms[k] = _weighted_regime_update(returns, w, current_atoms[k])
    end

    return updated_atoms
end

# ============================================================================
# Escobar-West Concentration Update
# ============================================================================

"""
    update_concentration_parameter(
        γ_current::Float64,
        n_components_active::Int,
        n_obs::Int,
        prior_shape::Float64,
        prior_rate::Float64
    ) -> Float64

Update concentration parameter γ using Escobar-West Gibbs sampler.

Uses auxiliary variable method for Gamma prior.

# Arguments
- `γ_current::Float64`: Current concentration parameter
- `n_components_active::Int`: Number of active components
- `n_obs::Int`: Total observations
- `prior_shape::Float64`: Gamma prior shape
- `prior_rate::Float64`: Gamma prior rate

# Returns
- `Float64`: Updated γ
"""
function update_concentration_parameter(
    γ_current::Float64,
    n_components_active::Int,
    n_obs::Int,
    prior_shape::Float64,
    prior_rate::Float64
)::Float64

    # Auxiliary variable η ~ Beta(γ + 1, n)
    η = rand(Beta(γ_current + 1, n_obs))

    # Mixture weight
    π_mix = (prior_shape + n_components_active - 1) / 
            (prior_shape + n_components_active - 1 + n_obs * (prior_rate - log(η)))

    # Sample new γ
    if rand() < π_mix
        γ_new = rand(Gamma(prior_shape + n_components_active, 1.0 / (prior_rate - log(η))))
    else
        γ_new = rand(Gamma(prior_shape + n_components_active - 1, 1.0 / (prior_rate - log(η))))
    end

    return max(0.01, γ_new)
end

# ============================================================================
# Full EM Algorithm
# ============================================================================

"""
    em_estimation(
        returns::Vector{Float64},
        config::DPMConfig,
        pf_config::ParticleFilterConfig,
        initial_params::Union{Nothing,StickBreaking}=nothing
    ) -> Tuple{StickBreaking, Vector{Float64}, Bool}

Full EM estimation for DPM with Gamma hyperprior.

# Arguments
- `returns::Vector{Float64}`: Return series
- `config::DPMConfig`: DPM configuration
- `pf_config::ParticleFilterConfig`: Particle filter configuration
- `initial_params::Union{Nothing,StickBreaking}`: Warm-start parameters

# Returns
- `final_model::StickBreaking`: Estimated DPM
- `loglikelihood_history::Vector{Float64}`: Log-likelihood trajectory
- `converged::Bool`: Whether EM converged
"""
function em_estimation(
    returns::Vector{Float64},
    config::DPMConfig,
    pf_config::ParticleFilterConfig,
    initial_params::Union{Nothing,StickBreaking}=nothing
)::Tuple{StickBreaking, Vector{Float64}, Bool}

    T = length(returns)
    K = config.max_components

    # Initialize stick-breaking
    if initial_params === nothing
        # Random initialization
        v = rand(Beta(1.0, 1.0), K)  # Stick-breaking proportions
        weights = _stick_breaking_weights(v)
        atoms = [_random_regime_model() for _ in 1:K]
        current_params = StickBreaking(weights, atoms)
    else
        current_params = initial_params
    end

    # Concentration parameter
    γ = config.concentration_prior_shape / config.concentration_prior_rate

    loglik_history = Float64[]
    converged = false

    for iter in 1:config.max_iterations
        # E-step: Particle filter
        regime_probs, smoothed_weights = particle_filter_estep(
            returns, current_params, pf_config
        )

        # Compute log-likelihood
        ll = _compute_loglikelihood(returns, current_params, regime_probs)
        push!(loglik_history, ll)

        # Check convergence
        if iter > 1
            prev_ll = loglik_history[end-1]
            curr_ll = loglik_history[end]
            # Guard against div-by-zero when log-likelihood is zero or very small
            denom = abs(prev_ll) < 1e-300 ? 1.0 : abs(prev_ll)
            rel_change = abs(curr_ll - prev_ll) / denom
            if rel_change < config.convergence_threshold
                converged = true
                break
            end
        end

        # M-step: Update parameters
        updated_atoms = mstep_update(returns, regime_probs, current_params.atoms)

        # Update concentration parameter
        n_active = sum(smoothed_weights .> 0.01)
        γ = update_concentration_parameter(
            γ, n_active, T,
            config.concentration_prior_shape,
            config.concentration_prior_rate
        )

        # Update stick-breaking weights
        # Collapse small components
        updated_weights = _collapse_components(smoothed_weights, updated_atoms, γ)

        current_params = StickBreaking(updated_weights, updated_atoms)
    end

    return (current_params, loglik_history, converged)
end

# ============================================================================
# Recursive Bayesian Update (Daily Fast Path)
# ============================================================================

"""
    recursive_update(
        previous_params::StickBreaking,
        new_return::Float64,
        forgetting_factor::Float64=0.99
    ) -> StickBreaking

Recursive Bayesian update with forgetting factor.

For daily fast path: update regime probabilities with new observation
without full EM re-estimation.

# Arguments
- `previous_params::StickBreaking`: Previous DPM parameters
- `new_return::Float64`: New return observation
- `forgetting_factor::Float64`: ρ = 0.99 (slight forgetting)

# Returns
- `StickBreaking`: Updated parameters
"""
function recursive_update(
    previous_params::StickBreaking,
    new_return::Float64,
    forgetting_factor::Float64=0.99
)::StickBreaking

    K = length(previous_params.weights)

    # Update weights with forgetting
    updated_weights = forgetting_factor .* previous_params.weights

    # Compute likelihood under each regime
    likelihoods = Float64[]
    for k in 1:K
        lik = _regime_likelihood(new_return, previous_params.atoms[k])
        push!(likelihoods, lik)
    end

    # Bayesian update
    updated_weights .*= likelihoods
    updated_weights ./= sum(updated_weights)

    # Slight parameter drift (optional)
    updated_atoms = previous_params.atoms

    return StickBreaking(updated_weights, updated_atoms)
end

# ============================================================================
# Crisis Regime Detection
# ============================================================================

"""
    detect_crisis_regime(
        regime::Any,
        volatility_3x_baseline::Bool,
        α_lt_1_8::Bool,
        jump_intensity_gt_0_3::Bool,
        vix_vxv_gt_1_1::Bool
    ) -> Bool

Detect crisis regime using four criteria (any three of four).

# Criteria
1. Volatility > 3× baseline
2. Tail index α < 1.8 (extreme heavy tails)
3. Jump intensity λ > 0.3
4. VIX/VXV > 1.1 (backwardation)

# Returns
- `Bool`: True if crisis detected (≥3 criteria met)
"""
function detect_crisis_regime(
    regime::Any,
    volatility_3x_baseline::Bool,
    α_lt_1_8::Bool,
    jump_intensity_gt_0_3::Bool,
    vix_vxv_gt_1_1::Bool
)::Bool

    criteria_count = sum([
        volatility_3x_baseline,
        α_lt_1_8,
        jump_intensity_gt_0_3,
        vix_vxv_gt_1_1
    ])

    return criteria_count >= 3
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

"""
    _categorical_sample(probs::Vector{Float64}) -> Int

Sample from categorical distribution.
"""
function _categorical_sample(probs::Vector{Float64})::Int
    u = rand()
    cumsum = 0.0
    for (i, p) in enumerate(probs)
        cumsum += p
        if u <= cumsum
            return i
        end
    end
    return length(probs)
end

"""
    _systematic_resample(particles::Matrix{Int}, weights::Vector{Float64}, t::Int) -> Matrix{Int}

Systematic resampling for particle filter.
"""
function _systematic_resample(
    particles::Matrix{Int}, 
    weights::Vector{Float64}, 
    t::Int
)::Matrix{Int}
    N = length(weights)
    new_particles = copy(particles)

    positions = (collect(0:N-1) .+ rand()) ./ N
    cum_weights = cumsum(weights)

    j = 1
    for i in 1:N
        while positions[i] > cum_weights[j] && j < N
            j += 1
        end
        new_particles[i, 1:t] = particles[j, 1:t]
    end

    return new_particles
end

"""
    _regime_likelihood(return_val::Float64, atom::Any) -> Float64

Compute likelihood of return under regime model.

Handles both Dict atoms (initialization phase) and RegimeModel atoms (post-EM phase).
During initialization, atoms are Dicts with :μ and :σ² keys.
Post-EM, atoms are RegimeModels with full ARMA-GARCH parameters.
"""
function _regime_likelihood(return_val::Float64, atom::Any)::Float64
    if atom isa Dict
        # Initialization phase: atom is a Dict with :μ and :σ² keys
        σ² = get(atom, :σ², 0.01)
        μ  = get(atom, :μ, 0.0)
        σ  = sqrt(max(σ², 1e-8))
    else
        # Post-EM phase: atom is a RegimeModel struct
        # Use the ARMA mean and vol_scale as the regime distribution
        μ  = atom.arma_params.μ
        σ  = atom.vol_scale > 0 ? atom.vol_scale : sqrt(atom.arma_params.σ²)
        σ  = max(σ, 1e-8 / sqrt(252))  # Annualized → daily floor
    end
    return pdf(Normal(μ, σ), return_val)
end

"""
    _stick_breaking_weights(v::Vector{Float64}) -> Vector{Float64}

Convert stick-breaking proportions to weights.
"""
function _stick_breaking_weights(v::Vector{Float64})::Vector{Float64}
    K = length(v)
    weights = Float64[]
    remaining = 1.0

    for k in 1:K
        w = v[k] * remaining
        push!(weights, w)
        remaining *= (1 - v[k])
    end

    # Normalize
    weights ./= sum(weights)
    return weights
end

"""
    _random_regime_model()

Generate random regime model for initialization.
"""
function _random_regime_model()
    return Dict(
        :μ => randn() * 0.001,
        :σ² => 0.0001 + rand() * 0.01,
        :φ => [randn() * 0.1],
        :θ => [randn() * 0.1]
    )
end

"""
    _weighted_regime_update(returns::Vector{Float64}, weights::Vector{Float64}, current_atom::Any)

Update regime parameters using weighted observations.
"""
function _weighted_regime_update(returns::Vector{Float64}, weights::Vector{Float64}, current_atom::Any)
    # Simplified: update mean and variance only
    # In production: full weighted MLE for ARMA-GARCH

    w = weights ./ sum(weights)
    μ_new = sum(w .* returns)
    σ²_new = sum(w .* (returns .- μ_new).^2)
    σ²_new = max(1e-10, σ²_new)

    updated = copy(current_atom)
    updated[:μ] = μ_new
    updated[:σ²] = σ²_new

    return updated
end

"""
    _compute_loglikelihood(returns::Vector{Float64}, params::StickBreaking, regime_probs::Matrix{Float64}) -> Float64

Compute total log-likelihood.
"""
function _compute_loglikelihood(
    returns::Vector{Float64}, 
    params::StickBreaking, 
    regime_probs::Matrix{Float64}
)::Float64
    T = length(returns)
    ll = 0.0

    for t in 1:T
        for k in 1:length(params.weights)
            if regime_probs[t, k] > 1e-10
                lik = _regime_likelihood(returns[t], params.atoms[k])
                ll += regime_probs[t, k] * log(lik + 1e-300)
            end
        end
    end

    return ll
end

"""
    _collapse_components(weights::Vector{Float64}, atoms::Vector{Any}, γ::Float64) -> Vector{Float64}

Collapse small components and renormalize.
"""
function _collapse_components(weights::Vector{Float64}, atoms::Vector{Any}, γ::Float64)::Vector{Float64}
    threshold = 0.5 / (length(weights) + γ)

    new_weights = copy(weights)
    for i in eachindex(new_weights)
        if new_weights[i] < threshold
            new_weights[i] = 0.0
        end
    end

    if sum(new_weights) > 0
        new_weights ./= sum(new_weights)
    else
        new_weights .= 1.0 / length(new_weights)
    end

    return new_weights
end

end  # module DPM
