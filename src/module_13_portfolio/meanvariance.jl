# =============================================================================
# meanvariance.jl — Markowitz-family optimizers
#
# All solvers accept a covariance `Σ` (and where relevant expected returns `μ`)
# and return a weight vector summing to 1. Constraints supported across the
# family: long-only toggle, scalar/vector box bounds, and (for mean_variance)
# either a risk-aversion or a target-return formulation.
# =============================================================================

# Internal: build a JuMP model with budget + box + sign constraints already set.
function _base_model(N::Int; long_only::Bool, w_min, w_max, optimizer)
    model = Model(optimizer)
    set_silent(model)
    @variable(model, w[1:N])
    @constraint(model, sum(w) == 1)
    if long_only
        @constraint(model, w .>= 0)
    end
    if w_min !== nothing
        lo = w_min isa Number ? fill(float(w_min), N) : collect(w_min)
        @constraint(model, w .>= lo)
    end
    if w_max !== nothing
        hi = w_max isa Number ? fill(float(w_max), N) : collect(w_max)
        @constraint(model, w .<= hi)
    end
    return model, w
end

function _psd(Σ)
    A = Matrix(Σ)
    A = (A + A') / 2
    A[diagind(A)] .+= 1e-12                           # tiny ridge for solver robustness
    return A
end

_check(model) = is_solved_and_feasible(model) ||
    @warn "optimizer did not converge cleanly: status $(termination_status(model))"

"""
    min_variance(Σ; long_only=true, w_min=nothing, w_max=nothing,
                 optimizer=Clarabel.Optimizer) -> Vector

Global minimum-variance portfolio. With no constraints beyond the budget there
is a closed form (`Σ⁻¹𝟙 / 𝟙ᵀΣ⁻¹𝟙`); whenever any sign/box constraint is active
the QP path is used.
"""
function min_variance(Σ::AbstractMatrix; long_only::Bool = true,
                      w_min = nothing, w_max = nothing,
                      optimizer = Clarabel.Optimizer)
    N = size(Σ, 1)
    if !long_only && w_min === nothing && w_max === nothing
        ones_ = ones(N)
        z = Symmetric(_psd(Σ)) \ ones_
        return z ./ sum(z)
    end
    A = _psd(Σ)
    model, w = _base_model(N; long_only, w_min, w_max, optimizer)
    @objective(model, Min, w' * A * w)
    optimize!(model); _check(model)
    return value.(w)
end

"""
    max_sharpe(μ, Σ; rf=0.0, long_only=true, w_min=nothing, w_max=nothing,
               optimizer=Clarabel.Optimizer) -> Vector

Maximum-Sharpe (tangency) portfolio for excess returns `μ .- rf`. Solved by the
standard scale-free reformulation `min yᵀΣy s.t. (μ-rf)ᵀy = 1, y ≥ 0`, then
`w = y / Σyᵢ`. Requires at least one asset with positive excess return.
"""
function max_sharpe(μ::AbstractVector, Σ::AbstractMatrix; rf::Real = 0.0,
                    long_only::Bool = true, w_min = nothing, w_max = nothing,
                    optimizer = Clarabel.Optimizer)
    N = length(μ)
    maximum(μ .- rf) > 0 || error("no asset has positive excess return; tangency undefined")
    A = _psd(Σ)
    model = Model(optimizer); set_silent(model)
    @variable(model, y[1:N])
    long_only && @constraint(model, y .>= 0)
    @constraint(model, dot(μ .- rf, y) == 1)
    # box bounds apply to the normalized weights; encode as y bounds relative to Σy
    if w_min !== nothing || w_max !== nothing
        @variable(model, κ >= 1e-8)
        @constraint(model, sum(y) == κ)
        if w_min !== nothing
            lo = w_min isa Number ? fill(float(w_min), N) : collect(w_min)
            @constraint(model, y .>= lo .* κ)
        end
        if w_max !== nothing
            hi = w_max isa Number ? fill(float(w_max), N) : collect(w_max)
            @constraint(model, y .<= hi .* κ)
        end
    end
    @objective(model, Min, y' * A * y)
    optimize!(model); _check(model)
    yv = value.(y)
    return yv ./ sum(yv)
end

"""
    mean_variance(μ, Σ; risk_aversion=nothing, target_return=nothing,
                  long_only=true, w_min=nothing, w_max=nothing,
                  optimizer=Clarabel.Optimizer) -> Vector

General Markowitz optimizer. Provide exactly one of:

- `risk_aversion = λ`  → maximize `μᵀw − (λ/2) wᵀΣw`.
- `target_return = r`  → minimize `wᵀΣw` subject to `μᵀw ≥ r`.

If neither is given it reduces to the minimum-variance portfolio.
"""
function mean_variance(μ::AbstractVector, Σ::AbstractMatrix;
                       risk_aversion = nothing, target_return = nothing,
                       long_only::Bool = true, w_min = nothing, w_max = nothing,
                       optimizer = Clarabel.Optimizer)
    risk_aversion !== nothing && target_return !== nothing &&
        error("specify only one of `risk_aversion` or `target_return`")
    N = length(μ)
    A = _psd(Σ)
    model, w = _base_model(N; long_only, w_min, w_max, optimizer)
    if risk_aversion !== nothing
        @objective(model, Max, dot(μ, w) - (risk_aversion / 2) * (w' * A * w))
    elseif target_return !== nothing
        @constraint(model, dot(μ, w) >= target_return)
        @objective(model, Min, w' * A * w)
    else
        @objective(model, Min, w' * A * w)
    end
    optimize!(model); _check(model)
    return value.(w)
end

"""
    efficient_frontier(μ, Σ; n=25, kwargs...) -> NamedTuple

Trace `n` portfolios along the long-only (by default) efficient frontier between
the minimum-variance return and the maximum single-asset return. Returns
`(; returns, risks, weights)` where `weights` is an `N x n` matrix.
"""
function efficient_frontier(μ::AbstractVector, Σ::AbstractMatrix; n::Int = 25,
                            long_only::Bool = true, w_min = nothing, w_max = nothing,
                            optimizer = Clarabel.Optimizer)
    w_mv = min_variance(Σ; long_only, w_min, w_max, optimizer)
    r_lo = dot(μ, w_mv)
    r_hi = maximum(μ)
    targets = range(r_lo, r_hi; length = n)
    N = length(μ)
    W = zeros(N, n); rets = zeros(n); risks = zeros(n)
    for (k, r) in enumerate(targets)
        w = mean_variance(μ, Σ; target_return = r, long_only, w_min, w_max, optimizer)
        W[:, k] = w
        rets[k] = dot(μ, w)
        risks[k] = sqrt(max(dot(w, Symmetric(_psd(Σ)) * w), 0))
    end
    return (; returns = rets, risks = risks, weights = W)
end
