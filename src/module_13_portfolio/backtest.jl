# =============================================================================
# backtest.jl — walk-forward, periodically-rebalanced backtest
# =============================================================================

"""
    backtest(R, strategy; lookback=252, rebalance=21, cost_bps=0.0,
             warmup=lookback) -> NamedTuple

Walk forward through the `T x N` return matrix `R`. At each rebalance date the
trailing `lookback` window is handed to `strategy(window) -> weights`; those
weights are held until the next rebalance, and gross returns are debited a
proportional transaction cost of `cost_bps` basis points times turnover.

`strategy` is any function of a `lookback x N` return slice returning a length-`N`
weight vector — e.g. `w -> risk_parity(shrinkage_cov(w)[1])` or a closure that
also estimates `μ`. This keeps the estimator/optimizer choice fully pluggable.
A strategy may instead take two arguments `(window, w_current)` — the current
held weights — which is what cost-aware rebalancers need; the engine detects the
arity automatically.

Returns `(; returns, weights, dates, turnover)`:
- `returns`  — net periodic portfolio returns over the out-of-sample span.
- `weights`  — `N x (#rebalances)` matrix of target weights at each rebalance.
- `dates`    — row indices into `R` at which the corresponding return occurs.
- `turnover` — L1 turnover applied at each rebalance.
"""
function backtest(R::AbstractMatrix, strategy::Function;
                  lookback::Int = 252, rebalance::Int = 21,
                  cost_bps::Real = 0.0, warmup::Int = lookback)
    T, N = size(R)
    @assert warmup >= 1 "warmup must be ≥ 1"
    @assert warmup < T "not enough data for the requested warmup"

    port_ret = Float64[]
    dates = Int[]
    weight_hist = Vector{Vector{Float64}}()
    turnovers = Float64[]

    w_current = zeros(N)            # held weights, drift ignored between rebalances
    steps_since_rebal = rebalance   # force a rebalance on the first eligible day
    cost_rate = cost_bps / 10_000

    for t in (warmup + 1):T
        # ---- rebalance decision (uses data up to and including t-1) ----------
        if steps_since_rebal >= rebalance
            lo = max(1, t - lookback)
            window = @view R[lo:(t - 1), :]
            # cost-aware strategies may also take the current holdings
            w_target = applicable(strategy, window, w_current) ?
                       strategy(window, w_current) : strategy(window)
            turn = sum(abs.(w_target .- w_current))
            push!(turnovers, turn)
            push!(weight_hist, collect(w_target))
            # charge the rebalancing cost to this period's return
            cost = cost_rate * turn
            w_current = collect(w_target)
            steps_since_rebal = 0
        else
            cost = 0.0
        end

        # ---- realize period-t return on currently held weights ---------------
        gross = dot(w_current, @view R[t, :])
        push!(port_ret, gross - cost)
        push!(dates, t)
        steps_since_rebal += 1

        # weights drift with realized asset returns between rebalances
        grown = w_current .* (1 .+ @view R[t, :])
        s = sum(grown)
        if s != 0
            w_current = grown ./ s
        end
    end

    W = isempty(weight_hist) ? zeros(N, 0) : reduce(hcat, weight_hist)
    return (; returns = port_ret, weights = W, dates = dates, turnover = turnovers)
end

"""
    equal_weight(window) -> Vector

Convenience strategy: the 1/N portfolio. Handy as a benchmark in `backtest`.
"""
equal_weight(window::AbstractMatrix) = fill(1 / size(window, 2), size(window, 2))
