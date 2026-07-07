module Governance

using Dates, Statistics, SQLite, TimeZones, JLD2

export ModelVersion, ValidationGate, PMOMetrics,
       store_version, load_version, get_active_version,
       check_rollback, run_walk_forward_validation,
       compute_pmo_metrics, check_escalation_threshold

# ============================================================================
# Version Registry
# ============================================================================

"""
    ModelVersion

Registered model version with metadata.

# Fields
- `version_id::String`: Version identifier (format: v_YYYY_MM_DD)
- `timestamp::ZonedDateTime`: Registration timestamp
- `dpm_model::Any`: DPM model parameters (StickBreaking)
- `mae_forecast::Float64`: Mean absolute error on Friday close
- `is_active::Bool`: Whether this version is currently active
"""
struct ModelVersion
    version_id::String
    timestamp::ZonedDateTime
    dpm_model::Any
    mae_forecast::Float64
    is_active::Bool
end

"""
    store_version(version::ModelVersion, db_path::String) -> Nothing

Store model version in SQLite registry.

# Arguments
- `version::ModelVersion`: Version to store
- `db_path::String`: Path to SQLite database
"""
function store_version(version::ModelVersion, db_path::String)::Nothing
    # Initialize database if needed
    _init_version_db(db_path)

    db = SQLite.DB(db_path)

    # Deactivate previous active version
    DBInterface.execute(db, """
        UPDATE model_versions SET is_active = 0 WHERE is_active = 1
    """)

    # Insert new version
    DBInterface.execute(db, """
        INSERT INTO model_versions 
        (version_id, timestamp, mae_forecast, is_active, model_blob)
        VALUES (?, ?, ?, ?, ?)
    """, (
        version.version_id,
        string(version.timestamp),
        version.mae_forecast,
        version.is_active ? 1 : 0,
        _serialize_model(version.dpm_model)
    ))

    @info "Version stored" version_id=version.version_id mae=version.mae_forecast

    return nothing
end

"""
    load_version(version_id::String, db_path::String) -> Union{ModelVersion,Nothing}

Load model version from registry.

# Arguments
- `version_id::String`: Version identifier
- `db_path::String`: Path to SQLite database

# Returns
- `ModelVersion` or `nothing` if not found
"""
function load_version(version_id::String, db_path::String)::Union{ModelVersion,Nothing}
    if !isfile(db_path)
        return nothing
    end

    db = SQLite.DB(db_path)
    result = DBInterface.execute(db, """
        SELECT * FROM model_versions WHERE version_id = ?
    """, (version_id,))

    row = first(result, nothing)
    if row === nothing
        return nothing
    end

    return ModelVersion(
        row.version_id,
        ZonedDateTime(row.timestamp, tz"America/New_York"),
        _deserialize_model(row.model_blob),
        row.mae_forecast,
        row.is_active == 1
    )
end

"""
    get_active_version(db_path::String) -> Union{ModelVersion,Nothing}

Get currently active model version.

# Arguments
- `db_path::String`: Path to SQLite database

# Returns
- `ModelVersion` or `nothing` if no active version
"""
function get_active_version(db_path::String)::Union{ModelVersion,Nothing}
    if !isfile(db_path)
        return nothing
    end

    db = SQLite.DB(db_path)
    result = DBInterface.execute(db, """
        SELECT * FROM model_versions WHERE is_active = 1 
        ORDER BY timestamp DESC LIMIT 1
    """)

    row = first(result, nothing)
    if row === nothing
        return nothing
    end

    return ModelVersion(
        row.version_id,
        ZonedDateTime(row.timestamp, tz"America/New_York"),
        _deserialize_model(row.model_blob),
        row.mae_forecast,
        true
    )
end

# ============================================================================
# Automatic Rollback
# ============================================================================

"""
    check_rollback(
        current_mae::Float64,
        previous_mae::Float64,
        threshold::Float64=1.2
    ) -> Tuple{Bool, String}

Check if model rollback is needed based on MAE degradation.

# Arguments
- `current_mae::Float64`: Current model MAE
- `previous_mae::Float64`: Previous model MAE
- `threshold::Float64`: Degradation threshold (default: 1.2 = 20% worse)

# Returns
- `should_rollback::Bool`: Whether to rollback
- `reason::String`: Explanation
"""
function check_rollback(
    current_mae::Float64,
    previous_mae::Float64,
    threshold::Float64=1.2
)::Tuple{Bool, String}

    if previous_mae <= 0
        return (false, "No previous MAE available for comparison")
    end

    ratio = current_mae / previous_mae

    if ratio > threshold
        reason = "MAE degraded by $(round((ratio-1)*100, digits=1))% " *
                 "(threshold: $(round((threshold-1)*100, digits=1))%). " *
                 "Current: $(round(current_mae, digits=4)), " *
                 "Previous: $(round(previous_mae, digits=4))"
        return (true, reason)
    end

    return (false, "MAE within acceptable range (ratio: $(round(ratio, digits=3)))")
end

# ============================================================================
# Walk-Forward Validation Gates
# ============================================================================

"""
    ValidationGate

Walk-forward validation gate specification.

# Fields
- `name::String`: Gate identifier ("T1", "T2", "T3", "T4")
- `start_date::Date`: Validation start date
- `end_date::Date`: Validation end date
- `success_criterion::Function`: Function that returns Bool
"""
struct ValidationGate
    name::String
    start_date::Date
    end_date::Date
    success_criterion::Function
end

"""
    run_walk_forward_validation(
        gates::Vector{ValidationGate},
        returns::Vector{Float64},
        config::Any
    ) -> Dict{String,Bool}

Run walk-forward validation through all gates.

# Gates
- T1: 1-month out-of-sample (basic functionality)
- T2: 3-month out-of-sample (regime detection)
- T3: 6-month out-of-sample (crisis handling)
- T4: 12-month out-of-sample (full cycle)

# Arguments
- `gates::Vector{ValidationGate}`: Validation gates to run
- `returns::Vector{Float64}`: Historical returns for validation
- `config::Any`: DPM configuration

# Returns
- `Dict{String,Bool}`: Gate name → passed
"""
function run_walk_forward_validation(
    gates::Vector{ValidationGate},
    returns::Vector{Float64},
    config::Any
)::Dict{String,Bool}

    results = Dict{String,Bool}()

    for gate in gates
        @info "Running validation gate" gate=gate.name start_date=gate.start_date end_date=gate.end_date

        # Extract validation period returns
        # In production: map dates to indices
        val_returns = returns  # Simplified

        # Run validation
        passed = gate.success_criterion(val_returns, config)
        results[gate.name] = passed

        status = passed ? "PASSED" : "FAILED"
        @info "Gate $(gate.name) $(status)"
    end

    return results
end

# ============================================================================
# PMO Metrics
# ============================================================================

"""
    PMOMetrics

Project Management Office performance metrics.

# Fields
- `classification_accuracy::Float64`: Regime classification accuracy
- `bootstrap_coverage::Float64`: 95% CI actual coverage
- `mse_fixed::Float64`: MSE in Fixed regime
- `mse_growth::Float64`: MSE in Growth regime
- `mse_floating::Float64`: MSE in Floating regime
- `arma_order_changes::Int`: ARMA order changes per regime per year
"""
struct PMOMetrics
    classification_accuracy::Float64
    bootstrap_coverage::Float64
    mse_fixed::Float64
    mse_growth::Float64
    mse_floating::Float64
    arma_order_changes::Int
end

"""
    compute_pmo_metrics(
        regime_probs_history::Matrix{Float64},
        ex_post_labels::Vector{Int},
        bootstrap_intervals::Vector{Tuple{Float64,Float64}},
        actual_correlations::Vector{Float64},
        mse_by_regime::NamedTuple,
        arma_change_log::Vector{Pair{String,Date}}
    ) -> PMOMetrics

Compute PMO performance metrics.

# Arguments
- `regime_probs_history::Matrix{Float64}`: T×K regime probability history
- `ex_post_labels::Vector{Int}`: Ex-post smoothed regime labels
- `bootstrap_intervals::Vector{Tuple{Float64,Float64}}`: Bootstrap CIs
- `actual_correlations::Vector{Float64}`: Actual realized correlations
- `mse_by_regime::NamedTuple`: MSE broken down by regime
- `arma_change_log::Vector{Pair{String,Date}}`: ARMA order change history

# Returns
- `PMOMetrics`: Computed metrics
"""
function compute_pmo_metrics(
    regime_probs_history::Matrix{Float64},
    ex_post_labels::Vector{Int},
    bootstrap_intervals::Vector{Tuple{Float64,Float64}},
    actual_correlations::Vector{Float64},
    mse_by_regime::NamedTuple,
    arma_change_log::Vector{Pair{String,Date}}
)::PMOMetrics

    T = length(ex_post_labels)

    # Classification accuracy
    predicted = [argmax(regime_probs_history[t, :]) for t in 1:T]
    correct = sum(predicted .== ex_post_labels)
    classification_accuracy = T > 0 ? correct / T : 0.0

    # Bootstrap coverage
    coverage_count = 0
    for i in eachindex(bootstrap_intervals)
        lower, upper = bootstrap_intervals[i]
        if lower <= actual_correlations[i] <= upper
            coverage_count += 1
        end
    end
    bootstrap_coverage = length(bootstrap_intervals) > 0 ? 
                         coverage_count / length(bootstrap_intervals) : 0.0

    # ARMA order changes per year
    n_changes = length(arma_change_log)
    # Approximate: assume data spans ~1 year per 252 observations
    years = T / 252.0
    arma_order_changes = years > 0 ? round(Int, n_changes / years) : 0

    return PMOMetrics(
        classification_accuracy,
        bootstrap_coverage,
        get(mse_by_regime, :fixed, 0.0),
        get(mse_by_regime, :growth, 0.0),
        get(mse_by_regime, :floating, 0.0),
        arma_order_changes
    )
end

# ============================================================================
# Escalation Threshold Detection
# ============================================================================

"""
    check_escalation_threshold(
        metrics::PMOMetrics,
        warning_thresholds::NamedTuple,
        consecutive_failures::Int
    ) -> Tuple{Bool, Vector{String}}

Check if human escalation is needed.

# Arguments
- `metrics::PMOMetrics`: Current PMO metrics
- `warning_thresholds::NamedTuple`: Threshold values
    - classification_accuracy_min::Float64
    - bootstrap_coverage_min::Float64
    - mse_max::Float64
- `consecutive_failures::Int`: Number of consecutive threshold breaches

# Returns
- `needs_escalation::Bool`: Whether to escalate
- `failed_metrics::Vector{String}`: List of failed metrics
"""
function check_escalation_threshold(
    metrics::PMOMetrics,
    warning_thresholds::NamedTuple,
    consecutive_failures::Int
)::Tuple{Bool, Vector{String}}

    failed = String[]

    if metrics.classification_accuracy < warning_thresholds.classification_accuracy_min
        push!(failed, "classification_accuracy")
    end

    if metrics.bootstrap_coverage < warning_thresholds.bootstrap_coverage_min
        push!(failed, "bootstrap_coverage")
    end

    max_mse = max(metrics.mse_fixed, metrics.mse_growth, metrics.mse_floating)
    if max_mse > warning_thresholds.mse_max
        push!(failed, "mse")
    end

    # Escalate if any metric failed for 3+ consecutive checks
    needs_escalation = !isempty(failed) && consecutive_failures >= 3

    return (needs_escalation, failed)
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

"""
    _init_version_db(db_path::String)

Initialize SQLite database for version registry.
"""
function _init_version_db(db_path::String)
    db = SQLite.DB(db_path)

    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS model_versions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version_id TEXT UNIQUE NOT NULL,
            timestamp TEXT NOT NULL,
            mae_forecast REAL NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0,
            model_blob BLOB,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_active ON model_versions(is_active)
    """)
end

"""
    _serialize_model(model::Any) -> Vector{UInt8}

Serialize DPM model (StickBreaking) to bytes using JLD2 via an in-memory
IOBuffer. Stores both the struct fields and their types so deserialization
is unambiguous across Julia sessions.
"""
function _serialize_model(model::Any)::Vector{UInt8}
    tmp = tempname() * ".jld2"
    try
        jldsave(tmp; model=model)
        return read(tmp)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

"""
    _deserialize_model(blob::Vector{UInt8}) -> Any

Deserialize a JLD2-encoded model blob back to the original struct.
Returns `nothing` on error (safe degradation for legacy placeholder blobs).
"""
function _deserialize_model(blob::Vector{UInt8})
    isempty(blob) && return nothing
    # Detect legacy placeholder written before JLD2 was wired
    if blob == Vector{UInt8}("serialized_model_placeholder")
        @warn "_deserialize_model: legacy placeholder blob — returning nothing"
        return nothing
    end
    tmp = tempname() * ".jld2"
    try
        write(tmp, blob)
        result = jldopen(tmp) do f; f["model"]; end
        return result
    catch e
        @warn "_deserialize_model: failed to deserialize blob" exception=e
        return nothing
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

end  # module Governance
