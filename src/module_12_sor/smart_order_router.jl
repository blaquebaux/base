module SmartOrderRouter

# ============================================================================
# SMART ORDER ROUTER — cuOpt-backed venue routing
# Gap 5 — replaces single-venue IBKR default routing with GPU-optimized SOR
#
# Architecture:
#   Julia SOR (this module) ←→ Python cuOpt bridge (cuopt_bridge.py)
#
# Julia handles: venue state, routing cache, decision logic, IBKR dispatch
# cuOpt handles: LP solve — minimize cost(fill_price, fee, impact) subject
#                to quantity constraints across venues
#
# Routing cache strategy (venue footprint minimization):
#   Pre-compute at 09:30 (session open) using overnight spread/depth data.
#   Recompute when any venue's spread or depth deviates > threshold from cache.
#   This avoids solving a fresh LP on every order — the cache answer is valid
#   until market microstructure shifts meaningfully.
#
# For NVDA: primary venues are SMART (IBKR routing), ARCA, NASDAQ, NYSE ARCA.
# cuOpt solves the minimum-cost allocation across these in <5ms on Alienware GPU.
# ============================================================================

using Dates, Statistics, Logging, JSON3, HTTP

export Venue, VenueQuote, SORConfig, RoutingCache, SORResult,
       update_venue_quote!, build_routing_cache, route_order,
       should_recompute_cache, SORDecision

# ── Types ─────────────────────────────────────────────────────────────────────

"""
    Venue

A trading venue (exchange or ATS) with its routing characteristics.

# Fields
- `id::String`: Venue identifier used by IBKR ("ARCA", "NASDAQ", "NYSE", "SMART")
- `fee_per_share::Float64`: Exchange fee in \$/share (negative = rebate)
- `min_lot::Int`: Minimum order size in shares
- `priority::Int`: Tie-breaking priority (lower = preferred)
"""
struct Venue
    id::String
    fee_per_share::Float64
    min_lot::Int
    priority::Int
end

# Standard US equity venues for NVDA routing
const DEFAULT_VENUES = [
    Venue("SMART",  0.0000, 1, 1),   # IBKR SMART routing (default, lowest friction)
    Venue("ARCA",   0.0030, 100, 2), # NYSE ARCA
    Venue("NASDAQ", 0.0030, 100, 3), # NASDAQ
    Venue("BYX",   -0.0020, 100, 4), # CBOE BYX (maker rebate)
]

"""
    VenueQuote

Real-time quote snapshot for one venue.
Updated continuously from market data feed.
"""
mutable struct VenueQuote
    venue_id::String
    bid::Float64
    ask::Float64
    bid_size::Int        # shares available at bid
    ask_size::Int        # shares available at ask
    last_updated::DateTime
    is_stale::Bool       # true if not updated in last 30 seconds
end

function VenueQuote(venue_id::String)
    VenueQuote(venue_id, NaN, NaN, 0, 0, DateTime(0), true)
end

"""
    SORConfig

Configuration for the Smart Order Router.

# Fields
- `venues::Vector{Venue}`: Venues to route across
- `recompute_threshold::Float64`: Spread/depth deviation fraction that triggers
    cache recomputation (default: 0.05 = 5% change in best spread or depth)
- `max_impact_pct::Float64`: Refuse a venue if expected impact > this fraction of price
- `cuopt_endpoint::String`: URL of the cuOpt Python bridge service
- `use_gpu::Bool`: Whether to invoke cuOpt (true) or use CPU fallback (false)
- `cache_ttl_seconds::Int`: Force recompute after this many seconds regardless
"""
struct SORConfig
    venues::Vector{Venue}
    recompute_threshold::Float64
    max_impact_pct::Float64
    cuopt_endpoint::String
    use_gpu::Bool
    cache_ttl_seconds::Int
end

function SORConfig(;
    venues::Vector{Venue}       = DEFAULT_VENUES,
    recompute_threshold::Float64 = 0.05,
    max_impact_pct::Float64     = 0.001,
    cuopt_endpoint::String      = get(ENV, "CUOPT_ENDPOINT", "http://127.0.0.1:8765/route"),
    use_gpu::Bool               = true,
    cache_ttl_seconds::Int      = 300
)
    SORConfig(venues, recompute_threshold, max_impact_pct,
              cuopt_endpoint, use_gpu, cache_ttl_seconds)
end

"""
    RoutingCache

Holds the last solved routing plan and the venue state at solve time.
Used to detect when re-solving is needed.
"""
mutable struct RoutingCache
    venue_quotes_at_solve::Dict{String, VenueQuote}
    allocation::Dict{String, Float64}    # venue_id → fraction of order [0,1]
    solved_at::DateTime
    is_valid::Bool
end

function RoutingCache()
    RoutingCache(Dict(), Dict(), DateTime(0), false)
end

"""
    SORDecision

Routing decision for a single order.

# Fields
- `allocations::Dict{String,Int}`: venue_id → shares to send
- `expected_cost::Float64`: estimated total cost in \$/share
- `method::Symbol`: :cuopt_gpu, :cpu_fallback, or :single_venue
- `cache_hit::Bool`: true if routing plan came from cache (no re-solve)
"""
struct SORDecision
    allocations::Dict{String,Int}
    expected_cost::Float64
    method::Symbol
    cache_hit::Bool
    timestamp::DateTime
end

"""
    SORResult

Full routing result with venue fill tracking.
"""
mutable struct SORResult
    decision::SORDecision
    fills_received::Dict{String,Float64}   # venue_id → avg fill price
    is_complete::Bool
end

# ── Venue quote management ────────────────────────────────────────────────────

"""
    update_venue_quote!(quote, bid, ask, bid_size, ask_size)

Update a venue quote from live market data. Call from the IBKR market
data callback for each venue's Level II feed.
"""
function update_venue_quote!(
    q::VenueQuote,
    bid::Float64, ask::Float64,
    bid_size::Int, ask_size::Int
)
    q.bid          = bid
    q.ask          = ask
    q.bid_size     = bid_size
    q.ask_size     = ask_size
    q.last_updated = now(UTC)
    q.is_stale     = false
end

"""
    should_recompute_cache(cache, current_quotes, config) -> Bool

Returns true when the routing cache should be re-solved:
- Cache is invalid (first solve, or after TTL)
- Any venue's spread or available depth has deviated > recompute_threshold
  from the state at last solve time
"""
function should_recompute_cache(
    cache::RoutingCache,
    current_quotes::Dict{String,VenueQuote},
    config::SORConfig
)::Bool
    !cache.is_valid && return true

    # TTL check
    age = (now(UTC) - cache.solved_at).value / 1000   # seconds
    age > config.cache_ttl_seconds && return true

    # Microstructure deviation check
    for (vid, q_now) in current_quotes
        q_was = get(cache.venue_quotes_at_solve, vid, nothing)
        q_was === nothing && continue
        q_was.is_stale && continue

        spread_now = q_now.ask - q_now.bid
        spread_was = q_was.ask - q_was.bid

        spread_was > 0 && abs(spread_now - spread_was) / spread_was > config.recompute_threshold && return true
        q_was.ask_size > 0 && abs(q_now.ask_size - q_was.ask_size) / q_was.ask_size > config.recompute_threshold && return true
    end

    return false
end

# ── Routing solve ──────────────────────────────────────────────────────────────

"""
    build_routing_cache(quotes, total_qty, config) -> RoutingCache

Solve the venue allocation LP and update the cache.
Tries cuOpt GPU first; falls back to CPU greedy if cuOpt is unavailable.

The LP solved by cuOpt:
  minimize  Σ_v  (fee_v + impact_v(qty_v)) * qty_v
  subject to:
    Σ_v qty_v = total_qty
    0 ≤ qty_v ≤ available_depth_v  ∀v
    qty_v ≥ min_lot_v  if qty_v > 0

cuOpt reformulates this as a Vehicle Routing Problem with capacity constraints.
Each venue is a "stop" with a capacity equal to its available depth.
"""
function build_routing_cache(
    quotes::Dict{String, VenueQuote},
    total_qty::Int,
    config::SORConfig
)::RoutingCache

    allocation = if config.use_gpu
        _solve_cuopt(quotes, total_qty, config)
    else
        nothing
    end

    if allocation === nothing
        @warn "cuOpt unavailable — using CPU greedy fallback"
        allocation = _solve_greedy(quotes, total_qty, config)
    end

    cache = RoutingCache()
    cache.venue_quotes_at_solve = Dict(vid => deepcopy(q) for (vid,q) in quotes)
    cache.allocation   = allocation
    cache.solved_at    = now(UTC)
    cache.is_valid     = true

    @info "Routing cache built" n_venues=length(allocation) method=(config.use_gpu ? "cuopt" : "greedy")
    return cache
end

"""
    route_order(total_qty, side, quotes, cache, config) -> SORDecision

Convert a routing cache (fractional allocations) into a concrete order split
(integer shares per venue). Updates cache if microstructure has deviated.

# Arguments
- `total_qty::Int`: Total shares to route
- `side::String`: "BUY" or "SELL"
- `quotes::Dict{String,VenueQuote}`: Current venue quotes
- `cache::RoutingCache`: Current routing cache (may be rebuilt in-place)
- `config::SORConfig`: SOR configuration
"""
function route_order(
    total_qty::Int,
    side::String,
    quotes::Dict{String, VenueQuote},
    cache::RoutingCache,
    config::SORConfig
)::SORDecision

    cache_hit = !should_recompute_cache(cache, quotes, config)

    if !cache_hit
        new_cache = build_routing_cache(quotes, total_qty, config)
        # Mutate cache fields in place (caller holds the same reference)
        cache.venue_quotes_at_solve = new_cache.venue_quotes_at_solve
        cache.allocation            = new_cache.allocation
        cache.solved_at             = new_cache.solved_at
        cache.is_valid              = new_cache.is_valid
    end

    # Convert fractional allocation to integer shares
    price_field = side == "BUY" ? :ask : :bid
    allocations = Dict{String,Int}()
    remaining   = total_qty

    # Sort venues by priority, then by cost
    sorted_venues = sort(collect(keys(cache.allocation)),
                         by = v -> (get(config.venues, findfirst(x->x.id==v, config.venues), Venue(v,0.0,1,99)).priority))

    for (i, vid) in enumerate(sorted_venues)
        frac = get(cache.allocation, vid, 0.0)
        frac <= 0 && continue

        # Last venue absorbs the rounding remainder
        shares = i == length(sorted_venues) ? remaining :
                 min(remaining, round(Int, frac * total_qty))
        shares <= 0 && continue

        # Enforce min_lot
        venue = findfirst(x -> x.id == vid, config.venues)
        if venue !== nothing
            min_lot = config.venues[venue].min_lot
            shares < min_lot && (shares = 0)
        end

        allocations[vid] = shares
        remaining       -= shares
        remaining <= 0  && break
    end

    # If rounding left residual, add to highest-priority venue
    if remaining > 0 && !isempty(sorted_venues)
        vid = first(sorted_venues)
        allocations[vid] = get(allocations, vid, 0) + remaining
    end

    # Estimated cost
    expected_cost = _estimate_cost(allocations, quotes, config, side)

    return SORDecision(
        allocations, expected_cost,
        (cache_hit ? :cache_hit : (config.use_gpu ? :cuopt_gpu : :cpu_fallback)),
        cache_hit, now(UTC)
    )
end

# ── cuOpt bridge ──────────────────────────────────────────────────────────────

"""
    _solve_cuopt(quotes, total_qty, config) -> Union{Dict{String,Float64}, Nothing}

Call the Python cuOpt bridge service (cuopt_bridge.py) via HTTP POST.
The bridge translates the routing problem to cuOpt's LP formulation and
solves it on the GPU, returning fractional allocations per venue.

Returns nothing if the bridge is unreachable or returns an error.

The bridge payload schema:
```json
{
  "total_qty": 500,
  "venues": [
    {"id": "ARCA", "depth": 1000, "spread": 0.02, "fee": 0.003},
    ...
  ]
}
```

Response schema:
```json
{
  "allocations": {"ARCA": 0.6, "NASDAQ": 0.4},
  "solve_time_ms": 2.3
}
```
"""
function _solve_cuopt(
    quotes::Dict{String,VenueQuote},
    total_qty::Int,
    config::SORConfig
)::Union{Dict{String,Float64}, Nothing}

    venues_payload = []
    for venue in config.venues
        q = get(quotes, venue.id, nothing)
        (q === nothing || q.is_stale) && continue
        spread = q.ask - q.bid
        depth  = venue.id == "BUY" ? q.ask_size : q.bid_size
        depth <= 0 && continue
        push!(venues_payload, Dict(
            "id"     => venue.id,
            "depth"  => depth,
            "spread" => spread,
            "fee"    => venue.fee_per_share
        ))
    end

    isempty(venues_payload) && return nothing

    payload = Dict("total_qty" => total_qty, "venues" => venues_payload)

    try
        resp = HTTP.post(
            config.cuopt_endpoint,
            ["Content-Type" => "application/json"],
            JSON3.write(payload);
            readtimeout = 5
        )
        resp.status != 200 && return nothing
        body = JSON3.read(String(resp.body))
        alloc = Dict{String,Float64}(string(k) => Float64(v)
                                     for (k,v) in body["allocations"])
        @info "cuOpt solve complete" solve_time_ms=get(body, "solve_time_ms", NaN) n_venues=length(alloc)
        return alloc
    catch e
        @debug "cuOpt bridge unavailable" exception=e endpoint=config.cuopt_endpoint
        return nothing
    end
end

"""
    _solve_greedy(quotes, total_qty, config) -> Dict{String,Float64}

CPU fallback: greedy best-price routing. Fills from the venue with the
lowest effective cost (spread/2 + fee) first, up to available depth,
then spills over to the next cheapest venue.

Not optimal but deterministic and GPU-free — used when cuOpt is
unavailable (Mac, or before Alienware GPU is warm).
"""
function _solve_greedy(
    quotes::Dict{String,VenueQuote},
    total_qty::Int,
    config::SORConfig
)::Dict{String,Float64}

    # Score each venue: lower effective cost = better
    scored = []
    for venue in config.venues
        q = get(quotes, venue.id, nothing)
        (q === nothing || q.is_stale) && continue
        spread = q.ask - q.bid
        effective_cost = spread / 2 + venue.fee_per_share
        capacity = max(q.ask_size, q.bid_size)
        capacity <= 0 && continue
        push!(scored, (venue.id, effective_cost, capacity))
    end

    sort!(scored, by = x -> x[2])

    allocation = Dict{String,Float64}()
    remaining  = Float64(total_qty)

    for (vid, _, capacity) in scored
        remaining <= 0 && break
        alloc = min(remaining, Float64(capacity))
        allocation[vid] = alloc / total_qty
        remaining -= alloc
    end

    # Normalize (rounding)
    total = sum(values(allocation))
    total > 0 && for k in keys(allocation); allocation[k] /= total; end

    return allocation
end

function _estimate_cost(
    allocations::Dict{String,Int},
    quotes::Dict{String,VenueQuote},
    config::SORConfig,
    side::String
)::Float64
    total_shares = sum(values(allocations))
    total_shares == 0 && return 0.0

    cost = 0.0
    for (vid, shares) in allocations
        q = get(quotes, vid, nothing)
        q === nothing && continue
        price = side == "BUY" ? q.ask : q.bid
        isnan(price) && continue
        venue = findfirst(x -> x.id == vid, config.venues)
        fee   = venue !== nothing ? config.venues[venue].fee_per_share : 0.0
        cost += shares * (price + fee * (side == "BUY" ? 1 : -1))
    end
    return total_shares > 0 ? cost / total_shares : NaN
end

end  # module SmartOrderRouter
