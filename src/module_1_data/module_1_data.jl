module DataIngestion

using Dates, DataFrames, HTTP, JSON3, CSV, TimeZones

export FeedConfig, Observation, MarketState,
       fetch_and_normalize, is_stale, count_stale_signals,
       normalize_vix, normalize_iv_rank, normalize_vix_vxv_ratio,
       vix1d_unavailable_handling,
       VIX, VXV, VVIX, VIX1D, IV_Rank_SPY, GSW, LW, OIS_SOFR_spread, TGA_balance

# ============================================================================
# Data Feed Types
# ============================================================================

abstract type DataFeed end
struct VIX <: DataFeed end
struct VXV <: DataFeed end
struct VVIX <: DataFeed end
struct VIX1D <: DataFeed end
struct IV_Rank_SPY <: DataFeed end
struct GSW <: DataFeed end
struct LW <: DataFeed end
struct OIS_SOFR_spread <: DataFeed end
struct TGA_balance <: DataFeed end

# ============================================================================
# Core Structures
# ============================================================================

"""
    FeedConfig

Configuration for a data feed including source URLs, expected update frequency,
and staleness detection thresholds.
"""
struct FeedConfig
    name::String
    primary_source::String
    backup_source::Union{Nothing,String}
    expected_cadence::Second
    staleness_threshold::Second
end

"""
    Observation

A single market observation with metadata including timestamp, value,
staleness flag, and data source identifier.
"""
struct Observation
    timestamp::ZonedDateTime
    value::Float64
    is_stale::Bool
    source::String
end

"""
    MarketState

Complete 11-dimensional market state vector container with derived metrics.
All fields are Observation types except derived ratio fields.
"""
struct MarketState
    timestamp::ZonedDateTime
    vix::Observation          # VIX spot
    vxv::Observation          # VXV (90-day implied vol)
    vvix::Observation         # VVIX (vol of vol)
    vix1d::Observation        # VIX1D (1-day implied vol)
    iv_rank::Observation      # IV Rank (SPY)
    gsw_2yr::Observation      # GSW 2-year yield
    gsw_10yr::Observation     # GSW 10-year yield
    gsw_30yr::Observation     # GSW 30-year yield
    ois_sofr_spread::Observation
    tga_balance::Observation
    vix_vxv_ratio::Float64    # Derived: VIX/VXV
    vix1d_available::Bool     # Flag for VIX1D data availability
end

# ============================================================================
# Feed Configuration Defaults
# ============================================================================

const DEFAULT_FEEDS = Dict(
    "VIX" => FeedConfig(
        "VIX", 
        "https://www.cboe.com/tradable_products/vix/vix_historical_data/",
        nothing,
        Second(86400),      # Daily
        Second(172800)      # 2 days stale threshold
    ),
    "VXV" => FeedConfig(
        "VXV",
        "https://www.cboe.com/tradable_products/vix/vxv/",
        nothing,
        Second(86400),
        Second(172800)
    ),
    "VVIX" => FeedConfig(
        "VVIX",
        "https://www.cboe.com/tradable_products/vix/vvix/",
        nothing,
        Second(86400),
        Second(172800)
    ),
    "VIX1D" => FeedConfig(
        "VIX1D",
        "https://www.cboe.com/tradable_products/vix/vix1d/",
        nothing,
        Second(86400),
        Second(86400)      # Stricter: 1 day
    ),
    "IV_Rank_SPY" => FeedConfig(
        "IV_Rank_SPY",
        "https://api.polygon.io/v2/aggs/ticker/SPY/options/",
        nothing,
        Second(86400),
        Second(172800)
    ),
    "GSW" => FeedConfig(
        "GSW",
        "https://www.federalreserve.gov/data/treasury-yields.htm",
        nothing,
        Second(86400),
        Second(259200)      # 3 days (Fed holidays)
    ),
    "OIS_SOFR" => FeedConfig(
        "OIS_SOFR",
        "https://www.newyorkfed.org/markets/reference-rates/sofr",
        nothing,
        Second(86400),
        Second(172800)
    ),
    "TGA" => FeedConfig(
        "TGA",
        "https://fiscaldata.treasury.gov/datasets/daily-treasury-statement/",
        nothing,
        Second(86400),
        Second(259200)
    )
)

# ============================================================================
# Fetch and Normalize Functions
# ============================================================================

"""
    fetch_and_normalize(::Type{VIX}, dt::ZonedDateTime) -> Observation

Fetch and normalize VIX data for the given timestamp.
Returns an Observation with normalized value.
"""
function fetch_and_normalize(::Type{VIX}, dt::ZonedDateTime)::Observation
    # In production: HTTP request to CBOE API
    # For now: simulated with placeholder logic
    config = DEFAULT_FEEDS["VIX"]

    # Simulated fetch - replace with actual HTTP call
    value = _simulate_fetch("VIX", dt)

    is_stale_flag = _check_staleness(dt, config)

    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{VXV}, dt::ZonedDateTime) -> Observation

Fetch and normalize VXV (90-day VIX) data.
"""
function fetch_and_normalize(::Type{VXV}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["VXV"]
    value = _simulate_fetch("VXV", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{VVIX}, dt::ZonedDateTime) -> Observation

Fetch and normalize VVIX (volatility of VIX) data.
"""
function fetch_and_normalize(::Type{VVIX}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["VVIX"]
    value = _simulate_fetch("VVIX", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{VIX1D}, dt::ZonedDateTime) -> Observation

Fetch and normalize VIX1D (1-day implied volatility) data.
Note: VIX1D may not be available for all historical dates.
"""
function fetch_and_normalize(::Type{VIX1D}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["VIX1D"]

    # VIX1D introduced ~2022, check availability
    if dt < ZonedDateTime(DateTime(2022, 7, 1), tz"America/New_York")
        return Observation(dt, NaN, true, "UNAVAILABLE")
    end

    value = _simulate_fetch("VIX1D", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{IV_Rank_SPY}, dt::ZonedDateTime) -> Observation

Fetch and normalize IV Rank for SPY options.
"""
function fetch_and_normalize(::Type{IV_Rank_SPY}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["IV_Rank_SPY"]
    value = _simulate_fetch("IV_Rank", dt)
    is_stale_flag = _check_staleness(dt, config)
    normalized = normalize_iv_rank(value)
    Observation(dt, normalized, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{GSW}, maturity::Int, dt::ZonedDateTime) -> Observation

Fetch and normalize GSW (Gürkaynak, Sack, Wright) yield for given maturity.
Valid maturities: 2, 10, 30 (years).
"""
function fetch_and_normalize(::Type{GSW}, maturity::Int, dt::ZonedDateTime)::Observation
    @assert maturity in [2, 10, 30] "GSW maturity must be 2, 10, or 30 years"

    config = DEFAULT_FEEDS["GSW"]
    value = _simulate_fetch("GSW_$(maturity)Y", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{LW}, maturity::Int, dt::ZonedDateTime) -> Observation

Fetch and normalize LW (Litterman-Scheinkman-Weiss) yield factor.
"""
function fetch_and_normalize(::Type{LW}, maturity::Int, dt::ZonedDateTime)::Observation
    # LW factors are derived from GSW curve, not directly fetched
    # This would typically call the yield curve construction first
    config = DEFAULT_FEEDS["GSW"]  # Uses same source
    value = _simulate_fetch("LW_$(maturity)Y", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{OIS_SOFR_spread}, dt::ZonedDateTime) -> Observation

Fetch and normalize OIS-SOFR spread.
"""
function fetch_and_normalize(::Type{OIS_SOFR_spread}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["OIS_SOFR"]
    value = _simulate_fetch("OIS_SOFR", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

"""
    fetch_and_normalize(::Type{TGA_balance}, dt::ZonedDateTime) -> Observation

Fetch and normalize Treasury General Account balance.
"""
function fetch_and_normalize(::Type{TGA_balance}, dt::ZonedDateTime)::Observation
    config = DEFAULT_FEEDS["TGA"]
    value = _simulate_fetch("TGA", dt)
    is_stale_flag = _check_staleness(dt, config)
    Observation(dt, value, is_stale_flag, config.primary_source)
end

# ============================================================================
# Staleness Detection
# ============================================================================

"""
    is_stale(obs::Observation, config::FeedConfig) -> Bool

Check if an observation is stale based on feed configuration.
Uses both the pre-computed flag and a threshold check.
"""
function is_stale(obs::Observation, config::FeedConfig)::Bool
    obs.is_stale && return true

    now_time = now(tz"America/New_York")
    age = now_time - obs.timestamp

    return age > config.staleness_threshold
end

"""
    count_stale_signals(state::MarketState) -> Int

Count the number of stale signals in a MarketState.
"""
function count_stale_signals(state::MarketState)::Int
    count = 0
    for field in [:vix, :vxv, :vvix, :vix1d, :iv_rank, 
                  :gsw_2yr, :gsw_10yr, :gsw_30yr, 
                  :ois_sofr_spread, :tga_balance]
        obs = getfield(state, field)
        if obs.is_stale
            count += 1
        end
    end
    return count
end

# ============================================================================
# Normalization Functions
# ============================================================================

"""
    normalize_vix(value::Float64, rolling_window::Int=252) -> Float64

Normalize VIX using log transform followed by z-score over rolling window.

# Arguments
- `value::Float64`: Raw VIX value
- `rolling_window::Int`: Window size for z-score calculation (default: 252 trading days)

# Returns
- Normalized VIX value (log VIX z-scored)
"""
function normalize_vix(value::Float64, rolling_window::Int=252)::Float64
    value <= 0 && return NaN

    log_vix = log(value)

    # In production: use actual rolling mean and std from historical data
    # For initialization, use approximate long-run VIX statistics
    # Long-run mean of log(VIX) ≈ 2.8, std ≈ 0.4
    historical_mean = 2.8
    historical_std = 0.4

    z_score = (log_vix - historical_mean) / historical_std

    return z_score
end

"""
    normalize_iv_rank(value::Float64) -> Float64

Normalize IV Rank to [0, 100] range.
IV Rank = (current IV - 52w low) / (52w high - 52w low) * 100
"""
function normalize_iv_rank(value::Float64)::Float64
    clamp(value, 0.0, 100.0)
end

"""
    normalize_vix_vxv_ratio(vix::Float64, vxv::Float64) -> Float64

Normalize VIX/VXV ratio to [0, 1] range.
Typical range [0.7, 1.3] is mapped to [0, 1].

# Interpretation
- < 0.9: Contango (calm/forward-looking calm)
- 0.9 - 1.1: Transition
- > 1.1: Backwardation (stress/elevated near-term fear)
"""
function normalize_vix_vxv_ratio(vix::Float64, vxv::Float64)::Float64
    vxv <= 0 && return 0.5  # Neutral if invalid

    ratio = vix / vxv
    clamp((ratio - 0.7) / (1.3 - 0.7), 0.0, 1.0)
end

# ============================================================================
# Fallback Handling
# ============================================================================

"""
    vix1d_unavailable_handling(state::MarketState) -> MarketState

Handle case where VIX1D is unavailable by setting flag and excluding
Vol PC₃ from downstream calculations.

Returns a new MarketState with vix1d_available = false.
"""
function vix1d_unavailable_handling(state::MarketState)::MarketState
    if state.vix1d.is_stale || isnan(state.vix1d.value)
        new_vix1d = Observation(
            state.vix1d.timestamp,
            NaN,
            true,
            "FALLBACK_UNAVAILABLE"
        )

        return MarketState(
            state.timestamp,
            state.vix, state.vxv, state.vvix, new_vix1d,
            state.iv_rank, state.gsw_2yr, state.gsw_10yr, state.gsw_30yr,
            state.ois_sofr_spread, state.tga_balance,
            state.vix_vxv_ratio,
            false  # vix1d_available = false
        )
    end

    return state
end

# ============================================================================
# Complete Market State Assembly
# ============================================================================

"""
    assemble_market_state(dt::ZonedDateTime) -> MarketState

Fetch all data feeds and assemble into a complete MarketState.
This is the main entry point for data ingestion.
"""
function assemble_market_state(dt::ZonedDateTime)::MarketState
    vix_obs = fetch_and_normalize(VIX, dt)
    vxv_obs = fetch_and_normalize(VXV, dt)
    vvix_obs = fetch_and_normalize(VVIX, dt)
    vix1d_obs = fetch_and_normalize(VIX1D, dt)
    iv_rank_obs = fetch_and_normalize(IV_Rank_SPY, dt)
    gsw_2yr_obs = fetch_and_normalize(GSW, 2, dt)
    gsw_10yr_obs = fetch_and_normalize(GSW, 10, dt)
    gsw_30yr_obs = fetch_and_normalize(GSW, 30, dt)
    ois_sofr_obs = fetch_and_normalize(OIS_SOFR_spread, dt)
    tga_obs = fetch_and_normalize(TGA_balance, dt)

    vix_vxv = normalize_vix_vxv_ratio(vix_obs.value, vxv_obs.value)
    vix1d_avail = !(vix1d_obs.is_stale || isnan(vix1d_obs.value))

    state = MarketState(
        dt,
        vix_obs, vxv_obs, vvix_obs, vix1d_obs,
        iv_rank_obs, gsw_2yr_obs, gsw_10yr_obs, gsw_30yr_obs,
        ois_sofr_obs, tga_obs,
        vix_vxv, vix1d_avail
    )

    # Apply fallback if VIX1D unavailable
    return vix1d_unavailable_handling(state)
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

"""
    _simulate_fetch(feed_name::String, dt::ZonedDateTime) -> Float64

Simulated data fetch for development/testing.
In production, replace with actual HTTP/API calls.
"""
function _simulate_fetch(feed_name::String, dt::ZonedDateTime)::Float64
    # Deterministic pseudo-random values based on date for reproducibility
    seed = Dates.dayofyear(dt) + Dates.year(dt) * 365
    rng = MersenneTwister(seed)

    base_values = Dict(
        "VIX" => 20.0,
        "VXV" => 22.0,
        "VVIX" => 95.0,
        "VIX1D" => 18.0,
        "IV_Rank" => 45.0,
        "GSW_2Y" => 4.5,
        "GSW_10Y" => 4.2,
        "GSW_30Y" => 4.4,
        "OIS_SOFR" => 0.05,
        "TGA" => 500.0,
        "LW_2Y" => 4.5,
        "LW_10Y" => 4.2,
        "LW_30Y" => 4.4
    )

    base = get(base_values, feed_name, 50.0)
    noise = randn(rng) * base * 0.1

    return max(0.01, base + noise)
end

"""
    _check_staleness(dt::ZonedDateTime, config::FeedConfig) -> Bool

Check if data for given timestamp would be stale.
"""
function _check_staleness(dt::ZonedDateTime, config::FeedConfig)::Bool
    now_time = now(tz"America/New_York")
    age = now_time - dt
    return age > config.staleness_threshold
end

end  # module DataIngestion
