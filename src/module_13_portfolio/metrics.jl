# =============================================================================
# metrics.jl — performance and risk diagnostics for a return series
#
# `r` is a vector of periodic portfolio returns; `ppy` is periods per year
# (252 daily, 52 weekly, 12 monthly). Risk-free `rf` is quoted annually.
# =============================================================================

"""
    ann_return(r; ppy=252, geometric=true) -> Float64

Annualized return. Geometric (CAGR) by default; set `geometric=false` for the
arithmetic-mean annualization.
"""
function ann_return(r::AbstractVector; ppy::Int = 252, geometric::Bool = true)
    if geometric
        return prod(1 .+ r)^(ppy / length(r)) - 1
    else
        return mean(r) * ppy
    end
end

"""Annualized volatility of periodic returns."""
ann_vol(r::AbstractVector; ppy::Int = 252) = std(r) * sqrt(ppy)

"""
    sharpe(r; rf=0.0, ppy=252) -> Float64

Annualized Sharpe ratio using geometric annualized return in the numerator.
"""
function sharpe(r::AbstractVector; rf::Real = 0.0, ppy::Int = 252)
    return (ann_return(r; ppy) - rf) / ann_vol(r; ppy)
end

"""
    sortino(r; rf=0.0, ppy=252, mar=0.0) -> Float64

Annualized Sortino ratio. Downside deviation is measured against the per-period
minimum acceptable return `mar`.
"""
function sortino(r::AbstractVector; rf::Real = 0.0, ppy::Int = 252, mar::Real = 0.0)
    downside = min.(r .- mar, 0)
    dd = sqrt(mean(downside .^ 2)) * sqrt(ppy)
    return (ann_return(r; ppy) - rf) / dd
end

"""
    drawdown_series(r) -> Vector

Drawdown at each point relative to the running peak of compounded wealth.
Values are ≤ 0.
"""
function drawdown_series(r::AbstractVector)
    wealth = cumprod(1 .+ r)
    peak = accumulate(max, wealth)
    return wealth ./ peak .- 1
end

"""Maximum drawdown (a negative number)."""
max_drawdown(r::AbstractVector) = minimum(drawdown_series(r))

"""
    calmar(r; ppy=252) -> Float64

Calmar ratio: annualized return divided by the absolute maximum drawdown.
"""
function calmar(r::AbstractVector; ppy::Int = 252)
    mdd = abs(max_drawdown(r))
    return mdd == 0 ? Inf : ann_return(r; ppy) / mdd
end

# ---- Tail risk on the realized series ---------------------------------------

"""
    value_at_risk(r; α=0.95, method=:historical) -> Float64

Value-at-Risk reported as a positive loss number.

- `:historical`     — empirical `α` quantile of losses.
- `:gaussian`       — `−(μ + zₐ σ)` under normality.
- `:cornish_fisher` — Gaussian VaR with a skew/kurtosis adjustment to `zₐ`.
"""
function value_at_risk(r::AbstractVector; α::Real = 0.95, method::Symbol = :historical)
    if method === :historical
        return -quantile(r, 1 - α)
    elseif method === :gaussian
        z = quantile(Normal(), 1 - α)
        return -(mean(r) + z * std(r))
    elseif method === :cornish_fisher
        μ, σ = mean(r), std(r)
        s = skewness(r); k = kurtosis(r)              # `kurtosis` is excess kurtosis
        z = quantile(Normal(), 1 - α)
        zcf = z + (z^2 - 1) * s / 6 + (z^3 - 3z) * k / 24 -
              (2z^3 - 5z) * s^2 / 36
        return -(μ + zcf * σ)
    else
        error("unknown VaR method $method")
    end
end

"""
    expected_shortfall(r; α=0.95) -> Float64

Historical Conditional VaR / Expected Shortfall: the mean loss in the worst
`1−α` tail, reported as a positive number.
"""
function expected_shortfall(r::AbstractVector; α::Real = 0.95)
    q = quantile(r, 1 - α)
    tail = r[r .<= q]
    return isempty(tail) ? -q : -mean(tail)
end

"""
    summary_stats(r; rf=0.0, ppy=252, α=0.95) -> NamedTuple

One-shot diagnostics bundle for a return series.
"""
function summary_stats(r::AbstractVector; rf::Real = 0.0, ppy::Int = 252, α::Real = 0.95)
    return (; ann_return = ann_return(r; ppy),
              ann_vol     = ann_vol(r; ppy),
              sharpe      = sharpe(r; rf, ppy),
              sortino     = sortino(r; rf, ppy),
              max_dd      = max_drawdown(r),
              calmar      = calmar(r; ppy),
              var         = value_at_risk(r; α),
              cvar        = expected_shortfall(r; α))
end
