module CascadeInterface

export RegimeProbs, BlendedCascadeParams, PositionSizing, GammaARMAOutput,
       CASCADE_PARAMS,
       blend_cascade_params, compute_position_sizing,
       apply_global_risk_off

# ============================================================================
# Regime Probabilities
# ============================================================================

"""
    RegimeProbs

Regime probabilities from DPM (must sum to 1.0).

# Fields
- `p_fixed::Float64`: Probability of Fixed Income regime
- `p_growth::Float64`: Probability of Growth regime
- `p_floating::Float64`: Probability of Floating regime
"""
struct RegimeProbs
    p_fixed::Float64
    p_growth::Float64
    p_floating::Float64

    function RegimeProbs(p_fixed::Float64, p_growth::Float64, p_floating::Float64)
        total = p_fixed + p_growth + p_floating
        @assert abs(total - 1.0) < 1e-6 "Regime probabilities must sum to 1.0 (got $total)"
        new(p_fixed, p_growth, p_floating)
    end
end

# Convenience constructor from vector
function RegimeProbs(probs::Vector{Float64})
    @assert length(probs) == 3 "Need exactly 3 regime probabilities"
    RegimeProbs(probs[1], probs[2], probs[3])
end

# ============================================================================
# Cascade Parameters by Regime
# ============================================================================

"""
    CASCADE_PARAMS

Strategy weights and risk parameters for each regime.

# Fixed Income Regime
- trend_weight = 0.20 (low trend following)
- meanrev_weight = 0.60 (high mean reversion)
- momentum_weight = 0.20 (moderate momentum)
- defensive_weight = 0.00 (no defense)
- stop_width = 1.5 (tight stops)
- max_hold_days = 20 (short hold)

# Growth Regime
- trend_weight = 0.70 (high trend following)
- meanrev_weight = 0.10 (low mean reversion)
- momentum_weight = 0.20 (moderate momentum)
- defensive_weight = 0.00 (no defense)
- stop_width = 3.0 (wide stops)
- max_hold_days = 60 (long hold)

# Floating Regime
- trend_weight = 0.10 (very low trend)
- meanrev_weight = 0.10 (very low mean reversion)
- momentum_weight = 0.10 (very low momentum)
- defensive_weight = 0.70 (high defense)
- stop_width = 0.5 (very tight stops)
- max_hold_days = 3 (very short hold)
"""
const CASCADE_PARAMS = Dict(
    "fixed" => (
        trend_weight = 0.20,
        meanrev_weight = 0.60,
        momentum_weight = 0.20,
        defensive_weight = 0.00,
        stop_width = 1.5,
        max_hold_days = 20
    ),
    "growth" => (
        trend_weight = 0.70,
        meanrev_weight = 0.10,
        momentum_weight = 0.20,
        defensive_weight = 0.00,
        stop_width = 3.0,
        max_hold_days = 60
    ),
    "floating" => (
        trend_weight = 0.10,
        meanrev_weight = 0.10,
        momentum_weight = 0.10,
        defensive_weight = 0.70,
        stop_width = 0.5,
        max_hold_days = 3
    )
)

# ============================================================================
# Blended Cascade Parameters
# ============================================================================

"""
    BlendedCascadeParams

Regime-probability-weighted cascade parameters.

# Fields
- `trend_weight::Float64`: Blended trend-following weight
- `meanrev_weight::Float64`: Blended mean-reversion weight
- `momentum_weight::Float64`: Blended momentum weight
- `defensive_weight::Float64`: Blended defensive weight
- `stop_width_atr::Float64`: Blended stop width (in ATR units)
- `max_holding_days::Int`: Blended maximum holding period
"""
struct BlendedCascadeParams
    trend_weight::Float64
    meanrev_weight::Float64
    momentum_weight::Float64
    defensive_weight::Float64
    stop_width_atr::Float64
    max_holding_days::Int
end

"""
    blend_cascade_params(probs::RegimeProbs) -> BlendedCascadeParams

Blend cascade parameters by regime probabilities.

Computes probability-weighted average of strategy weights and risk parameters.
"""
function blend_cascade_params(probs::RegimeProbs)::BlendedCascadeParams
    fixed = CASCADE_PARAMS["fixed"]
    growth = CASCADE_PARAMS["growth"]
    floating = CASCADE_PARAMS["floating"]

    # Weighted averages
    trend = probs.p_fixed * fixed.trend_weight +
            probs.p_growth * growth.trend_weight +
            probs.p_floating * floating.trend_weight

    meanrev = probs.p_fixed * fixed.meanrev_weight +
              probs.p_growth * growth.meanrev_weight +
              probs.p_floating * floating.meanrev_weight

    momentum = probs.p_fixed * fixed.momentum_weight +
               probs.p_growth * growth.momentum_weight +
               probs.p_floating * floating.momentum_weight

    defensive = probs.p_fixed * fixed.defensive_weight +
                probs.p_growth * growth.defensive_weight +
                probs.p_floating * floating.defensive_weight

    stop_width = probs.p_fixed * fixed.stop_width +
                 probs.p_growth * growth.stop_width +
                 probs.p_floating * floating.stop_width

    max_hold = round(Int, probs.p_fixed * fixed.max_hold_days +
                          probs.p_growth * growth.max_hold_days +
                          probs.p_floating * floating.max_hold_days)

    return BlendedCascadeParams(
        trend, meanrev, momentum, defensive,
        stop_width, max_hold
    )
end

# ============================================================================
# Position Sizing
# ============================================================================

"""
    PositionSizing

Position sizing parameters for parallel regional pools.

# Fields
- `total_capital::Float64`: Total capital per pool (default: \$10,000)
- `active_pct::Float64`: Percentage allocated to active strategies
- `defensive_pct::Float64`: Percentage allocated to defensive/cash
- `multiplier::Float64`: Position size multiplier
- `exposure::Float64`: Total exposure (active + defensive)
- `defensive_cash::Float64`: Cash held defensively
"""
struct PositionSizing
    total_capital::Float64
    active_pct::Float64
    defensive_pct::Float64
    multiplier::Float64
    exposure::Float64
    defensive_cash::Float64
end

"""
    compute_position_sizing(
        probs::RegimeProbs,
        total_capital::Float64=10000.0
    ) -> PositionSizing

Compute position sizing based on regime probabilities.

# Allocation Rules
- Fixed regime: 70% active, 30% defensive
- Growth regime: 90% active, 10% defensive
- Floating regime: 20% active, 80% defensive

# Arguments
- `probs::RegimeProbs`: Regime probabilities
- `total_capital::Float64`: Total capital per pool (default: \$10,000)

# Returns
- `PositionSizing`: Computed position sizing
"""
function compute_position_sizing(
    probs::RegimeProbs,
    total_capital::Float64=10000.0
)::PositionSizing

    # Regime-specific allocations
    fixed_active = 0.70
    growth_active = 0.90
    floating_active = 0.20

    # Blended active percentage
    active_pct = probs.p_fixed * fixed_active +
                 probs.p_growth * growth_active +
                 probs.p_floating * floating_active

    defensive_pct = 1.0 - active_pct

    # Multiplier based on conviction (max regime prob)
    max_prob = max(probs.p_fixed, probs.p_growth, probs.p_floating)
    multiplier = 0.5 + max_prob  # Range: 0.5 to 1.5

    # Exposure calculations
    exposure = active_pct * total_capital * multiplier
    defensive_cash = defensive_pct * total_capital

    return PositionSizing(
        total_capital,
        active_pct,
        defensive_pct,
        multiplier,
        exposure,
        defensive_cash
    )
end

# ============================================================================
# Cross-Asset Linkage (Global Risk-Off)
# ============================================================================

"""
    apply_global_risk_off(
        local_probs::RegimeProbs,
        global_risk_off::Float64
    ) -> RegimeProbs

Adjust local regime probabilities based on global risk-off signal.

# Arguments
- `local_probs::RegimeProbs`: Local (asset-specific) regime probabilities
- `global_risk_off::Float64`: Global risk-off indicator [0, 1]
    - 0.0: Full risk-on
    - 1.0: Full risk-off

# Returns
- `RegimeProbs`: Adjusted probabilities with increased Floating weight
"""
function apply_global_risk_off(
    local_probs::RegimeProbs,
    global_risk_off::Float64
)::RegimeProbs

    global_risk_off = clamp(global_risk_off, 0.0, 1.0)

    # Shift probability toward Floating (defensive) regime
    # Linear interpolation: more risk-off → more Floating
    p_floating_new = local_probs.p_floating + global_risk_off * (1.0 - local_probs.p_floating)

    # Reduce Fixed and Growth proportionally
    remaining = 1.0 - p_floating_new
    if remaining > 0 && local_probs.p_fixed + local_probs.p_growth > 0
        ratio = local_probs.p_fixed / (local_probs.p_fixed + local_probs.p_growth)
        p_fixed_new = remaining * ratio
        p_growth_new = remaining * (1 - ratio)
    else
        p_fixed_new = 0.0
        p_growth_new = 0.0
    end

    return RegimeProbs(p_fixed_new, p_growth_new, p_floating_new)
end

# ============================================================================
# Gamma-ARMA Output
# ============================================================================

"""
    GammaARMAOutput

Complete output object for downstream risk engine.

# Fields
- `regime_probs::RegimeProbs`: Current regime probabilities
- `cond_vol::Float64`: Conditional volatility σₜ from GARCH or realized vol
- `tail_alpha::Float64`: Tail index α for RNIV calculation
- `jump_intensity::Float64`: Jump intensity λ(t)
"""
struct GammaARMAOutput
    regime_probs::RegimeProbs
    cond_vol::Float64
    tail_alpha::Float64
    jump_intensity::Float64
end

"""
    create_gamma_arma_output(
        regime_probs::RegimeProbs,
        cond_vol::Float64,
        tail_alpha::Float64,
        jump_intensity::Float64=0.0
    ) -> GammaARMAOutput

Create GammaARMAOutput with validation.
"""
function create_gamma_arma_output(
    regime_probs::RegimeProbs,
    cond_vol::Float64,
    tail_alpha::Float64,
    jump_intensity::Float64=0.0
)::GammaARMAOutput
    @assert cond_vol >= 0 "Conditional volatility must be non-negative"
    @assert 1.5 <= tail_alpha <= 4.0 "Tail index must be in [1.5, 4.0]"
    @assert jump_intensity >= 0 "Jump intensity must be non-negative"

    return GammaARMAOutput(regime_probs, cond_vol, tail_alpha, jump_intensity)
end

end  # module CascadeInterface
