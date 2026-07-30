# =============================================================================
# spine.jl — the validated Path-B "spine": a diversified risk-parity base blended
# with a time-series-momentum (trend) sleeve, scaled by a volatility-target overlay.
#
# This is the strategy the edge-first validation selected (see
# docs/CANONICAL_ARCHITECTURE.md, "Path-B SYNTHESIS validated"). On 2007–2026,
# 5 assets, net of costs it delivered Sharpe 0.86 / Sortino 1.17 / maxDD −11%,
# with the trend sleeve carrying the book through 2022 (short bonds / long energy)
# when the long base and 60/40 both bled. It forecasts nothing: the base harvests
# the diversification premium by risk structure, the trend sleeve is the divergent
# crisis-alpha hedge, and the overlay is the risk-timing that halves drawdowns.
#
# Everything here composes the existing risk-based primitives (`ewma_cov`,
# `risk_parity`, `inverse_variance`); only the trend signal and the vol-target
# overlay are new. Convention (package-wide): return matrices are T x N.
# =============================================================================

"""
    tsmom_signal(R; lookback=252) -> Vector

Time-series-momentum sign per asset: `sign` of the trailing cumulative return over
the last `lookback` rows of the `T x N` return matrix `R` (uses all rows when
`T < lookback`). +1 = uptrend (go long), −1 = downtrend (go short), 0 = flat.
Causal — it reads only the window it is given.
"""
function tsmom_signal(R::AbstractMatrix; lookback::Int = 252)
    T = size(R, 1)
    lo = max(1, T - lookback + 1)
    cumret = vec(prod(1 .+ view(R, lo:T, :); dims = 1)) .- 1
    return sign.(cumret)
end

"""
    tsmom_weights(σ, signal) -> Vector

Long/short trend weights: each asset's `signal` scaled by inverse volatility
`1/σ`, then gross-normalized so `sum(|w|) == 1`. Inverse-vol scaling equalizes
each position's risk contribution to the sleeve (the standard managed-futures
construction). Returns zeros if no asset is trending.
"""
function tsmom_weights(σ::AbstractVector, signal::AbstractVector)
    raw = signal ./ max.(σ, eps())
    g = sum(abs, raw)
    return g > 0 ? raw ./ g : zero(raw)
end

# EWMA-weighted annualized volatility of a P&L series (RiskMetrics-style, most-recent
# observation weighted 1). `halflife` in periods; matches the covariance's decay so the
# per-sleeve vol-target reacts to fresh risk rather than a flat trailing average.
function _ewma_vol(x::AbstractVector; halflife::Real, ppy::Int = 252)
    T = length(x); T == 0 && return 0.0
    λ = 0.5^(1 / halflife)
    w = λ .^ collect(T-1:-1:0); w ./= sum(w)
    μ = dot(w, x)
    return sqrt(max(dot(w, (x .- μ) .^ 2), 0.0) * ppy)
end

"""
    voltarget_exposure(w, Σ; target_vol=0.12, cap=1.5, ppy=252) -> Float64

Volatility-target overlay. Scales gross exposure so the portfolio's *ex-ante*
annualized volatility `√(wᵀΣw · ppy)` hits `target_vol`, capped at `cap`
(`cap ≤ 1` ⇒ de-risk only, never lever). This is the risk-timing that cut the
book's max drawdown roughly in half in validation — it de-levers as forecast
risk rises. Ex-ante (from `Σ`) rather than trailing-realized, so it is causal and
does not lag a vol spike as badly.
"""
function voltarget_exposure(w::AbstractVector, Σ::AbstractMatrix;
                            target_vol::Real = 0.12, cap::Real = 1.5, ppy::Int = 252)
    daily_var = max(dot(w, Symmetric(Matrix(Σ)) * w), 0.0)
    ann_vol = sqrt(daily_var * ppy)
    return ann_vol <= eps() ? float(cap) : min(float(cap), target_vol / ann_vol)
end

"""
    spine_weights(R; sleeve_vol=0.08, cap=1.5, book_vol=nothing, halflife=21,
                  mom_lookback=252, base_weight=0.5, base=:erc) -> Vector

**Stateless single-window approximation.** This estimates each sleeve's vol from the
window `R` under the sleeve's *current* weights. That is faithful for the slow-moving
base but under-hedges the trend sleeve, whose true P&L vol depends on its *time-varying*
positions — a single window can't reconstruct that. The d-2 parity harness showed the
faithful construction needs a **stateful two-sleeve loop** that tracks each sleeve's own
realized P&L vol across time (reproduces Sharpe ~0.99 / maxDD −9.9% / 2022 −2.8%; this
one-shot version lands nearer Sharpe ~0.6). Use this for quick single-shot allocation and
`backtest` smoke-tests; the production daily path (`compute_targets`) uses the stateful
construction. The primitives below (`tsmom_signal`/`tsmom_weights`) are the verified
building blocks either way.

The full spine allocation for a trailing `T x N` return window `R`. Steps:

1. `Σ = ewma_cov(R; halflife)` — `halflife=21` matches the span-60 EWMA used in
   the prototype validation.
2. **base sleeve** (long-only, sums to 1): `:erc` = equal-risk-contribution
   `risk_parity(Σ)` (the principled, correlation-aware risk parity — the default);
   `:invvar` = `inverse_variance(Σ)`; `:invvol` = weights ∝ `1/σ` (the naive
   inverse-vol the prototype used).
3. **trend sleeve** (long/short, `sum|w|=1`): `tsmom_weights` on the 12-month sign.
4. **per-sleeve vol-target**: scale *each* sleeve independently to `sleeve_vol`
   (capped at `cap`) *before* blending, using the sleeve's own **realized P&L
   volatility** over the window (`std(R·w)`), the standard managed-futures
   construction. This is load-bearing in two ways the d-2 parity harness proved:
   (i) it levers the low-vol trend sleeve up to equal risk with the base so trend
   can actually hedge; and (ii) targeting on *realized P&L* vol — not the ex-ante
   asset-covariance vol — keeps the trend sleeve engaged through a crisis. A trend
   book's P&L is smooth when it's working (e.g. steadily short bonds in 2022) even
   as the underlying asset vols spike; ex-ante targeting would wrongly throttle the
   hedge exactly when it pays.
5. **blend**: `base_weight·(scaled base) + (1−base_weight)·(scaled trend)` (50/50).
6. **optional book overlay**: if `book_vol` is given, scale the combined book to it
   (`nothing` reproduces the two-sleeve prototype, which applied no further overlay).

The returned vector is the target book as fractions of capital; its net exposure
`sum(w)` may be below 1 (de-risked) and individual weights may be negative
(trend shorts). It forecasts no returns.
"""
function spine_weights(R::AbstractMatrix; sleeve_vol::Real = 0.08, cap::Real = 1.5,
                       book_vol = nothing, halflife::Real = 21, mom_lookback::Int = 252,
                       base_weight::Real = 0.5, base::Symbol = :erc)
    Σ = ewma_cov(R; halflife = halflife)
    σ = sqrt.(diag(Σ))

    base_w = base === :erc    ? risk_parity(Σ) :
             base === :invvar ? inverse_variance(Σ) :
             base === :invvol ? ((iv = 1 ./ max.(σ, eps())); iv ./ sum(iv)) :
             error("unknown base $base (use :erc, :invvar, or :invvol)")

    trend_w = tsmom_weights(σ, tsmom_signal(R; lookback = mom_lookback))

    # Per-sleeve exposure from the sleeve's REALIZED P&L vol over the window (not ex-ante
    # asset vol) — keeps the trend sleeve engaged in crises when its P&L stays smooth.
    # EWMA-weighted (same `halflife` as the covariance) so the risk-timing reacts quickly;
    # a flat trailing std lags spikes and blunts the overlay.
    sleeve_scale(sw) = begin
        rv = _ewma_vol(R * sw; halflife = halflife)
        rv <= eps() ? float(cap) : min(float(cap), sleeve_vol / rv)
    end
    w = base_weight .* (sleeve_scale(base_w) .* base_w) .+
        (1 - base_weight) .* (sleeve_scale(trend_w) .* trend_w)

    return book_vol === nothing ? w :
           voltarget_exposure(w, Σ; target_vol = book_vol, cap = cap) .* w
end

"""
    spine_strategy(; kwargs...) -> Function

Return a one-argument strategy closure `window -> spine_weights(window; kwargs...)`
suitable for `backtest(R, spine_strategy(); lookback=252, rebalance=21)`. `kwargs`
are forwarded to [`spine_weights`](@ref).
"""
spine_strategy(; kwargs...) = window -> spine_weights(window; kwargs...)

# =============================================================================
# Stateful spine — the production construction (verified in the d-2 parity harness to
# reproduce the study: Sharpe ~0.99, maxDD −9.9%, 2022 −2.8%, trend +4.2% in 2022).
#
# Unlike the stateless `spine_weights`, this carries each sleeve's *own realized P&L
# volatility* forward day-to-day (RiskMetrics recursion) — the thing a single window
# cannot reconstruct, and the reason the stateless version under-hedges trend. A daily
# loop calls `spine_step!(state, window)` once per bar; the state remembers the weights
# it held and each sleeve's vol so the next bar's realized P&L updates it.
# =============================================================================

"""
    SpineState(n_assets; sleeve_vol=0.08, cap=1.5, base_weight=0.5, halflife=21,
               mom_lookback=252, vol_span=60, base=:invvol, regime=:none)

Mutable state for the stateful two-sleeve spine over `n_assets`. `base=:invvol` is the
validated default (naive inverse-vol base); `:erc`/`:invvar` are available. `vol_span`
is the RiskMetrics span (in bars) for each sleeve's realized-P&L vol. `regime` is the d-5
gross-exposure overlay (`:none` = the exactly-validated baseline; `:dd` recommended in
production — see [`regime_multiplier`](@ref)). **Persist this across daily runs** (e.g.
`Serialization`) — the vol state must carry over.
"""
mutable struct SpineState
    sleeve_vol::Float64
    cap::Float64
    base_weight::Float64
    halflife::Float64
    mom_lookback::Int
    vol_span::Int
    base::Symbol
    regime::Symbol              # d-5 gross-exposure regime overlay (:none/:dd/:vol/:trend/:both)
    base_s2::Float64            # EWMA (RiskMetrics) variance of base sleeve daily P&L
    trend_s2::Float64           # …and the trend sleeve
    base_w::Vector{Float64}     # last-held (unscaled) base weights
    trend_w::Vector{Float64}    # last-held (unscaled) trend weights
    n::Int                      # number of steps taken
end

function SpineState(n_assets::Int; sleeve_vol::Real = 0.08, cap::Real = 1.5,
                    base_weight::Real = 0.5, halflife::Real = 21, mom_lookback::Int = 252,
                    vol_span::Int = 60, base::Symbol = :invvol, regime::Symbol = :none)
    SpineState(sleeve_vol, cap, base_weight, halflife, mom_lookback, vol_span, base, regime,
               0.0, 0.0, zeros(n_assets), zeros(n_assets), 0)
end

"""
    regime_multiplier(window, kind; floor=0.5) -> Float64

Gross-exposure multiplier ∈ (0,1] from the trailing window's equal-weight **market proxy** —
the d-5 regime risk-timing overlay layered on top of the spine book. Complements the
per-sleeve vol-target (which is a lagged crash-cutter) by reacting to the market's *state*:

- `:none`  — always 1.0 (reproduces the validated baseline).
- `:dd`    — cut to `floor` when the market is >8% below its in-window peak (the recommended
             default: best risk-adjusted, ~0 CAGR cost in the d-5 test).
- `:vol`   — scale down as short-horizon vs long-horizon realized vol rises.
- `:trend` — `floor` when the market is below its 200-bar moving average, else 1.0.
- `:both`  — `min(:dd, :vol)` (max crisis defense; some CAGR cost).

Causal — reads only `window`.
"""
function regime_multiplier(window::AbstractMatrix, kind::Symbol; floor::Real = 0.5)
    kind === :none && return 1.0
    mkt = vec(mean(window, dims = 2)); T = length(mkt)
    if kind === :dd
        idx = cumprod(1 .+ mkt); return idx[end] / maximum(idx) - 1 < -0.08 ? float(floor) : 1.0
    elseif kind === :vol
        n = min(20, T); r = std(@view mkt[end-n+1:end]) / (std(mkt) + eps())
        return clamp(1.0 - 1.5 * max(0.0, r - 1.0), float(floor), 1.0)
    elseif kind === :trend
        idx = cumprod(1 .+ mkt); n = min(200, T)
        return idx[end] >= mean(@view idx[end-n+1:end]) ? 1.0 : float(floor)
    elseif kind === :both
        return min(regime_multiplier(window, :dd; floor = floor),
                   regime_multiplier(window, :vol; floor = floor))
    else
        error("unknown regime $kind (:none/:dd/:vol/:trend/:both)")
    end
end

_base_weights(base::Symbol, Σ, σ) =
    base === :erc    ? risk_parity(Σ) :
    base === :invvar ? inverse_variance(Σ) :
    base === :invvol ? ((iv = 1 ./ max.(σ, eps())); iv ./ sum(iv)) :
    error("unknown base $base (use :erc, :invvar, or :invvol)")

"""
    spine_step!(state, window) -> Vector

Advance the stateful spine by one bar and return the target book (fractions of capital;
net exposure may be < 1, trend weights may be negative). `window` is the trailing `T x N`
return matrix whose **last row is the just-realized bar**. Order of operations (matches
the verified harness):

1. Update each sleeve's realized-P&L vol with the last bar earned by the *previously held*
   weights (skipped on the first call).
2. Compute fresh base and trend weights from the window (causal).
3. Size each sleeve to `sleeve_vol` using its realized vol (capped); the trend sleeve is
   sized on *its own P&L* vol, so a crisis where trend profits smoothly keeps it engaged.
4. Blend `base_weight·base ⊕ (1−base_weight)·trend`; remember the new weights for next bar.
"""
function spine_step!(s::SpineState, window::AbstractMatrix)
    λ = 1 - 2 / (s.vol_span + 1)
    last_bar = @view window[end, :]

    if s.n > 0                                          # 1. fold in the realized bar
        rb = dot(s.base_w, last_bar); rt = dot(s.trend_w, last_bar)
        s.base_s2  = s.n == 1 ? rb^2 : λ * s.base_s2  + (1 - λ) * rb^2
        s.trend_s2 = s.n == 1 ? rt^2 : λ * s.trend_s2 + (1 - λ) * rt^2
    end

    Σ = ewma_cov(window; halflife = s.halflife); σ = sqrt.(diag(Σ))    # 2. fresh weights
    base_w  = _base_weights(s.base, Σ, σ)
    trend_w = tsmom_weights(σ, tsmom_signal(window; lookback = s.mom_lookback))

    expo(s2) = (s.n == 0 || s2 <= eps()) ? s.cap :      # 3. per-sleeve vol-target
               min(s.cap, s.sleeve_vol / sqrt(s2 * 252))
    w = s.base_weight .* (expo(s.base_s2) .* base_w) .+  # 4. blend
        (1 - s.base_weight) .* (expo(s.trend_s2) .* trend_w)

    s.base_w = base_w; s.trend_w = trend_w; s.n += 1     # store un-modulated sleeves for next bar
    return regime_multiplier(window, s.regime) .* w       # 5. regime gross overlay (d-5)
end

"""
    spine_targets(w, symbols, prices, capital) -> Dict{String,Float64}

Map a spine weight vector to **signed share targets**: `wᵢ · capital / priceᵢ` per symbol
(negative = short). `prices` is a vector aligned with `symbols`/`w`. The execution layer
rounds/lots and reconciles; this is the strategy→order seam consumed by `execute_rebalance!`.
"""
function spine_targets(w::AbstractVector, symbols::AbstractVector,
                       prices::AbstractVector, capital::Real)
    return Dict{String,Float64}(String(symbols[i]) => w[i] * capital / prices[i]
                                for i in eachindex(w))
end
