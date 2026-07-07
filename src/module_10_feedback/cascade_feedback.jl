module CascadeFeedback

# ============================================================================
# CASCADE FEEDBACK ADAPTER
# Circular Futures Cascade Signal Gap — DPM integration layer
#
# This module is the "return pipe" that Module 5 (DPM) calls during
# re-estimation. It intercepts the raw return series, applies Layer 1
# (exogenous partitioning) and optionally Layer 2 (impact residualization),
# and returns a cleaned series ready for DPM/ARMA fitting.
#
# Usage (in DPM re-estimation loop):
#
#   prepared = prepare_returns_for_dpm(
#       raw_returns, timestamps, ledger, config;
#       symbol = "NVDA",
#       signed_positions = positions,
#       sigma_intervals  = vols
#   )
#   if prepared.fallback_mode
#       @warn "Cascade in conservative fallback — skip regime update this cycle"
#   else
#       em_estimation(dpm_config, prepared.returns)
#   end
# ============================================================================

using Dates, Statistics, Logging
using ..ExecutionLedger

export FeedbackConfig, PreparedReturns,
       prepare_returns_for_dpm,
       should_use_fallback,
       summarize_feedback

# ── Configuration ─────────────────────────────────────────────────────────────

"""
    FeedbackConfig

Controls which feedback layers are active during DPM pre-processing.

# Fields
- `layer1_enabled::Bool`: Apply exogenous return filter (default: true)
- `layer2_enabled::Bool`: Apply impact residualization (default: false — requires α)
- `alpha::Float64`: Market impact coefficient for Layer 2 (estimate via `estimate_alpha`)
- `adv_interval::Float64`: ADV in the same units as fills' `adv_interval` field
- `min_sample_size::Int`: Abort DPM update if exogenous sample < this (default: 60)
- `materiality_threshold::Float64`: Volume ratio cutoff for Layer 1 (default: 0.005)
"""
struct FeedbackConfig
    layer1_enabled::Bool
    layer2_enabled::Bool
    alpha::Float64
    adv_interval::Float64
    min_sample_size::Int
    materiality_threshold::Float64
end

function FeedbackConfig(;
    layer1_enabled::Bool        = true,
    layer2_enabled::Bool        = false,
    alpha::Float64              = 0.0,
    adv_interval::Float64       = 1.0,
    min_sample_size::Int        = 60,
    materiality_threshold::Float64 = 0.005   # == ExecutionLedger.DEFAULT_MATERIALITY_THRESHOLD
)
    FeedbackConfig(layer1_enabled, layer2_enabled, alpha, adv_interval,
                   min_sample_size, materiality_threshold)
end

# ── Output ────────────────────────────────────────────────────────────────────

"""
    PreparedReturns

Result of the feedback pre-processing pipeline.

# Fields
- `returns::Vector{Float64}`: Cleaned return series ready for DPM fitting
- `mask::BitVector`: Which original intervals survived Layer 1 (all-true if disabled)
- `n_original::Int`: Length of the input return series
- `n_exogenous::Int`: Length of `returns` after Layer 1 filtering
- `exogenous_ratio::Float64`: `n_exogenous / n_original`
- `layer2_applied::Bool`: Whether impact residualization was performed
- `alpha_used::Float64`: α value used in Layer 2 (NaN if layer 2 disabled)
- `fallback_mode::Bool`: True if sample is too thin — DPM update should be skipped
- `warning::Union{LowSignalRegimeWarning,Nothing}`: Set if exogenous_ratio < threshold
"""
struct PreparedReturns
    returns::Vector{Float64}
    mask::BitVector
    n_original::Int
    n_exogenous::Int
    exogenous_ratio::Float64
    layer2_applied::Bool
    alpha_used::Float64
    fallback_mode::Bool
    warning::Union{LowSignalRegimeWarning,Nothing}
end

# ── Main entry point ──────────────────────────────────────────────────────────

"""
    prepare_returns_for_dpm(
        raw_returns, timestamps, ledger, config;
        symbol, signed_positions, sigma_intervals
    ) -> PreparedReturns

Full feedback pipeline. Call this in Module 5 before `em_estimation` or
`recursive_update`. The output's `.returns` field is a drop-in replacement
for the raw return series.

# Arguments
- `raw_returns::Vector{Float64}`: Raw observed returns (length N)
- `timestamps::Vector{DateTime}`: Interval timestamps (length N or N+1)
- `ledger::ExecutionLedger`: Persistent fill store
- `config::FeedbackConfig`: Layer activation and parameters

# Keyword arguments
- `symbol::String`: Ticker to query from the ledger
- `signed_positions::Vector{Float64}`: For Layer 2 — average signed delta per interval
- `sigma_intervals::Vector{Float64}`: For Layer 2 — realized vol per interval

# Processing order
1. Layer 1 (if enabled): drop intervals where |Q|/ADV >= materiality_threshold
2. Layer 2 (if enabled and alpha != 0): subtract α·(|Q|/ADV)·σ·sign(Q) from each interval

Layer 2 is applied to the **full** return series (before Layer 1 filter).
The residualized series is then filtered by Layer 1 mask. This order ensures
Layer 2 correction is applied even to intervals that survive the filter —
because even sub-threshold fills have non-zero (though small) impact.
"""
function prepare_returns_for_dpm(
    raw_returns::Vector{Float64},
    timestamps::Vector{DateTime},
    ledger::ExecutionLedger,
    config::FeedbackConfig;
    symbol::String                    = "UNKNOWN",
    signed_positions::Vector{Float64} = Float64[],
    sigma_intervals::Vector{Float64}  = Float64[]
)::PreparedReturns

    N = length(raw_returns)
    all_true_mask = trues(N)

    # ── Layer 2 first (on full series before filtering) ──────────────────────
    working_returns = raw_returns
    layer2_applied  = false
    alpha_used      = NaN

    if config.layer2_enabled && config.alpha != 0.0 &&
       length(signed_positions) == N && length(sigma_intervals) == N

        working_returns = residualize_impact(
            raw_returns, signed_positions, sigma_intervals;
            alpha        = config.alpha,
            adv_interval = config.adv_interval
        )
        layer2_applied = true
        alpha_used     = config.alpha
        @info "Layer 2 impact residualization applied" symbol=symbol alpha=config.alpha
    elseif config.layer2_enabled
        @warn "Layer 2 requested but inputs incomplete" symbol=symbol has_positions=!isempty(signed_positions) has_vols=!isempty(sigma_intervals)
    end

    # ── Layer 1: exogenous partitioning ──────────────────────────────────────
    R_exo   = working_returns
    mask    = all_true_mask
    warning = nothing

    if config.layer1_enabled
        R_exo, mask, warning = build_exogenous_returns(
            working_returns, timestamps, ledger, symbol;
            adv_interval          = config.adv_interval,
            threshold             = config.materiality_threshold,
            low_signal_threshold  = 0.30   # == ExecutionLedger.LOW_SIGNAL_RATIO_THRESHOLD
        )
        @info "Layer 1 filter applied" symbol=symbol n_total=N n_exogenous=sum(mask)
    end

    n_exo  = length(R_exo)
    ratio  = N > 0 ? n_exo / N : 1.0

    # Fallback: too few clean observations to fit the DPM reliably
    fallback = n_exo < config.min_sample_size

    if fallback
        @warn "PreparedReturns: exogenous sample below min_sample_size — DPM update suppressed" symbol=symbol n_exogenous=n_exo min_required=config.min_sample_size
    end

    return PreparedReturns(
        R_exo, mask, N, n_exo, ratio,
        layer2_applied, alpha_used,
        fallback, warning
    )
end

# ── Utility ───────────────────────────────────────────────────────────────────

"""
    should_use_fallback(prepared::PreparedReturns) -> Bool

Returns `true` when the DPM update should be skipped and the cascade
should revert to equal-weight / reduced-leverage mode. This is the
decision point for the orchestration loop.
"""
function should_use_fallback(prepared::PreparedReturns)::Bool
    return prepared.fallback_mode
end

"""
    summarize_feedback(prepared::PreparedReturns) -> String

Human-readable diagnostic string for logging and the IBKR alert feed.
"""
function summarize_feedback(prepared::PreparedReturns)::String
    pct = round(prepared.exogenous_ratio * 100, digits=1)
    l2  = prepared.layer2_applied ? " | Layer2: α=$(round(prepared.alpha_used, digits=3))" : ""
    fb  = prepared.fallback_mode ? " | ⚠ FALLBACK ACTIVE" : ""
    warn = prepared.warning !== nothing ? " | LOW SIGNAL" : ""
    "Feedback: $(prepared.n_exogenous)/$(prepared.n_original) exogenous ($(pct)%)$(l2)$(warn)$(fb)"
end

end  # module CascadeFeedback
