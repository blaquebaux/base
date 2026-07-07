# ============================================================================
# WEIGHTED M-STEP — Full ARMA+GARCH Re-estimation
# Source: Deepseek v2, integrated with fixes (May 2026)
# Replaces the stub _weighted_regime_update in module_5_dpm.jl
# ============================================================================
# Integration note: place these functions inside module DPM, after the
# existing mstep_update function. They require ARMAGARCH module functions:
# _compute_innovations (from module_4_arma) — aliased as _compute_arma_residuals below.

"""
    _compute_arma_residuals(returns, μ, φ, θ) -> Vector{Float64}

Cross-module alias for ARMAGARCH._compute_innovations.
Avoids circular import by duplicating the lightweight residual computation.
"""
function _compute_arma_residuals(
    returns::Vector{Float64},
    μ::Float64,
    φ::Vector{Float64},
    θ::Vector{Float64}
)::Vector{Float64}
    T = length(returns)
    ε = zeros(T)
    for t in 1:T
        ar = sum(i <= length(φ) && t-i > 0 ? φ[i]*returns[t-i] : 0.0 for i in 1:max(1,length(φ)))
        ma = sum(j <= length(θ) && t-j > 0 ? θ[j]*ε[t-j]  : 0.0 for j in 1:max(1,length(θ)))
        ε[t] = returns[t] - μ - ar - ma
    end
    return ε
end

"""
    _compute_garch_variance(ε, ω, α₁, β₁, γ) -> Vector{Float64}

Compute GARCH(1,1) conditional variance series from innovations.
γ is the jump coefficient (typically 0.0 unless jump occurred).
"""
function _compute_garch_variance(
    ε::Vector{Float64},
    ω::Float64, α₁::Float64, β₁::Float64, γ::Float64=0.0
)::Vector{Float64}
    T = length(ε)
    # Guard stationarity
    α₁ = clamp(α₁, 0.0, 0.49)
    β₁ = clamp(β₁, 0.0, min(0.989, 0.999 - α₁))
    unconditional = ω / max(1e-8, 1.0 - α₁ - β₁)
    σ² = fill(unconditional, T)
    for t in 2:T
        σ²[t] = ω + α₁ * ε[t-1]^2 + β₁ * σ²[t-1]
        σ²[t] = max(σ²[t], 1e-8)
    end
    return σ²
end

"""
    _weighted_realized_variance(returns, weights, window) -> Float64

Weighted rolling realized variance for Floating regime M-step.
"""
function _weighted_realized_variance(
    returns::Vector{Float64},
    weights::Vector{Float64},
    window::Int=10
)::Float64
    n = length(returns)
    variances = Float64[]
    var_weights = Float64[]

    for t in window:n
        wr = @view returns[t-window+1:t]
        ww = @view weights[t-window+1:t]
        sw = sum(ww)
        sw < 1e-12 && continue
        nw = ww ./ sw
        μw = sum(nw .* wr)
        v  = sum(nw .* (wr .- μw).^2)
        push!(variances, v)
        push!(var_weights, weights[t])
    end

    isempty(variances) && return var(returns)
    sw = sum(var_weights)
    sw < 1e-12 && return mean(variances)
    return sum(var_weights .* variances) / sw
end

"""
    _get_baseline_volatility(current_atoms) -> Float64

Returns the Fixed ARMA regime volatility (minimum vol among GARCH-enabled regimes)
to use as σ_baseline for tail index calculation. Falls back to 0.02 if no Fixed regime.
"""
function _get_baseline_volatility(current_atoms::Vector{Any})::Float64
    min_vol = Inf
    for atom in current_atoms
        if atom isa RegimeModel && !isnothing(atom.garch_params)
            min_vol = min(min_vol, atom.vol_scale)
        end
    end
    return min_vol == Inf ? 0.02 : max(1e-4, min_vol)
end

"""
    _estimate_weighted_armagarch(returns, weights, spec, use_garch, initial_params)

Weighted QMLE for ARMA+GARCH. Each observation contributes weights[t] to log-likelihood.
Called by _weighted_regime_update for Fixed and Growth regimes.
"""
function _estimate_weighted_armagarch(
    returns::Vector{Float64},
    weights::Vector{Float64},
    spec::ARMASpec,
    use_garch::Bool,
    initial_params::Tuple{ARMAParams, Union{Nothing,GARCHParams}}
)::Tuple{ARMAParams, Union{Nothing,GARCHParams}, Float64}

    p, q = spec.p, spec.q
    init_arma, init_garch = initial_params

    # Build initial θ vector: [μ, φ..., θ..., log(σ²), [log(ω), logit(α), logit(β), γ]]
    θ0 = Float64[init_arma.μ]
    p > 0 && append!(θ0, init_arma.φ)
    q > 0 && append!(θ0, init_arma.θ)
    push!(θ0, log(max(init_arma.σ², 1e-8)))
    if use_garch && !isnothing(init_garch)
        push!(θ0, log(max(init_garch.ω, 1e-10)))
        push!(θ0, _logit_safe(init_garch.α₁))
        push!(θ0, _logit_safe(init_garch.β₁))
    end

    function neg_wll(θ)
        idx = 1
        μ  = θ[idx]; idx += 1
        φ  = p > 0 ? θ[idx:idx+p-1] : Float64[]; idx += p
        ma = q > 0 ? θ[idx:idx+q-1] : Float64[]; idx += q
        σ² = exp(θ[idx]); idx += 1

        ε = _compute_arma_residuals(returns, μ, φ, ma)

        if use_garch && length(θ) >= idx + 1
            ω  = exp(θ[idx])
            α₁ = _sigmoid_safe(θ[idx+1])
            β₁ = _sigmoid_safe(θ[idx+2]) * (1.0 - α₁ - 1e-6)  # enforce α+β < 1
            gσ² = _compute_garch_variance(ε, ω, α₁, β₁)
            ll = -0.5 * sum(weights .* (log.(2π .* gσ²) .+ ε.^2 ./ gσ²))
        else
            ll = -0.5 * sum(weights .* (log(2π * σ²) .+ ε.^2 ./ σ²))
        end
        return isfinite(ll) ? -ll : 1e12
    end

    result = optimize(neg_wll, θ0, BFGS(), Optim.Options(iterations=300, show_trace=false))
    θ_opt = Optim.minimizer(result)

    idx = 1
    μ_opt = θ_opt[idx]; idx += 1
    φ_opt = p > 0 ? θ_opt[idx:idx+p-1] : Float64[]; idx += p
    θ_opt_ma = q > 0 ? θ_opt[idx:idx+q-1] : Float64[]; idx += q
    σ²_opt = exp(θ_opt[idx]); idx += 1

    garch_out = nothing
    if use_garch && length(θ_opt) >= idx + 1
        ω_opt  = exp(θ_opt[idx])
        α₁_opt = _sigmoid_safe(θ_opt[idx+1])
        β₁_opt = _sigmoid_safe(θ_opt[idx+2]) * (1.0 - α₁_opt - 1e-6)
        garch_out = GARCHParams(ω_opt, α₁_opt, β₁_opt, 0.0)
        # Update σ²_opt from GARCH unconditional
        σ²_opt = ω_opt / max(1e-8, 1.0 - α₁_opt - β₁_opt)
    end

    arma_out = ARMAParams(μ_opt, φ_opt, θ_opt_ma, σ²_opt)
    return arma_out, garch_out, -Optim.minimum(result)
end

# Safe sigmoid/logit helpers for constrained optimization
_sigmoid_safe(x::Float64) = 1.0 / (1.0 + exp(-clamp(x, -50.0, 50.0)))
_logit_safe(x::Float64)   = log(clamp(x, 1e-6, 1.0 - 1e-6) / (1.0 - clamp(x, 1e-6, 1.0 - 1e-6)))

"""
    _weighted_regime_update(returns, regime_probs, current_atoms, config)

Full weighted M-step. Replaces stub in module_5_dpm.jl.
Re-estimates ARMA+GARCH per regime using observation weights from E-step.
"""
function _weighted_regime_update(
    returns::Vector{Float64},
    regime_probs::Matrix{Float64},
    current_atoms::Vector{Any},
    config::DPMConfig
)::Vector{Any}

    n_obs, n_components = size(regime_probs)
    updated = Vector{Any}(undef, n_components)

    for k in 1:n_components
        weights = regime_probs[:, k]
        effective_n = sum(weights)

        if effective_n < 1.0
            @warn "Regime $k effective weight $(round(effective_n, digits=3)) < 1.0 — keeping parameters"
            updated[k] = current_atoms[k]
            continue
        end

        atom = current_atoms[k]
        norm_weights = weights ./ effective_n

        if atom isa RegimeModel
            use_garch = !isnothing(atom.garch_params)
            σ_baseline = _get_baseline_volatility(current_atoms)

            if !use_garch
                # Floating regime: weighted mean + realized vol
                μ_new = sum(norm_weights .* returns)
                σ²_new = _weighted_realized_variance(returns, weights)
                σ²_new = max(σ²_new, 1e-8)
                new_arma = ARMAParams(μ_new, Float64[], Float64[], σ²_new)
                σ_regime = sqrt(σ²_new)
                new_α = clamp(tail_index_from_vol_scale(σ_regime, σ_baseline), 1.5, 4.0)
                updated[k] = RegimeModel(atom.arma_spec, new_arma, nothing, new_α, nothing, σ_regime)
            else
                # Fixed/Growth: full weighted ARMA+GARCH QMLE
                new_arma, new_garch, _ = _estimate_weighted_armagarch(
                    returns, norm_weights, atom.arma_spec, true, (atom.arma_params, atom.garch_params)
                )
                σ_regime = sqrt(new_arma.σ²)
                new_α = clamp(tail_index_from_vol_scale(σ_regime, σ_baseline), 1.5, 4.0)
                new_ν = new_α > 2.0 ? dof_from_tail_index(new_α) : nothing
                updated[k] = RegimeModel(atom.arma_spec, new_arma, new_garch, new_α, new_ν, σ_regime)
            end
        else
            # Dict atom (initialization phase) — update mean and variance only
            w = norm_weights
            μ_new  = sum(w .* returns)
            σ²_new = max(sum(w .* (returns .- μ_new).^2), 1e-8)
            d = copy(atom)
            d[:μ] = μ_new
            d[:σ²] = σ²_new
            d[:σ]  = sqrt(σ²_new)
            updated[k] = d
        end
    end

    return updated
end
