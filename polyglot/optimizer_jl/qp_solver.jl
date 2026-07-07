#=
blaque_baux/optimizer_jl/qp_solver.jl
──────────────────────────────────────
Portfolio optimizer using JuMP + Clarabel.

Replaces qp_solver.py (CVXPY) with identical problem formulation:

    minimize    w' Σ w  +  λ_turn ‖w - w_prev‖₁  +  λ_oracle ‖w - w_oracle‖²
    subject to:
        Σ w_long   = long_ratio
        Σ w_short  = -short_ratio
        w_long  ∈ [min_wt, max_wt]
        w_short ∈ [-max_wt, -min_wt]
        μ' w ≥ target_return - 2 × exec_drag
        μ' w ≥ -sVaR  (if sVaR constraint provided)

JuMP advantages over CVXPY:
  - Clarabel runs natively (no Python→C→Python round-trip)
  - JuMP's constraint DSL is more expressive for adding lane variants
  - Julia's JIT compiles the model construction itself, not just the solve
  - Efficient frontier loop amortizes model construction across solves

Called from Python via juliacall:
    from juliacall import Main as jl
    jl.include("optimizer_jl/qp_solver.jl")
    weights, meta = jl.optimize_portfolio(factor_scores, returns_hist, ...)
=#

module QPSolver

using JuMP
using Clarabel
using LinearAlgebra
using Statistics

export optimize_portfolio, compute_efficient_frontier, ewma_covariance

# ── Configuration (mirrors config.OptimizerConfig) ───────────────────────────

Base.@kwdef struct OptimizerConfig
    long_ratio::Float64      = 0.50
    max_position_wt::Float64 = 0.08
    min_position_wt::Float64 = 0.01
    target_return::Float64   = 0.008
    turnover_penalty::Float64 = 0.0005
    risk_aversion::Float64   = 0.5
    execution_drag::Float64  = 0.0008
end

const DEFAULT_CONFIG = OptimizerConfig()


# ── EWMA Covariance ──────────────────────────────────────────────────────────

"""
    ewma_covariance(returns; λ=0.94, min_periods=20)

RiskMetrics EWMA covariance matrix. λ=0.94 for 15-min bars.
Returns (n×n) positive semi-definite matrix.
"""
function ewma_covariance(returns::Matrix{Float64}; λ::Float64=0.94, min_periods::Int=20)
    T, n = size(returns)

    if T < min_periods
        # Diagonal fallback
        return Diagonal(vec(var(returns, dims=1)))
    end

    # EWMA weights (most recent = highest weight)
    α = 1.0 - λ
    weights = [α * λ^(T - t) for t in 1:T]
    weights ./= sum(weights)

    # Weighted covariance
    μ = vec(sum(returns .* weights, dims=1))
    centered = returns .- μ'
    Σ = zeros(n, n)
    @inbounds for t in 1:T
        x = @view centered[t, :]
        Σ .+= weights[t] .* (x * x')
    end

    # Ensure PSD (clip negative eigenvalues)
    return ensure_psd(Σ)
end

function ensure_psd(M::Matrix{Float64}; ε::Float64=1e-6)
    F = eigen(Symmetric(M))
    vals = max.(F.values, ε)
    return F.vectors * Diagonal(vals) * F.vectors'
end


# ── Risk parameters (from risk_engine.py) ────────────────────────────────────

Base.@kwdef struct RiskParams
    long_ratio::Float64       = 0.50
    short_ratio::Float64      = 0.50
    var_constraint::Union{Float64, Nothing}  = nothing
    svar_constraint::Union{Float64, Nothing} = nothing
    position_scalar::Float64  = 1.0
    trend_label::String       = "neutral"
    trend_strength::Float64   = 0.0
end


# ── Main optimizer ───────────────────────────────────────────────────────────

"""
    optimize_portfolio(factor_scores, returns_history, long_idx, short_idx; kwargs...)

Main QP solve for one 15-minute window.

# Arguments
- `factor_scores::Vector{Float64}`: expected relative returns per asset
- `returns_history::Matrix{Float64}`: (T × n_total) returns for covariance
- `long_idx::Vector{Int}`: indices of long candidates (1-based)
- `short_idx::Vector{Int}`: indices of short candidates (1-based)
- `prev_weights::Vector{Float64}`: previous window's weights (for turnover)
- `borrow_costs::Vector{Float64}`: annualized borrow cost per asset
- `risk_params::RiskParams`: VaR/sVaR constraints from risk engine
- `oracle_prior::Union{Nothing, Vector{Float64}}`: L4 oracle weights
- `oracle_blend::Float64`: oracle regularization coefficient
- `cfg::OptimizerConfig`: optimizer hyperparameters

# Returns
- `weights::Vector{Float64}`: optimal weights (positive=long, negative=short)
- `meta::Dict{String,Any}`: diagnostics
"""
function optimize_portfolio(
    factor_scores::Vector{Float64},
    returns_history::Matrix{Float64},
    long_idx::Vector{Int},
    short_idx::Vector{Int};
    prev_weights::Union{Nothing, Vector{Float64}} = nothing,
    borrow_costs::Union{Nothing, Vector{Float64}} = nothing,
    risk_params::RiskParams = RiskParams(),
    oracle_prior::Union{Nothing, Vector{Float64}} = nothing,
    oracle_blend::Float64 = 0.0,
    cfg::OptimizerConfig = DEFAULT_CONFIG,
)
    n_long  = length(long_idx)
    n_short = length(short_idx)
    n_total = n_long + n_short
    all_idx = vcat(long_idx, short_idx)

    if n_total < 4
        return equal_weight_fallback(n_long, n_short, cfg),
               Dict{String,Any}("status" => "fallback")
    end

    # ── Expected returns ─────────────────────────────────────────────────
    μ = factor_scores[all_idx] .* cfg.target_return

    # Adjust for borrow costs on short positions
    if borrow_costs !== nothing
        for (i, idx) in enumerate(short_idx)
            local_i = n_long + i
            cost_per_window = borrow_costs[idx] / (252 * 26)
            μ[local_i] -= cost_per_window
        end
    end

    # ── Covariance matrix ────────────────────────────────────────────────
    Σ = ewma_covariance(returns_history[:, all_idx])

    # ── Dynamic L/S ratio ────────────────────────────────────────────────
    lr = risk_params.long_ratio
    sr = risk_params.short_ratio

    # ── Build JuMP model ─────────────────────────────────────────────────
    model = Model(Clarabel.Optimizer)
    set_silent(model)
    set_optimizer_attribute(model, "max_iter", 200)

    @variable(model, w[1:n_total])

    # ── Objective: risk_aversion × w'Σw + turnover + oracle prior ────────
    @objective(model, Min,
        cfg.risk_aversion * w' * Σ * w
    )

    # Turnover penalty (L1 via auxiliary variables)
    if prev_weights !== nothing
        w_prev = prev_weights[all_idx]
        @variable(model, t_abs[1:n_total] >= 0)
        @constraint(model, [i=1:n_total],  w[i] - w_prev[i] <= t_abs[i])
        @constraint(model, [i=1:n_total], -w[i] + w_prev[i] <= t_abs[i])

        # Add to objective
        set_objective_function(model,
            objective_function(model) + cfg.turnover_penalty * sum(t_abs)
        )
    end

    # Oracle prior: L2 regularization toward oracle weights (L4 lane)
    if oracle_prior !== nothing && oracle_blend > 0
        w_oracle = oracle_prior[all_idx]
        set_objective_function(model,
            objective_function(model) + oracle_blend * sum((w[i] - w_oracle[i])^2 for i in 1:n_total)
        )
    end

    # ── Constraints ──────────────────────────────────────────────────────

    # Long book: sum to long_ratio, bounded per position
    @constraint(model, sum(w[1:n_long]) == lr)
    @constraint(model, [i=1:n_long], w[i] >= cfg.min_position_wt)
    @constraint(model, [i=1:n_long], w[i] <= cfg.max_position_wt)

    # Short book: sum to -short_ratio, bounded per position
    @constraint(model, sum(w[n_long+1:n_total]) == -sr)
    @constraint(model, [i=n_long+1:n_total], w[i] <= -cfg.min_position_wt)
    @constraint(model, [i=n_long+1:n_total], w[i] >= -cfg.max_position_wt)

    # Minimum expected return
    @constraint(model, μ' * w >= cfg.target_return - 2 * cfg.execution_drag)

    # sVaR constraint (from risk engine)
    if risk_params.svar_constraint !== nothing
        svar = risk_params.svar_constraint
        if svar > 0 && !isnan(svar)
            @constraint(model, μ' * w >= -svar)
        end
    end

    # ── Solve ────────────────────────────────────────────────────────────
    t0 = time()
    optimize!(model)
    solve_ms = (time() - t0) * 1000

    status = string(termination_status(model))

    if !(termination_status(model) in [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
        return equal_weight_fallback(n_long, n_short, cfg),
               Dict{String,Any}(
                   "status" => status,
                   "solve_ms" => solve_ms,
                   "long_ratio" => lr,
                   "short_ratio" => sr,
               )
    end

    # ── Package results ──────────────────────────────────────────────────
    w_val = value.(w)

    # Clean up noise
    for i in 1:n_total
        if abs(w_val[i]) < cfg.min_position_wt * 0.5
            w_val[i] = 0.0
        end
    end

    # Diagnostics
    exp_ret = μ' * w_val
    exp_vol = sqrt(max(w_val' * Σ * w_val, 0.0))

    meta = Dict{String,Any}(
        "status"          => status,
        "solve_ms"        => solve_ms,
        "expected_return" => exp_ret,
        "expected_vol"    => exp_vol,
        "sharpe_est"      => exp_ret / max(exp_vol, 1e-8),
        "n_long"          => count(x -> x > 0, w_val),
        "n_short"         => count(x -> x < 0, w_val),
        "long_ratio"      => lr,
        "short_ratio"     => sr,
        "var_constraint"  => risk_params.var_constraint,
        "svar_constraint" => risk_params.svar_constraint,
        "trend_label"     => risk_params.trend_label,
        "trend_strength"  => risk_params.trend_strength,
        "position_scalar" => risk_params.position_scalar,
        "oracle_active"   => oracle_prior !== nothing,
    )

    return w_val, meta
end


# ── Efficient frontier ───────────────────────────────────────────────────────

"""
    compute_efficient_frontier(factor_scores, returns_history, long_idx, short_idx;
                               confidence_levels=[0.90,0.93,0.95,0.97,0.98,0.99])

Trace the efficient frontier at multiple target return levels.
Exactly the Solver multi-confidence workflow.

Returns Vector of (confidence, target_return, achieved_return, achieved_vol, sharpe, status).
"""
function compute_efficient_frontier(
    factor_scores::Vector{Float64},
    returns_history::Matrix{Float64},
    long_idx::Vector{Int},
    short_idx::Vector{Int};
    confidence_levels::Vector{Float64} = [0.90, 0.93, 0.95, 0.97, 0.98, 0.99],
    cfg::OptimizerConfig = DEFAULT_CONFIG,
)
    results = Vector{Dict{String,Any}}()

    for conf in confidence_levels
        # Scale target return by confidence
        max_achievable = maximum(factor_scores[vcat(long_idx, short_idx)])
        target = max_achievable * conf

        local_cfg = OptimizerConfig(
            long_ratio      = cfg.long_ratio,
            max_position_wt = cfg.max_position_wt,
            min_position_wt = cfg.min_position_wt,
            target_return   = target,
            turnover_penalty = cfg.turnover_penalty,
            risk_aversion   = cfg.risk_aversion,
            execution_drag  = cfg.execution_drag,
        )

        _, meta = optimize_portfolio(
            factor_scores, returns_history,
            long_idx, short_idx;
            cfg=local_cfg,
        )

        push!(results, Dict{String,Any}(
            "confidence"      => conf,
            "target_return"   => target,
            "achieved_return" => get(meta, "expected_return", 0.0),
            "achieved_vol"    => get(meta, "expected_vol", 0.0),
            "sharpe"          => get(meta, "sharpe_est", 0.0),
            "status"          => get(meta, "status", "unknown"),
        ))
    end

    return results
end


# ── Equal weight fallback ────────────────────────────────────────────────────

function equal_weight_fallback(n_long::Int, n_short::Int, cfg::OptimizerConfig)
    n_total = n_long + n_short
    w = zeros(n_total)
    if n_long > 0
        w[1:n_long] .= cfg.long_ratio / n_long
    end
    if n_short > 0
        w[n_long+1:end] .= -(1.0 - cfg.long_ratio) / n_short
    end
    return w
end

end # module QPSolver
