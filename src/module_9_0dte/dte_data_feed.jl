module DTEDataFeed

# ============================================================================
# 0DTE DATA FEED
# Gap 4 — live Greeks, ORB, and IV state construction for ZeroDTE module
#
# Bridges the gap between ibkr_connection.jl (raw market data callbacks)
# and ZeroDTE.evaluate_0dte_setup() (which needs structured OptionGreeks,
# ORBState, and IVState). Three responsibilities:
#
# 1. Greeks feed: subscribes to IBKR tick data for an option contract and
#    assembles a ZeroDTE.OptionGreeks struct from tickOptionComputation callbacks
#
# 2. ORB builder: consumes 1-min bar data from the first 30 minutes of the
#    session and produces a ZeroDTE.ORBState
#
# 3. IV history tracker: maintains a rolling 20-day window of daily ATM IV
#    and produces a ZeroDTE.IVState for rank computation
# ============================================================================

using Dates, Statistics, Logging, JSON3, HTTP

export GreeksTick, ORBBuilder, IVHistory,
       build_option_greeks, update_orb!, finalize_orb,
       update_iv_history!, build_iv_state,
       fetch_greeks_from_tick, build_0dte_inputs,
       scan_0dte_expirations, select_strikes

# ── Live Greeks from IBKR tick data ──────────────────────────────────────────

"""
    GreeksTick

Mutable accumulator for a single option contract's Greeks, populated by
IBKR's tickOptionComputation callbacks. One instance per option being tracked.

IBKR tick types for options Greeks:
  10 = Bid Greeks, 11 = Ask Greeks, 12 = Last Greeks, 13 = Model Greeks
Use tickType=13 (model) for the most stable greeks mid-session.
"""
mutable struct GreeksTick
    req_id::Int
    contract_symbol::String    # e.g., "NVDA  260530C01080000"
    underlying_symbol::String  # e.g., "NVDA"
    expiry::String
    strike::Float64
    right::String              # "C" or "P"

    # Populated by tickOptionComputation (tickType=13)
    delta::Float64
    theta::Float64             # per day, negative for long options
    vega::Float64
    gamma::Float64
    iv::Float64                # implied volatility (decimal, not percent)
    premium::Float64           # option price (last/model)
    timestamp::DateTime

    is_valid::Bool             # true once all fields have been populated
end

function GreeksTick(req_id::Int, underlying::String, expiry::String,
                    strike::Float64, right::String)
    GreeksTick(req_id, "", underlying, expiry, strike, right,
               NaN, NaN, NaN, NaN, NaN, NaN, DateTime(0), false)
end

"""
    fetch_greeks_from_tick(tick::GreeksTick) -> Union{ZeroDTEGreeks, Nothing}

Convert a populated GreeksTick into the OptionGreeks type used by ZeroDTE.
Returns nothing if the tick has not yet received all fields.

Theta convention: IBKR reports theta as dollars/day for one contract.
Convert to theta/premium ratio: (|theta| * 1) / premium
The ZeroDTE screen uses this ratio, not the raw dollar value.
"""
function fetch_greeks_from_tick(tick::GreeksTick)
    tick.is_valid || return nothing
    isnan(tick.delta) || isnan(tick.theta) || isnan(tick.premium) && return nothing
    tick.premium <= 0 && return nothing

    # Return a NamedTuple compatible with ZeroDTE.OptionGreeks constructor args
    return (
        delta     = abs(tick.delta),         # absolute value; direction handled by right/action
        theta     = abs(tick.theta),          # positive magnitude
        vega      = tick.vega,
        gamma     = tick.gamma,
        premium   = tick.premium,
        iv        = tick.iv,
        timestamp = tick.timestamp
    )
end

"""
    update_greeks_tick!(tick::GreeksTick, tick_type::Int,
                        price, delta, gamma, vega, theta, iv, ...)

Called from the Jib wrapper's tickOptionComputation callback. Populates the
GreeksTick when tickType == 13 (Model Greeks).

Wire this into the IBKR wrapper in ibkr_connection.jl:
```julia
tickOptionComputation = (reqId, tickType, tickAttrib, impliedVol,
                         delta, optPrice, pvDividend, gamma, vega, theta, undPrice) -> begin
    tick = get_tracked_tick(reqId)
    tick !== nothing && update_greeks_tick!(tick, tickType, optPrice, delta, gamma, vega, theta, impliedVol)
end
```
"""
function update_greeks_tick!(
    tick::GreeksTick,
    tick_type::Int,
    opt_price::Float64,
    delta::Float64,
    gamma::Float64,
    vega::Float64,
    theta::Float64,
    implied_vol::Float64
)
    # Only update from Model Greeks (tickType=13); Bid/Ask can be noisy
    tick_type != 13 && return

    any(isnan, [opt_price, delta, theta]) && return
    opt_price <= 0 && return

    tick.premium   = opt_price
    tick.delta     = delta
    tick.gamma     = gamma
    tick.vega      = vega
    tick.theta     = theta
    tick.iv        = implied_vol
    tick.timestamp = now(UTC)
    tick.is_valid  = true
end

# ── ORB Builder ───────────────────────────────────────────────────────────────

"""
    ORBBuilder

Accumulates 1-minute bar data for the first 30 minutes of the session
and produces a ZeroDTE.ORBState once the ORB window closes.

Session open: 09:30 ET. ORB window closes at 10:00 ET by default.
"""
mutable struct ORBBuilder
    symbol::String
    orb_close_time::Time    # default: Time(10, 0)
    range_high::Float64
    range_low::Float64
    last_price::Float64
    n_bars::Int
    is_established::Bool
end

function ORBBuilder(symbol::String; orb_minutes::Int = 30)
    close_time = Time(9, 30) + Minute(orb_minutes)
    ORBBuilder(symbol, close_time, -Inf, Inf, NaN, 0, false)
end

"""
    update_orb!(builder, bar_time, bar_high, bar_low, bar_close)

Feed a 1-minute bar into the ORB builder. Call this for every bar during
[09:30, orb_close_time). After orb_close_time, call finalize_orb().
"""
function update_orb!(
    builder::ORBBuilder,
    bar_time::Time,
    bar_high::Float64,
    bar_low::Float64,
    bar_close::Float64
)
    bar_time >= builder.orb_close_time && return  # ORB window closed
    builder.range_high = max(builder.range_high, bar_high)
    builder.range_low  = min(builder.range_low,  bar_low)
    builder.last_price = bar_close
    builder.n_bars    += 1
end

"""
    finalize_orb(builder, current_price, current_time; buffer_pct) -> NamedTuple

Called after orb_close_time. Returns a NamedTuple with the ORBState fields
used by ZeroDTE.classify_orb_iv_quadrant():
- `high`, `low`, `is_established`, `breakout_direction`, `current_price`

`breakout_direction`: +1 = bullish (price above ORB high), -1 = bearish
(price below ORB low), 0 = inside range.
"""
function finalize_orb(
    builder::ORBBuilder,
    current_price::Float64,
    current_time::DateTime;
    buffer_pct::Float64 = 0.001
)::NamedTuple
    t = Time(current_time)
    established = t >= builder.orb_close_time && builder.n_bars >= 5

    if !established || isinf(builder.range_high)
        return (high=NaN, low=NaN, is_established=false,
                breakout_direction=0, current_price=current_price,
                buffer_pct=buffer_pct)
    end

    buf_h = builder.range_high * (1 + buffer_pct)
    buf_l = builder.range_low  * (1 - buffer_pct)

    direction = if current_price > buf_h
        1    # bullish breakout
    elseif current_price < buf_l
        -1   # bearish breakdown
    else
        0    # inside range
    end

    return (
        high               = builder.range_high,
        low                = builder.range_low,
        is_established     = true,
        breakout_direction = direction,
        current_price      = current_price,
        buffer_pct         = buffer_pct
    )
end

# ── IV History tracker ────────────────────────────────────────────────────────

"""
    IVHistory

Rolling 20-day window of ATM IV for IV rank computation.
Persisted to disk between sessions so the 20-day window survives restarts.
"""
mutable struct IVHistory
    symbol::String
    daily_ivs::Vector{Float64}   # chronological, oldest first
    dates::Vector{Date}
    max_days::Int
    cache_path::String
end

function IVHistory(symbol::String; max_days::Int=20,
                   cache_dir::String=joinpath(homedir(), ".blaquebaux", "iv_cache"))
    mkpath(cache_dir)
    cache_path = joinpath(cache_dir, "$(symbol)_iv_history.json")
    hist = IVHistory(symbol, Float64[], Date[], max_days, cache_path)
    _load_iv_cache!(hist)
    return hist
end

"""
    update_iv_history!(hist, today_iv; date)

Record today's ATM IV. Call once daily at session close using the IV from
the nearest ATM option (typically the closest strike to the underlying price).
Maintains a rolling `max_days` window.
"""
function update_iv_history!(
    hist::IVHistory,
    today_iv::Float64;
    date::Date = today()
)
    isnan(today_iv) || today_iv <= 0 && return

    # Avoid duplicate entries for same date
    if !isempty(hist.dates) && last(hist.dates) == date
        hist.daily_ivs[end] = today_iv   # update today's entry
    else
        push!(hist.daily_ivs, today_iv)
        push!(hist.dates, date)
    end

    # Trim to max_days
    if length(hist.daily_ivs) > hist.max_days
        excess = length(hist.daily_ivs) - hist.max_days
        deleteat!(hist.daily_ivs, 1:excess)
        deleteat!(hist.dates,     1:excess)
    end

    _save_iv_cache(hist)
    @info "IV history updated" symbol=hist.symbol date=date iv=round(today_iv, digits=4) n_days=length(hist.daily_ivs)
end

"""
    build_iv_state(hist, current_iv) -> NamedTuple

Produces the IVState NamedTuple consumed by ZeroDTE.screen_iv_rank()
and classify_orb_iv_quadrant().

Fields:
- `iv_history`: full 20-day history vector
- `current_iv`: today's current IV reading
- `iv_rank`: percentile of current_iv in the 20-day window [0,1]
- `is_expanding`: true if current_iv > median of last 5 days
"""
function build_iv_state(hist::IVHistory, current_iv::Float64)::NamedTuple
    ivs = hist.daily_ivs

    if isempty(ivs) || isnan(current_iv)
        return (iv_history=Float64[], current_iv=current_iv,
                iv_rank=0.5, is_expanding=false)
    end

    # IV rank: fraction of history below current_iv
    iv_rank = count(v -> v < current_iv, ivs) / length(ivs)

    # IV expanding: compare current to median of recent 5 bars
    recent = length(ivs) >= 5 ? ivs[end-4:end] : ivs
    is_expanding = current_iv > median(recent)

    return (
        iv_history   = copy(ivs),
        current_iv   = current_iv,
        iv_rank      = iv_rank,
        is_expanding = is_expanding
    )
end

# ── Option chain scanning ─────────────────────────────────────────────────────

"""
    scan_0dte_expirations(symbol; today_date) -> Vector{String}

Return 0DTE expiry strings for `symbol` on `today_date`.
For US equities: only Mondays/Wednesdays/Fridays have weekly expirations
(and daily for SPY/QQQ/SPX). For NVDA, only Fridays unless weeklies exist.

In production: replace with reqSecDefOptParams callback results.
This helper provides a date-based fallback.
"""
function scan_0dte_expirations(
    symbol::String;
    today_date::Date = today()
)::Vector{String}
    dow = dayofweek(today_date)   # 1=Mon, 5=Fri

    # NVDA has weekly expirations on Fridays
    # Major ETFs (SPY, QQQ) have Mon/Wed/Fri
    weekly_symbols = Set(["SPY", "QQQ", "IWM", "GLD", "SLV"])
    daily_symbols  = Set(["SPX", "SPXW", "NDX"])

    has_today = if symbol in daily_symbols
        true
    elseif symbol in weekly_symbols
        dow in (1, 3, 5)   # Mon, Wed, Fri
    else
        dow == 5            # Fridays only for single stocks
    end

    has_today || return String[]

    expiry_str = Dates.format(today_date, "yyyymmdd")
    return [expiry_str]
end

"""
    select_strikes(underlying_price, n_strikes; step) -> Vector{Float64}

Return `n_strikes` strikes centered on `underlying_price`, rounded to `step`.
Used to select which option contracts to track for 0DTE.
"""
function select_strikes(
    underlying_price::Float64,
    n_strikes::Int = 5;
    step::Float64 = 2.5
)::Vector{Float64}
    atm = round(underlying_price / step) * step
    half = n_strikes ÷ 2
    return [atm + step * k for k in -half:half]
end

# ── Integrated input builder ──────────────────────────────────────────────────

"""
    build_0dte_inputs(
        greeks_tick, orb_builder, iv_hist, current_price, current_time;
        buffer_pct
    ) -> Union{NamedTuple, Nothing}

Top-level convenience function. Assembles all three ZeroDTE inputs
from live data sources and returns them as a named tuple ready for:

```julia
(greeks, orb, iv_state) = build_0dte_inputs(...)
result = ZeroDTE.evaluate_0dte_setup(greeks, orb, iv_state)
```

Returns `nothing` if Greeks or ORB are not yet valid.
"""
function build_0dte_inputs(
    greeks_tick::GreeksTick,
    orb_builder::ORBBuilder,
    iv_hist::IVHistory,
    current_price::Float64,
    current_time::DateTime;
    buffer_pct::Float64 = 0.001
)::Union{NamedTuple, Nothing}

    # Greeks
    g = fetch_greeks_from_tick(greeks_tick)
    g === nothing && return nothing

    # ORB
    orb = finalize_orb(orb_builder, current_price, current_time;
                        buffer_pct=buffer_pct)
    !orb.is_established && return nothing

    # IV state
    iv_state = build_iv_state(iv_hist, greeks_tick.iv)

    return (greeks=g, orb=orb, iv_state=iv_state)
end

# ── Cache I/O ─────────────────────────────────────────────────────────────────

function _save_iv_cache(hist::IVHistory)
    payload = Dict("symbol" => hist.symbol,
                   "dates"  => string.(hist.dates),
                   "ivs"    => hist.daily_ivs)
    open(hist.cache_path, "w") do f
        JSON3.write(f, payload)
    end
end

function _load_iv_cache!(hist::IVHistory)
    isfile(hist.cache_path) || return
    try
        payload = JSON3.read(read(hist.cache_path, String))
        hist.dates     = Date.(payload["dates"])
        hist.daily_ivs = Float64.(payload["ivs"])
    catch e
        @warn "IV cache load failed" path=hist.cache_path exception=e
    end
end

end  # module DTEDataFeed
