# =============================================================================
# tailrisk.jl — optimizers that target tail risk directly from the return scenarios
#
# These work on the empirical return matrix `R` (T x N) rather than on summary
# moments, which is the point: they shape the realized loss distribution instead
# of a Gaussian proxy.
# =============================================================================

"""
    min_cvar(R; α=0.95, μ=nothing, target_return=nothing, long_only=true,
             w_min=nothing, w_max=nothing, optimizer=Clarabel.Optimizer) -> Vector

Minimum Conditional-Value-at-Risk portfolio using the Rockafellar–Uryasev linear
program. CVaR at level `α` (the mean loss in the worst `1−α` tail) is

    minimize  ζ + (1/((1−α)T)) Σₜ uₜ
    s.t.      uₜ ≥ −Rₜ·w − ζ,  uₜ ≥ 0,  Σ wᵢ = 1,  (+ optional μᵀw ≥ target).

Everything is linear, so this stays an LP regardless of the number of scenarios.
Pass `μ` together with `target_return` to impose a return floor.
"""
function min_cvar(R::AbstractMatrix; α::Real = 0.95, μ = nothing,
                  target_return = nothing, long_only::Bool = true,
                  w_min = nothing, w_max = nothing, optimizer = Clarabel.Optimizer)
    T, N = size(R)
    model, w = _base_model(N; long_only, w_min, w_max, optimizer)
    @variable(model, ζ)
    @variable(model, u[1:T] >= 0)
    @constraint(model, [t = 1:T], u[t] >= -dot(R[t, :], w) - ζ)
    if target_return !== nothing
        μ === nothing && error("supply `μ` to use `target_return`")
        @constraint(model, dot(μ, w) >= target_return)
    end
    @objective(model, Min, ζ + sum(u) / ((1 - α) * T))
    optimize!(model); _check(model)
    return value.(w)
end

"""
    min_cdar(R; α=0.95, μ=nothing, target_return=nothing, long_only=true,
             w_min=nothing, w_max=nothing, optimizer=Clarabel.Optimizer) -> Vector

Minimum Conditional-Drawdown-at-Risk portfolio (Chekhlov–Uryasev–Zabarankin).
Built on the *uncompounded* cumulative wealth path `yₜ = Σ_{s≤t} Rₛ·w`; an
auxiliary running-peak series and the same CVaR LP trick bound the average of the
worst `1−α` drawdowns. Linear program in `(w, ζ, peaks, slacks)`.
"""
function min_cdar(R::AbstractMatrix; α::Real = 0.95, μ = nothing,
                  target_return = nothing, long_only::Bool = true,
                  w_min = nothing, w_max = nothing, optimizer = Clarabel.Optimizer)
    T, N = size(R)
    model, w = _base_model(N; long_only, w_min, w_max, optimizer)
    @variable(model, y[1:T])                          # cumulative portfolio return
    @constraint(model, y[1] == dot(R[1, :], w))
    @constraint(model, [t = 2:T], y[t] == y[t-1] + dot(R[t, :], w))
    @variable(model, peak[1:T])                       # running maximum (envelope)
    @constraint(model, [t = 1:T], peak[t] >= y[t])
    @constraint(model, [t = 2:T], peak[t] >= peak[t-1])
    @constraint(model, peak[1] >= 0)
    @variable(model, ζ)
    @variable(model, z[1:T] >= 0)                     # tail slacks on drawdowns
    @constraint(model, [t = 1:T], z[t] >= (peak[t] - y[t]) - ζ)
    if target_return !== nothing
        μ === nothing && error("supply `μ` to use `target_return`")
        @constraint(model, dot(μ, w) >= target_return)
    end
    @objective(model, Min, ζ + sum(z) / ((1 - α) * T))
    optimize!(model); _check(model)
    return value.(w)
end
