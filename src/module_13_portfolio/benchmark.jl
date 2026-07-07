# =============================================================================
# benchmark.jl — benchmark-relative (active) risk and return analytics
#
# All series are periodic returns; `rb` is the benchmark's return series of the
# same length. `rf` is an annual risk-free rate, converted to per-period as
# `rf/ppy`.
# =============================================================================

"""
    capm_alpha_beta(r, rb; rf=0.0, ppy=252) -> NamedTuple

OLS market model of asset/portfolio excess returns on benchmark excess returns.
Returns `(; alpha, beta, r2)` with `alpha` annualized (`α_period · ppy`).
"""
function capm_alpha_beta(r::AbstractVector, rb::AbstractVector; rf::Real = 0.0, ppy::Int = 252)
    rfp = rf / ppy
    ra, rbe = r .- rfp, rb .- rfp
    β = cov(ra, rbe) / var(rbe)
    α = mean(ra) - β * mean(rbe)
    return (; alpha = α * ppy, beta = β, r2 = cor(r, rb)^2)
end

"""Annualized tracking error: volatility of the active return `r − rb`."""
tracking_error(r::AbstractVector, rb::AbstractVector; ppy::Int = 252) =
    std(r .- rb) * sqrt(ppy)

"""
    information_ratio(r, rb; ppy=252) -> Float64

Annualized information ratio: mean active return divided by tracking error.
"""
function information_ratio(r::AbstractVector, rb::AbstractVector; ppy::Int = 252)
    a = r .- rb
    return mean(a) / std(a) * sqrt(ppy)
end

"""
    treynor_ratio(r, rb; rf=0.0, ppy=252) -> Float64

Annualized excess return per unit of market beta (systematic risk).
"""
function treynor_ratio(r::AbstractVector, rb::AbstractVector; rf::Real = 0.0, ppy::Int = 252)
    β = capm_alpha_beta(r, rb; rf, ppy).beta
    return (ann_return(r; ppy) - rf) / β
end

"""
    omega_ratio(r; threshold=0.0) -> Float64

Omega ratio at a per-period `threshold`: probability-weighted gains above the
threshold divided by losses below it. Uses the full return distribution rather
than just its first two moments.
"""
function omega_ratio(r::AbstractVector; threshold::Real = 0.0)
    e = r .- threshold
    gains = sum(e[e .> 0])
    losses = -sum(e[e .< 0])
    return losses == 0 ? Inf : gains / losses
end

"""
    brinson_attribution(wp, wb, rp, rb) -> NamedTuple

Single-period Brinson–Fachler attribution across segments (sectors/sleeves).
Inputs are per-segment portfolio/benchmark weights (`wp`, `wb`) and segment
returns (`rp`, `rb`). Decomposes active return into allocation, selection, and
interaction; with weights summing to 1 the three totals reconcile exactly to
`active_return = wpᵀrp − wbᵀrb`.
"""
function brinson_attribution(wp::AbstractVector, wb::AbstractVector,
                             rp::AbstractVector, rb::AbstractVector)
    Rb = dot(wb, rb)
    allocation  = (wp .- wb) .* (rb .- Rb)
    selection   = wb .* (rp .- rb)
    interaction = (wp .- wb) .* (rp .- rb)
    return (; allocation, selection, interaction,
              total_allocation  = sum(allocation),
              total_selection   = sum(selection),
              total_interaction = sum(interaction),
              active_return     = dot(wp, rp) - dot(wb, rb))
end
