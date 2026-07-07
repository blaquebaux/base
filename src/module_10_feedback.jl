module FeedbackLayer

# ============================================================================
# MODULE 10 — FEEDBACK LAYER
# Circular Futures Cascade Signal Gap
#
# Installs the "return pipe" from ExecutionLayer → DPM pre-processing.
#
# Layer 1 (ExecutionLedger + build_exogenous_returns):
#   Drops return intervals where own-fills exceed a volume-ratio threshold.
#   Produces R_exogenous. Warns when the surviving sample is dangerously thin.
#
# Layer 2 (residualize_impact):
#   Subtracts estimated market impact from each interval using a strategy-
#   specific α coefficient estimated by OLS from historical fills.
#   Produces R_clean. α is re-estimated weekly on a 60-day rolling window.
#
# Layer 3 (research-grade, future work):
#   Feedback-aware DPM prior with latent endogeneity variable η_t.
#   Requires custom variational EM. Needed only above ~$100M NVDA notional
#   or when trading >2% of ADV daily.
#
# Usage: see cascade_feedback.jl → prepare_returns_for_dpm()
# ============================================================================

using Dates, Statistics, Logging, SQLite

include("execution_ledger.jl")
include("cascade_feedback.jl")

using .ExecutionLedger
using .CascadeFeedback

export ExecutionLedger, CascadeFeedback

# Re-export the most common entry points so callers can write:
#   using BlaqueBaux
#   FeedbackLayer.prepare_returns_for_dpm(...)
#   FeedbackLayer.open_ledger(...)
export open_ledger, close_ledger, record_fill,
       query_fills, query_fills_in_period,
       FillRecord, LedgerConfig, LowSignalRegimeWarning,
       FeedbackConfig, PreparedReturns,
       prepare_returns_for_dpm, should_use_fallback, summarize_feedback,
       estimate_alpha, residualize_impact, build_exogenous_returns

end  # module FeedbackLayer
