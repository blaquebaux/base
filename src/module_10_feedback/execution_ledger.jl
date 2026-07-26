module ExecutionLedger

# ============================================================================
# EXECUTION LEDGER
# Circular Futures Cascade Signal Gap — Layer 1 & 2 Foundation
#
# Responsibility: persist every confirmed fill with enough metadata to
# (a) flag which return intervals are endogenously contaminated (Layer 1)
# (b) estimate and subtract market impact from observed returns (Layer 2)
#
# The ledger is the "return pipe" from ExecutionLayer → DPM pre-processing.
# Without it, Module 5 (DPM) trains on returns that include the strategy's
# own footprint, making regime classification reflexively biased.
# ============================================================================

using Dates, Statistics, SQLite, Logging

export FillRecord, ExecutionLedger, LedgerConfig,
       open_ledger, close_ledger, record_fill,
       query_fills, query_fills_in_period,
       compute_volume_ratio, is_material_fill,
       estimate_alpha, residualize_impact,
       build_exogenous_returns, LowSignalRegimeWarning

# ── Constants ─────────────────────────────────────────────────────────────────

# 0.5 % of interval ADV → position is detectable in price data
const DEFAULT_MATERIALITY_THRESHOLD = 0.005

# Warn when < 30 % of return observations survive the exogenous filter
const LOW_SIGNAL_RATIO_THRESHOLD = 0.30

# ── Warning type ──────────────────────────────────────────────────────────────

"""
    LowSignalRegimeWarning

Thrown (as a logged warning, not an exception) when the exogenous return
sample drops below `LOW_SIGNAL_RATIO_THRESHOLD`. Indicates the strategy is
dominated by its own footprint; regime classification is unreliable.
Cascade should revert to conservative fallback (equal weights, reduced leverage).
"""
struct LowSignalRegimeWarning
    exogenous_ratio::Float64
    n_total::Int
    n_exogenous::Int
    message::String
end

# ── Configuration ─────────────────────────────────────────────────────────────

"""
    LedgerConfig

Configuration for the ExecutionLedger.

# Fields
- `db_path::String`: SQLite file path (persists across sessions)
- `materiality_threshold::Float64`: |Q|/ADV ratio above which a fill is "material"
- `adv_window_minutes::Int`: Lookback for rolling ADV computation (default: 15)
- `low_signal_threshold::Float64`: Exogenous ratio below which to warn (default: 0.30)
"""
struct LedgerConfig
    db_path::String
    materiality_threshold::Float64
    adv_window_minutes::Int
    low_signal_threshold::Float64
end

function LedgerConfig(;
    db_path::String = joinpath(homedir(), ".blaquebaux", "execution_ledger.sqlite"),
    materiality_threshold::Float64 = DEFAULT_MATERIALITY_THRESHOLD,
    adv_window_minutes::Int = 15,
    low_signal_threshold::Float64 = LOW_SIGNAL_RATIO_THRESHOLD
)
    mkpath(dirname(db_path))
    LedgerConfig(db_path, materiality_threshold, adv_window_minutes, low_signal_threshold)
end

# ── Fill record ───────────────────────────────────────────────────────────────

"""
    FillRecord

A single confirmed order fill. All fields required — no optional nulls —
so that impact estimation arithmetic never hits a missing-value edge case.

# Fields
- `fill_id::String`: Unique fill identifier (IBKR order ID + leg suffix)
- `symbol::String`: Underlying ticker (e.g., "NVDA", "SPY")
- `timestamp_ns::Int64`: Nanosecond-precision POSIX timestamp of the fill
- `signed_qty::Float64`: Positive = long fill, negative = short fill
- `fill_price::Float64`: Actual transaction price
- `mid_price_before::Float64`: NBBO midpoint immediately before the order was sent
- `adv_interval::Float64`: Average daily volume in the instrument during `adv_window_minutes`
- `sigma_interval::Float64`: Realized volatility of the instrument in that same interval
- `volume_ratio::Float64`: `|signed_qty| / adv_interval` — pre-computed at record time
- `is_material::Bool`: `volume_ratio >= materiality_threshold`
- `estimated_impact::Float64`: `volume_ratio * sigma_interval` (dimensionless, pre-sign)

## Decision lineage (REQ-AUDIT-001)
Every fill must trace its full causal chain. A fill with any missing lineage field is a
defect; the write-path constructor rejects empty values.
- `signal_id::String`: the signal that produced the decision
- `regime::String`: the Gamma-ARMA regime state at decision time
- `solve_id::String`: the QP/portfolio solve that sized the order
- `order_id::String`: the venue order id this fill belongs to (one order → many fills)
"""
struct FillRecord
    fill_id::String
    symbol::String
    timestamp_ns::Int64
    signed_qty::Float64
    fill_price::Float64
    mid_price_before::Float64
    adv_interval::Float64
    sigma_interval::Float64
    volume_ratio::Float64
    is_material::Bool
    estimated_impact::Float64
    signal_id::String
    regime::String
    solve_id::String
    order_id::String
end

"""
    FillRecord(fill_id, symbol, timestamp, signed_qty, fill_price,
               mid_price_before, adv_interval, sigma_interval;
               materiality_threshold) -> FillRecord

Convenience constructor — computes `volume_ratio`, `is_material`, and
`estimated_impact` from the raw inputs.
"""
function FillRecord(
    fill_id::String,
    symbol::String,
    timestamp::DateTime,
    signed_qty::Float64,
    fill_price::Float64,
    mid_price_before::Float64,
    adv_interval::Float64,
    sigma_interval::Float64;
    signal_id::String,
    regime::String,
    solve_id::String,
    order_id::String,
    materiality_threshold::Float64 = DEFAULT_MATERIALITY_THRESHOLD
)::FillRecord
    # REQ-AUDIT-001: lineage is mandatory on the write path — a fill missing any lineage
    # field is a defect and cannot be recorded.
    for (nm, v) in (("signal_id", signal_id), ("regime", regime),
                    ("solve_id", solve_id), ("order_id", order_id))
        @assert !isempty(v) "FillRecord missing lineage field '$nm' (REQ-AUDIT-001)"
    end
    adv_interval = max(adv_interval, 1.0)  # guard against zero ADV on halts
    vr = abs(signed_qty) / adv_interval
    mat = vr >= materiality_threshold
    impact = vr * sigma_interval          # units: vol × qty_fraction; scaled by α later
    ts_ns = Int64(Dates.datetime2unix(timestamp) * 1_000_000_000)
    FillRecord(fill_id, symbol, ts_ns, signed_qty, fill_price,
               mid_price_before, adv_interval, sigma_interval, vr, mat, impact,
               signal_id, regime, solve_id, order_id)
end

# ── Ledger handle ─────────────────────────────────────────────────────────────

"""
    ExecutionLedger

Handle to the persistent SQLite execution ledger.

# Fields
- `config::LedgerConfig`: Configuration
- `db::SQLite.DB`: Open database connection
"""
struct ExecutionLedger
    config::LedgerConfig
    db::SQLite.DB
end

"""
    open_ledger([config]) -> ExecutionLedger

Open (or create) the execution ledger database.
"""
function open_ledger(config::LedgerConfig = LedgerConfig())::ExecutionLedger
    db = SQLite.DB(config.db_path)
    _init_ledger_schema(db)
    @info "ExecutionLedger opened" path=config.db_path
    ExecutionLedger(config, db)
end

"""
    close_ledger(ledger::ExecutionLedger)

Close the ledger database connection.
"""
function close_ledger(ledger::ExecutionLedger)
    SQLite.close(ledger.db)
end

# ── Write ─────────────────────────────────────────────────────────────────────

"""
    record_fill(ledger, fill) -> Nothing

Persist a confirmed fill to the ledger. Called from ExecutionLayer immediately
after IBKR confirms the fill. Idempotent on `fill_id`.
"""
function record_fill(ledger::ExecutionLedger, fill::FillRecord)::Nothing
    DBInterface.execute(ledger.db, """
        INSERT OR IGNORE INTO fills (
            fill_id, symbol, timestamp_ns, signed_qty, fill_price,
            mid_price_before, adv_interval, sigma_interval,
            volume_ratio, is_material, estimated_impact,
            signal_id, regime, solve_id, order_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        fill.fill_id, fill.symbol, fill.timestamp_ns, fill.signed_qty,
        fill.fill_price, fill.mid_price_before, fill.adv_interval,
        fill.sigma_interval, fill.volume_ratio,
        fill.is_material ? 1 : 0, fill.estimated_impact,
        fill.signal_id, fill.regime, fill.solve_id, fill.order_id
    ))
    return nothing
end

# ── Read ──────────────────────────────────────────────────────────────────────

"""
    query_fills(ledger, symbol; from, to) -> Vector{FillRecord}

Retrieve all fills for `symbol` between `from` and `to` (inclusive).
Timestamps are compared at nanosecond precision.
"""
function query_fills(
    ledger::ExecutionLedger,
    symbol::String;
    from::DateTime = DateTime(1970),
    to::DateTime   = now(UTC)
)::Vector{FillRecord}
    from_ns = Int64(Dates.datetime2unix(from) * 1_000_000_000)
    to_ns   = Int64(Dates.datetime2unix(to)   * 1_000_000_000)
    rows = DBInterface.execute(ledger.db, """
        SELECT * FROM fills
        WHERE symbol = ? AND timestamp_ns >= ? AND timestamp_ns <= ?
        ORDER BY timestamp_ns ASC
    """, (symbol, from_ns, to_ns))
    return [_row_to_fill(r) for r in rows]
end

"""
    query_fills_in_period(ledger, symbol, period_start, period_end) -> Vector{FillRecord}

Convenience wrapper: fills within a single return interval.
"""
function query_fills_in_period(
    ledger::ExecutionLedger,
    symbol::String,
    period_start::DateTime,
    period_end::DateTime
)::Vector{FillRecord}
    query_fills(ledger, symbol; from=period_start, to=period_end)
end

# ── Layer 1: exogenous return partitioning ────────────────────────────────────

"""
    compute_volume_ratio(fills, adv_interval) -> Float64

Total |qty| traded in a set of fills as a fraction of one ADV interval.
Used to decide whether a return interval is endogenously contaminated.
"""
function compute_volume_ratio(fills::Vector{FillRecord}, adv_interval::Float64)::Float64
    adv_interval <= 0 && return 0.0
    sum(abs(f.signed_qty) for f in fills; init=0.0) / adv_interval
end

"""
    is_material_fill(fill; threshold) -> Bool

Re-evaluate materiality at query time (allows threshold changes without
re-writing historical records).
"""
function is_material_fill(
    fill::FillRecord;
    threshold::Float64 = DEFAULT_MATERIALITY_THRESHOLD
)::Bool
    fill.volume_ratio >= threshold
end

"""
    build_exogenous_returns(
        returns, timestamps, ledger, symbol;
        adv_interval, threshold, low_signal_threshold
    ) -> (Vector{Float64}, BitVector, Union{LowSignalRegimeWarning,Nothing})

Layer 1 — filter `returns` to keep only intervals with no material fills.

# Arguments
- `returns::Vector{Float64}`: Observed return series (length N)
- `timestamps::Vector{DateTime}`: Interval *start* timestamps (length N+1, or N for point timestamps)
- `ledger::ExecutionLedger`: Persistent fill store
- `symbol::String`: Ticker to query

# Keyword arguments
- `adv_interval::Float64`: ADV units matching `timestamps` granularity
- `threshold::Float64`: Volume ratio above which interval is contaminated (default 0.005)
- `low_signal_threshold::Float64`: Ratio of surviving observations below which to warn

# Returns
- `R_exogenous::Vector{Float64}`: Filtered returns (length ≤ N)
- `mask::BitVector`: `true` = interval survived the filter
- `warning::Union{LowSignalRegimeWarning,Nothing}`: Set when sample is severely thinned

# Notes
The final interval uses `timestamps[end]` as both start and end if only N
timestamps are provided (point-in-time labels). For bar data, pass N+1
timestamps representing interval boundaries.
"""
function build_exogenous_returns(
    returns::Vector{Float64},
    timestamps::Vector{DateTime},
    ledger::ExecutionLedger,
    symbol::String;
    adv_interval::Float64      = 1.0,
    threshold::Float64         = DEFAULT_MATERIALITY_THRESHOLD,
    low_signal_threshold::Float64 = LOW_SIGNAL_RATIO_THRESHOLD
)::Tuple{Vector{Float64}, BitVector, Union{LowSignalRegimeWarning,Nothing}}

    N = length(returns)
    mask = BitVector(undef, N)

    # Determine interval boundaries
    if length(timestamps) == N + 1
        # Bar boundaries supplied: [t0, t1, t2, ..., tN]
        starts = timestamps[1:N]
        ends   = timestamps[2:N+1]
    elseif length(timestamps) == N
        # Point-in-time labels: use each stamp as start, next as end
        starts = timestamps[1:N-1]
        ends   = timestamps[2:N]
        # Last interval: use a 1-second window around the final stamp
        push!(starts, timestamps[N])
        push!(ends,   timestamps[N] + Second(1))
    else
        error("timestamps length must be N or N+1 (got $(length(timestamps)) for N=$(N))")
    end

    for i in 1:N
        fills = query_fills_in_period(ledger, symbol, starts[i], ends[i])
        if isempty(fills)
            mask[i] = true
        else
            vr = compute_volume_ratio(fills, adv_interval)
            mask[i] = vr < threshold
        end
    end

    R_exo = returns[mask]
    n_exo = sum(mask)
    ratio = N > 0 ? n_exo / N : 1.0

    warning = nothing
    if ratio < low_signal_threshold
        msg = "Exogenous return sample dangerously thin: " *
              "$(n_exo)/$(N) observations ($(round(ratio*100, digits=1))%) survived. " *
              "Regime classification unreliable — cascade should use conservative fallback."
        @warn msg exogenous_ratio=ratio n_total=N n_exogenous=n_exo
        warning = LowSignalRegimeWarning(ratio, N, n_exo, msg)
    end

    return R_exo, mask, warning
end

# ── Layer 2: market impact residualization ────────────────────────────────────

"""
    estimate_alpha(fills, observed_returns) -> Float64

Estimate strategy-specific market impact coefficient α by OLS:

    price_impact = α * volume_ratio * sigma_interval + ε

where `price_impact = (fill_price - mid_price_before) * sign(signed_qty)`.

# Arguments
- `fills::Vector{FillRecord}`: Historical fills (recommend ≥ 60 trading days)
- `observed_returns::Vector{Float64}`: Unused here; kept for API symmetry

# Returns
- `α::Float64`: Impact coefficient (typical range: 0.1–0.5 for liquid large-caps)

# Notes
Requires `length(fills) >= 10` for meaningful OLS. Returns `NaN` if
insufficient data, which causes `residualize_impact` to return the
unmodified series (safe degradation).

Re-estimate weekly on a rolling 60-day window. A rising α signals the
strategy is becoming more detectable in market microstructure.
"""
function estimate_alpha(
    fills::Vector{FillRecord},
    observed_returns::Vector{Float64} = Float64[]
)::Float64
    if length(fills) < 10
        @warn "estimate_alpha: fewer than 10 fills — returning NaN (impact not estimated)"
        return NaN
    end

    # Dependent variable: price impact in direction of trade
    y = [(f.fill_price - f.mid_price_before) * sign(f.signed_qty) for f in fills]

    # Regressor: volume_ratio * sigma_interval
    X = [f.volume_ratio * f.sigma_interval for f in fills]

    # OLS: α = (X'X)⁻¹ X'y  (intercept suppressed — impact is zero at zero size)
    X_sq = sum(x^2 for x in X)
    if X_sq < 1e-12
        @warn "estimate_alpha: near-zero regressor variance — returning 0.0"
        return 0.0
    end
    XY = sum(X[i] * y[i] for i in eachindex(X))
    α = XY / X_sq

    @info "estimate_alpha" alpha=round(α, digits=4) n_fills=length(fills)
    return α
end

"""
    residualize_impact(
        returns, signed_positions, sigma_intervals;
        alpha, adv_interval
    ) -> Vector{Float64}

Layer 2 — subtract estimated market impact from `returns` to produce
`R_clean` suitable for DPM re-estimation.

# Arguments
- `returns::Vector{Float64}`: Observed return series
- `signed_positions::Vector{Float64}`: Average signed delta during each interval
- `sigma_intervals::Vector{Float64}`: Realized volatility during each interval

# Keyword arguments
- `alpha::Float64`: Impact coefficient from `estimate_alpha` (or 0.0 to skip)
- `adv_interval::Float64`: ADV baseline for volume ratio

# Returns
- `R_clean::Vector{Float64}`: Impact-residualized return series

# Notes
If `alpha` is `NaN` or `adv_interval <= 0`, returns `returns` unmodified
(safe degradation). The subtraction is directional:

    R_clean[t] = R_observed[t] - α * (|Q[t]| / ADV) * σ[t] * sign(Q[t])
"""
function residualize_impact(
    returns::Vector{Float64},
    signed_positions::Vector{Float64},
    sigma_intervals::Vector{Float64};
    alpha::Float64      = 0.0,
    adv_interval::Float64 = 1.0
)::Vector{Float64}

    if isnan(alpha) || alpha == 0.0 || adv_interval <= 0.0
        return copy(returns)
    end

    N = length(returns)
    @assert length(signed_positions) == N "signed_positions length mismatch"
    @assert length(sigma_intervals)  == N "sigma_intervals length mismatch"

    R_clean = similar(returns)
    for i in 1:N
        vr     = abs(signed_positions[i]) / adv_interval
        impact = alpha * vr * sigma_intervals[i] * sign(signed_positions[i])
        R_clean[i] = returns[i] - impact
    end

    @info "residualize_impact complete" alpha=alpha n=N mean_adjustment=mean(abs.(R_clean .- returns))
    return R_clean
end

# ── Internal helpers ──────────────────────────────────────────────────────────

function _init_ledger_schema(db::SQLite.DB)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS fills (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            fill_id         TEXT    NOT NULL UNIQUE,
            symbol          TEXT    NOT NULL,
            timestamp_ns    INTEGER NOT NULL,
            signed_qty      REAL    NOT NULL,
            fill_price      REAL    NOT NULL,
            mid_price_before REAL   NOT NULL,
            adv_interval    REAL    NOT NULL,
            sigma_interval  REAL    NOT NULL,
            volume_ratio    REAL    NOT NULL,
            is_material     INTEGER NOT NULL DEFAULT 0,
            estimated_impact REAL   NOT NULL,
            signal_id       TEXT    NOT NULL DEFAULT '',
            regime          TEXT    NOT NULL DEFAULT '',
            solve_id        TEXT    NOT NULL DEFAULT '',
            order_id        TEXT    NOT NULL DEFAULT '',
            created_at      TEXT    DEFAULT CURRENT_TIMESTAMP
        )
    """)
    # REQ-AUDIT-001 migration: add lineage columns to any pre-existing ledger DB.
    _ensure_columns(db, "fills", [
        ("signal_id", "TEXT NOT NULL DEFAULT ''"),
        ("regime",    "TEXT NOT NULL DEFAULT ''"),
        ("solve_id",  "TEXT NOT NULL DEFAULT ''"),
        ("order_id",  "TEXT NOT NULL DEFAULT ''"),
    ])
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_symbol_ts
        ON fills (symbol, timestamp_ns)
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_material
        ON fills (symbol, is_material)
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_order_id
        ON fills (order_id)
    """)
end

"Add any missing columns to `table` (idempotent lightweight migration)."
function _ensure_columns(db::SQLite.DB, table::String, cols::Vector{Tuple{String,String}})
    existing = Set(String(r.name) for r in DBInterface.execute(db, "PRAGMA table_info($table)"))
    for (name, decl) in cols
        if !(name in existing)
            DBInterface.execute(db, "ALTER TABLE $table ADD COLUMN $name $decl")
            @info "ledger migration: added column" table=table column=name
        end
    end
end

function _row_to_fill(r)::FillRecord
    # Raw (read-path) constructor — no re-validation, so reads never fail.
    FillRecord(
        r.fill_id, r.symbol, r.timestamp_ns,
        r.signed_qty, r.fill_price, r.mid_price_before,
        r.adv_interval, r.sigma_interval,
        r.volume_ratio, r.is_material == 1, r.estimated_impact,
        r.signal_id, r.regime, r.solve_id, r.order_id
    )
end

end  # module ExecutionLedger
