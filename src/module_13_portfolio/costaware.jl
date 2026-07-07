# =============================================================================
# costaware.jl — optimization that accounts for the cost of getting there
#
# These take the *current* holdings `w0` and decide what to trade to, so the
# transaction cost actually shapes the solution instead of only being measured
# afterward. Uses the `_base_model` / `_psd` / `_check` helpers from
# meanvariance.jl (included earlier in the module).
# =============================================================================

"""
    turnover(w, w0) -> Float64

L1 turnover (one-way Σ|wᵢ − w0ᵢ|) between target and current weights.
"""
turnover(w::AbstractVector, w0::AbstractVector) = sum(abs.(w .- w0))

"""
    transaction_cost(w, w0; linear_cost=0.0, impact_cost=0.0) -> Float64

Realized trading cost of moving `w0 → w`: a proportional component
`linear_cost · Σ|Δ|` (e.g. spread/commission, as a fraction of traded notional)
plus a convex market-impact component `impact_cost · ΣΔ²`.
"""
function transaction_cost(w::AbstractVector, w0::AbstractVector;
                          linear_cost::Real = 0.0, impact_cost::Real = 0.0)
    Δ = w .- w0
    return linear_cost * sum(abs.(Δ)) + impact_cost * sum(Δ .^ 2)
end

"""
    mean_variance_tc(μ, Σ, w0; risk_aversion, linear_cost=0.0, impact_cost=0.0,
                     max_turnover=nothing, long_only=true, w_min=nothing,
                     w_max=nothing, optimizer=Clarabel.Optimizer) -> Vector

Cost-aware mean–variance rebalance. Maximizes net utility

    μᵀw − (λ/2) wᵀΣw − linear_cost·Σ|w−w0| − impact_cost·Σ(w−w0)²

optionally subject to `Σ|w−w0| ≤ max_turnover`. Because the costs enter the same
objective as expected return, they trade off correctly: a marginal expected-return
pickup is only taken if it clears the marginal cost of trading into it. The L1
term is linearized with auxiliary variables, so the program stays a convex QP.

`risk_aversion` (λ) is required — costs are denominated in return units, which is
the coherent place for them. To impose a turnover budget on a *target-return*
problem instead, set `max_turnover` here with a large `λ`, or add a turnover
constraint to a plain `mean_variance` call.
"""
function mean_variance_tc(μ::AbstractVector, Σ::AbstractMatrix, w0::AbstractVector;
                          risk_aversion::Real, linear_cost::Real = 0.0,
                          impact_cost::Real = 0.0, max_turnover = nothing,
                          long_only::Bool = true, w_min = nothing, w_max = nothing,
                          optimizer = Clarabel.Optimizer)
    N = length(μ)
    A = _psd(Σ)
    model, w = _base_model(N; long_only, w_min, w_max, optimizer)
    @variable(model, tdev[1:N] >= 0)                  # |wᵢ − w0ᵢ|
    @constraint(model, tdev .>= w .- w0)
    @constraint(model, tdev .>= w0 .- w)
    max_turnover !== nothing && @constraint(model, sum(tdev) <= max_turnover)

    util = dot(μ, w) - (risk_aversion / 2) * (w' * A * w) - linear_cost * sum(tdev)
    if impact_cost != 0
        util = util - impact_cost * sum((w[i] - w0[i])^2 for i in 1:N)
    end
    @objective(model, Max, util)
    optimize!(model); _check(model)
    return value.(w)
end
