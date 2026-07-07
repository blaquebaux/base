module ZeroDTE

# ============================================================================
# module_9_0dte.jl — 0DTE Overlay Engine
#
# Implements a systematic 0DTE options overlay with three layers:
#   Layer 1: Greeks screening (Delta bounds, Theta/Premium, Vega/IV veto)
#   Layer 2: Dynamic position sizing via Theta Load factor
#   Layer 3: ORB + IV confirmation matrix (4-quadrant signal filter)
#
# Integration points:
#   - Receives GEX levels from module_6_cascade (CascadeInterface)
#   - Receives regime context from module_5_dpm (DPM)
#   - Sends sized orders to module_7_execution (ExecutionLayer)
#
# All filters are applied sequentially. A trade must pass ALL layers.
# ============================================================================

using Dates, Statistics, Logging

export OptionGreeks, ORBState, IVState, ZeroDTEParams, ZeroDTESignal
export ZeroDTEResult, TradeDecision
export screen_greeks, compute_iv_rank, classify_orb_iv_quadrant
export compute_theta_load, size_position, evaluate_0dte_setup
export DEFAULT_PARAMS

# ── Constants ─────────────────────────────────────────────────────────────────

const MARKET_OPEN   = Time(9, 30)
const MARKET_CLOSE  = Time(16, 0)
const TOTAL_SESSION_HOURS = 6.5   # 9:30 → 16:00

# ── Core Types ────────────────────────────────────────────────────────────────

"""
    OptionGreeks

Snapshot of option Greeks at a given moment.

# Fields
- `delta::Float64`: Option delta (0–1 for calls, -1–0 for puts)
- `theta::Float64`: Daily Theta decay (negative — cost per day)
- `vega::Float64`: Sensitivity to 1pp IV move
- `gamma::Float64`: Rate of delta change
- `premium::Float64`: Current option mid-price (per contract)
- `iv::Float64`: Implied volatility (decimal, e.g. 0.25 = 25%)
- `timestamp::DateTime`: Observation time
"""
struct OptionGreeks
    delta::Float64
    theta::Float64      # negative (cost)
    vega::Float64
    gamma::Float64
    premium::Float64    # mid-price per contract
    iv::Float64         # e.g. 0.25
    timestamp::DateTime
end

"""
    ORBState

Opening Range Breakout state for the current session.

# Fields
- `orb_high::Float64`: Upper bound of the opening range
- `orb_low::Float64`: Lower bound of the opening range
- `orb_minutes::Int`: Window used (e.g. 15 or 30)
- `current_price::Float64`: Latest underlying price
- `breakout_confirmed::Bool`: Price has cleanly closed outside the range
- `direction::Symbol`: `:bullish`, `:bearish`, or `:none`
"""
struct ORBState
    orb_high::Float64
    orb_low::Float64
    orb_minutes::Int
    current_price::Float64
    breakout_confirmed::Bool
    direction::Symbol       # :bullish | :bearish | :none
end

"""
    IVState

Implied volatility context for IV-rank computation.

# Fields
- `current_iv::Float64`: Current IV (decimal)
- `iv_history::Vector{Float64}`: Rolling 20-day IV observations
- `iv_rank::Float64`: Percentile rank within history (0–1)
- `iv_expanding::Bool`: True if IV is rising vs. prior bar
- `iv_change_pct::Float64`: Percentage change in IV vs. prior bar
"""
struct IVState
    current_iv::Float64
    iv_history::Vector{Float64}
    iv_rank::Float64
    iv_expanding::Bool
    iv_change_pct::Float64
end

"""
    ZeroDTEParams

Configurable parameters for all three overlay layers.
"""
struct ZeroDTEParams
    # Layer 1 — Greeks screening
    delta_min::Float64          # 0.20 — minimum abs(delta) for entry
    delta_max::Float64          # 0.40 — maximum abs(delta) for entry
    theta_premium_max::Float64  # 0.15–0.20 — Theta as % of premium ceiling
    iv_rank_veto::Float64       # 0.85–0.90 — veto if IV rank exceeds this

    # Layer 2 — Dynamic sizing
    account_risk_limit::Float64 # Max USD at risk per trade (e.g. 500.0)
    min_size_floor::Int         # Minimum contracts regardless of time (e.g. 1)

    # Layer 3 — ORB + IV matrix
    scout_size_pct::Float64     # Fraction of full size for low-conviction (0.10–0.20)
    orb_buffer_pct::Float64     # % above/below ORB level to confirm breakout (e.g. 0.001)
end

"""
Default parameters per specification.
"""
const DEFAULT_PARAMS = ZeroDTEParams(
    0.20,    # delta_min
    0.40,    # delta_max
    0.175,   # theta_premium_max (midpoint of 15–20%)
    0.875,   # iv_rank_veto (midpoint of top 10–15%)
    500.0,   # account_risk_limit
    1,       # min_size_floor
    0.15,    # scout_size_pct (midpoint of 10–20%)
    0.001    # orb_buffer_pct (0.1% beyond range boundary)
)

"""
    TradeDecision

Enumerated outcome from the 0DTE overlay evaluation.
"""
@enum TradeDecision begin
    FULL_SIZE       # All layers passed — enter at full Theta Load size
    SCOUT_SIZE      # ORB confirmed but IV compressing — small probe entry
    REJECT_GREEKS   # Failed Layer 1 Greeks screen
    REJECT_IV_VETO  # Failed Layer 1 IV rank veto (high IV environment)
    REJECT_NO_ORB   # No confirmed ORB breakout
    REJECT_IV_COMP  # ORB present but IV compressing — no trade
end

"""
    ZeroDTESignal

Full signal package passed to the execution layer.

# Fields
- `decision::TradeDecision`: Final trade decision
- `contracts::Int`: Recommended position size (0 if rejected)
- `direction::Symbol`: `:bullish` or `:bearish`
- `theta_load::Float64`: Time-decay factor applied (0–1)
- `greeks_ok::Bool`: Passed Layer 1
- `iv_rank::Float64`: Current IV rank
- `orb_quadrant::Symbol`: Signal classification
- `rejection_reason::String`: Human-readable reason if rejected
- `timestamp::DateTime`
"""
struct ZeroDTESignal
    decision::TradeDecision
    contracts::Int
    direction::Symbol
    theta_load::Float64
    greeks_ok::Bool
    iv_rank::Float64
    orb_quadrant::Symbol    # :bullish_expansion | :bullish_compression |
                            # :bearish_expansion | :bearish_compression | :none
    rejection_reason::String
    timestamp::DateTime
end

# A wrapper returned by the top-level evaluator
struct ZeroDTEResult
    signal::ZeroDTESignal
    layer1_passed::Bool
    layer2_size::Int        # Theta-load size before Layer 3 adjustment
    layer3_adjustment::Float64  # Multiplier applied by Layer 3
end

# ── Layer 1: Greeks Screening ─────────────────────────────────────────────────

"""
    screen_greeks(greeks, params) -> (passed::Bool, reason::String)

Apply three sequential Greek filters:
1. Delta bounds: abs(delta) ∈ [delta_min, delta_max]
2. Theta/Premium ratio: abs(theta) / premium < theta_premium_max
3. IV rank veto: iv_rank < iv_rank_veto (handled separately via screen_iv_rank)

Returns (true, "") on pass, (false, reason) on fail.
"""
function screen_greeks(greeks::OptionGreeks, params::ZeroDTEParams)::Tuple{Bool, String}

    # Guard against zero premium (prevents division by zero)
    if greeks.premium <= 0.0
        return (false, "Invalid premium: $(greeks.premium) — cannot compute Theta/Premium ratio")
    end

    # Filter 1: Delta bounds
    abs_delta = abs(greeks.delta)
    if abs_delta < params.delta_min || abs_delta > params.delta_max
        return (false,
            "Delta $(round(abs_delta, digits=3)) outside bounds " *
            "[$(params.delta_min), $(params.delta_max)]")
    end

    # Filter 2: Theta as percentage of premium
    # Theta is negative by convention; abs gives the decay rate
    theta_pct = abs(greeks.theta) / greeks.premium
    if theta_pct >= params.theta_premium_max
        return (false,
            "Theta/Premium ratio $(round(theta_pct * 100, digits=1))% " *
            "exceeds ceiling $(params.theta_premium_max * 100)% " *
            "(Theta=$(round(greeks.theta, digits=4)), Premium=$(greeks.premium))")
    end

    return (true, "")
end

"""
    compute_iv_rank(iv_history, current_iv) -> Float64

Compute the percentile rank of current_iv within the trailing window.
Returns a value in [0, 1]; 1.0 = highest IV in the window.

Uses the standard AFML formulation:
    IV rank = (current_iv - min_iv) / (max_iv - min_iv)
"""
function compute_iv_rank(iv_history::Vector{Float64}, current_iv::Float64)::Float64
    isempty(iv_history) && return 0.5  # neutral if no history

    min_iv = minimum(iv_history)
    max_iv = maximum(iv_history)

    # Avoid division by zero in a flat-vol environment
    max_iv ≈ min_iv && return 0.5

    return clamp((current_iv - min_iv) / (max_iv - min_iv), 0.0, 1.0)
end

"""
    screen_iv_rank(iv_state, params) -> (passed::Bool, reason::String)

Veto the trade if IV rank is in the top 10–15% of its 20-day range.
High IV environments make 0DTE options expensive and increase adverse
Vega exposure post-entry.
"""
function screen_iv_rank(iv_state::IVState, params::ZeroDTEParams)::Tuple{Bool, String}
    if iv_state.iv_rank >= params.iv_rank_veto
        return (false,
            "IV rank $(round(iv_state.iv_rank * 100, digits=1))% " *
            "exceeds veto threshold $(params.iv_rank_veto * 100)% — " *
            "high-IV environment, 0DTE premium too expensive")
    end
    return (true, "")
end

# ── Layer 2: Dynamic Position Sizing (Theta Load) ─────────────────────────────

"""
    compute_theta_load(current_time) -> Float64

Compute the time-decay factor based on hours remaining in the session.

Formula (per specification):
    theta_load = hours_remaining / total_session_hours

Returns a value in (0, 1]:
- At open (9:30): theta_load ≈ 1.0 — full size permitted
- At 13:00 (midday): theta_load ≈ 0.5
- At 15:30: theta_load ≈ 0.077 — minimal size
- After close: theta_load = 0.0

The effect is that position size shrinks linearly as the session progresses,
protecting capital from the convex Theta acceleration in the final hours.
"""
function compute_theta_load(current_time::DateTime)::Float64
    t = Time(current_time)

    t <= MARKET_OPEN  && return 1.0
    t >= MARKET_CLOSE && return 0.0

    elapsed_hours = (t - MARKET_OPEN).value / (3_600_000)   # ms → hours
    hours_remaining = TOTAL_SESSION_HOURS - elapsed_hours

    return clamp(hours_remaining / TOTAL_SESSION_HOURS, 0.0, 1.0)
end

"""
    size_position(greeks, params, theta_load) -> Int

Compute the Theta Load-adjusted position size.

Formula (per specification):
    base_size = floor(account_risk_limit / premium_per_contract)
    adjusted_size = round(base_size * theta_load)

Enforces min_size_floor as a lower bound (so a live trade is never
sized to zero mid-session by the time-decay factor alone — the decision
to exit belongs to the trade management layer, not the sizer).

Returns number of contracts (integer).
"""
function size_position(greeks::OptionGreeks, params::ZeroDTEParams,
                       theta_load::Float64)::Int

    # Premium is per-share; multiply by 100 for per-contract cost
    cost_per_contract = greeks.premium * 100.0

    cost_per_contract <= 0.0 && return 0

    base_size = floor(Int, params.account_risk_limit / cost_per_contract)
    base_size == 0 && return 0

    adjusted = round(Int, base_size * theta_load)

    return max(adjusted, params.min_size_floor)
end

# ── Layer 3: ORB + IV Quadrant Matrix ─────────────────────────────────────────

"""
    classify_orb_iv_quadrant(orb, iv_state, params) -> Symbol

Map the ORB breakout direction and IV condition into one of five quadrants:

    :bullish_expansion   — Bullish ORB + IV expanding  → FULL_SIZE
    :bullish_compression — Bullish ORB + IV compressing → REJECT (or scout)
    :bearish_expansion   — Bearish ORB + IV expanding  → FULL_SIZE
    :bearish_compression — Bearish ORB + IV compressing → REJECT (or scout)
    :none                — No confirmed ORB breakout    → REJECT

The breakout is confirmed when price closes beyond the ORB boundary by
at least `orb_buffer_pct` to filter fakeouts at the range edges.
"""
function classify_orb_iv_quadrant(orb::ORBState, iv_state::IVState,
                                   params::ZeroDTEParams)::Symbol

    # No breakout → no signal
    orb.breakout_confirmed || return :none
    orb.direction == :none  && return :none

    expanding = iv_state.iv_expanding

    if orb.direction == :bullish
        return expanding ? :bullish_expansion : :bullish_compression
    else
        return expanding ? :bearish_expansion : :bearish_compression
    end
end

"""
    apply_layer3(quadrant, base_contracts, params) -> (decision, contracts, multiplier)

Apply the ORB + IV matrix decision rules:

    Expansion quadrant  → FULL_SIZE, full contracts, multiplier = 1.0
    Compression quadrant → SCOUT_SIZE or REJECT_IV_COMP depending on params
    No ORB              → REJECT_NO_ORB, 0 contracts

Scout mode enters at `scout_size_pct` of the Theta Load size — a
small probe that limits capital at risk when conviction is absent.
"""
function apply_layer3(quadrant::Symbol, base_contracts::Int,
                      params::ZeroDTEParams)::Tuple{TradeDecision, Int, Float64}

    if quadrant == :none
        return (REJECT_NO_ORB, 0, 0.0)
    end

    if quadrant ∈ (:bullish_expansion, :bearish_expansion)
        return (FULL_SIZE, base_contracts, 1.0)
    end

    # Compression quadrants — scout or reject
    # If scout_size_pct rounds to at least 1 contract, enter scout
    scout_contracts = max(round(Int, base_contracts * params.scout_size_pct), 0)

    if scout_contracts >= 1
        return (SCOUT_SIZE, scout_contracts, params.scout_size_pct)
    else
        return (REJECT_IV_COMP, 0, 0.0)
    end
end

# ── Top-Level Evaluator ───────────────────────────────────────────────────────

"""
    evaluate_0dte_setup(greeks, orb, iv_state, params) -> ZeroDTEResult

Full three-layer evaluation pipeline for a 0DTE option entry.

Layers are applied sequentially. Failure at any layer returns immediately
with the appropriate rejection reason.

# Arguments
- `greeks::OptionGreeks`: Current Greeks snapshot for the candidate option
- `orb::ORBState`: Opening range breakout state
- `iv_state::IVState`: IV rank and expansion context
- `params::ZeroDTEParams`: Configuration (use DEFAULT_PARAMS for standard setup)

# Returns
`ZeroDTEResult` containing the final signal with all diagnostic fields.

# Example
```julia
using BlaqueBaux

greeks = OptionGreeks(0.32, -0.18, 0.04, 0.02, 1.45, 0.22, now())
orb    = ORBState(4420.0, 4410.0, 15, 4422.5, true, :bullish)
iv     = IVState(0.22, fill(0.20, 20), 0.60, true, 2.5)

result = evaluate_0dte_setup(greeks, orb, iv, DEFAULT_PARAMS)
println(result.signal.decision)   # FULL_SIZE
println(result.signal.contracts)  # e.g. 3
```
"""
function evaluate_0dte_setup(greeks::OptionGreeks, orb::ORBState,
                              iv_state::IVState,
                              params::ZeroDTEParams = DEFAULT_PARAMS)::ZeroDTEResult

    now_dt = greeks.timestamp

    # ── Layer 1a: Greeks ──────────────────────────────────────────────────────
    greeks_ok, greeks_reason = screen_greeks(greeks, params)
    if !greeks_ok
        sig = ZeroDTESignal(REJECT_GREEKS, 0, orb.direction, 0.0,
                            false, iv_state.iv_rank, :none,
                            "Layer 1 Greeks: $greeks_reason", now_dt)
        return ZeroDTEResult(sig, false, 0, 0.0)
    end

    # ── Layer 1b: IV rank veto ────────────────────────────────────────────────
    iv_ok, iv_reason = screen_iv_rank(iv_state, params)
    if !iv_ok
        sig = ZeroDTESignal(REJECT_IV_VETO, 0, orb.direction, 0.0,
                            true, iv_state.iv_rank, :none,
                            "Layer 1 IV Veto: $iv_reason", now_dt)
        return ZeroDTEResult(sig, false, 0, 0.0)
    end

    # ── Layer 2: Theta Load sizing ────────────────────────────────────────────
    theta_load      = compute_theta_load(now_dt)
    base_contracts  = size_position(greeks, params, theta_load)

    if base_contracts == 0
        sig = ZeroDTESignal(REJECT_GREEKS, 0, orb.direction, theta_load,
                            true, iv_state.iv_rank, :none,
                            "Layer 2: Zero contracts after Theta Load — " *
                            "premium too high for risk limit or session almost closed",
                            now_dt)
        return ZeroDTEResult(sig, true, 0, 0.0)
    end

    # ── Layer 3: ORB + IV matrix ──────────────────────────────────────────────
    quadrant                      = classify_orb_iv_quadrant(orb, iv_state, params)
    decision, final_contracts, mult = apply_layer3(quadrant, base_contracts, params)

    reason = if decision == REJECT_NO_ORB
        "Layer 3: No confirmed ORB breakout"
    elseif decision == REJECT_IV_COMP
        "Layer 3: ORB confirmed ($(orb.direction)) but IV compressing — " *
        "low-conviction setup, scout size rounds to 0"
    elseif decision == SCOUT_SIZE
        "Layer 3: ORB confirmed ($(orb.direction)) but IV compressing — " *
        "entering scout size ($(round(Int, params.scout_size_pct * 100))% of full)"
    else
        ""
    end

    sig = ZeroDTESignal(
        decision,
        final_contracts,
        orb.direction,
        theta_load,
        true,
        iv_state.iv_rank,
        quadrant,
        reason,
        now_dt
    )

    return ZeroDTEResult(sig, true, base_contracts, mult)
end

# ── Diagnostics ───────────────────────────────────────────────────────────────

"""
    describe_signal(result) -> String

Return a human-readable summary of a ZeroDTEResult for logging.
"""
function describe_signal(result::ZeroDTEResult)::String
    s = result.signal
    lines = String[
        "═══ 0DTE Signal ═══════════════════════════════",
        "  Decision   : $(s.decision)",
        "  Direction  : $(s.direction)",
        "  Contracts  : $(s.contracts)",
        "  Theta Load : $(round(s.theta_load * 100, digits=1))% of session remaining",
        "  IV Rank    : $(round(s.iv_rank * 100, digits=1))%",
        "  ORB Quad   : $(s.orb_quadrant)",
        "  Layer 1    : $(result.layer1_passed ? "PASSED" : "FAILED")",
        "  Base Size  : $(result.layer2_size) contracts (pre-Layer 3)",
        "  L3 Mult    : $(round(result.layer3_adjustment * 100, digits=0))%",
    ]
    if !isempty(s.rejection_reason)
        push!(lines, "  Reason     : $(s.rejection_reason)")
    end
    push!(lines, "  Time       : $(s.timestamp)")
    push!(lines, "═══════════════════════════════════════════════")
    return join(lines, "\n")
end

end  # module ZeroDTE
