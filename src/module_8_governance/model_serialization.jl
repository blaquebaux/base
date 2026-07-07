# ============================================================================
# MODEL SERIALIZATION — JLD2 Production Implementation
# Source: Deepseek v2, integrated with corrections (May 2026)
# Fixes applied:
#   - SQLite.execute! → DBInterface.execute (SQLite.jl >= 1.0 API)
#   - SQLite.query   → DBInterface.execute + collect
#   - StickBreaking serialized field-by-field (no new struct fields required)
# ============================================================================

using JLD2, FileIO, SQLite

const MODEL_REGISTRY_DIR = get(ENV, "BLAQUEBAUX_MODEL_DIR", "models/registry")
const MODEL_BACKUP_DIR   = get(ENV, "BLAQUEBAUX_BACKUP_DIR", "models/backups")

# ── JLD2 serialization ────────────────────────────────────────────────────────
"""
    serialize_model_jld2(model::StickBreaking, version_id::String) -> String

Save DPM model to JLD2 file. Returns filepath.
"""
function serialize_model_jld2(model::StickBreaking, version_id::String)::String
    isdir(MODEL_REGISTRY_DIR) || mkpath(MODEL_REGISTRY_DIR)
    filepath = joinpath(MODEL_REGISTRY_DIR, "$(version_id).jld2")

    jldsave(filepath;
        version_id = version_id,
        saved_at   = string(now(UTC)),
        weights    = model.weights,
        atoms      = model.atoms,         # Vector{Any} — JLD2 handles this
    )
    @info "Model serialized" version_id=version_id path=filepath
    return filepath
end

"""
    deserialize_model_jld2(filepath::String) -> StickBreaking

Load DPM model from JLD2 file.
"""
function deserialize_model_jld2(filepath::String)::StickBreaking
    isfile(filepath) || error("Model file not found: $filepath")
    data = load(filepath)
    return StickBreaking(data["weights"], data["atoms"])
end

# ── SQLite registry (production-correct API) ──────────────────────────────────
function _init_version_registry(db_path::String)
    db = SQLite.DB(db_path)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS model_versions (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            version_id   TEXT    UNIQUE NOT NULL,
            timestamp    TEXT    NOT NULL,
            mae_forecast REAL    NOT NULL,
            is_active    INTEGER NOT NULL DEFAULT 0,
            model_path   TEXT,
            created_at   TEXT    DEFAULT CURRENT_TIMESTAMP
        )
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_active ON model_versions(is_active)
    """)
    return db
end

"""
    store_version_jld2(version::ModelVersion, db_path::String)

Store version metadata in SQLite + model weights in JLD2 file.
"""
function store_version_jld2(version::ModelVersion, db_path::String)::Nothing
    model_path = serialize_model_jld2(version.dpm_model, version.version_id)

    db = _init_version_registry(db_path)

    # Deactivate all prior active versions
    DBInterface.execute(db, "UPDATE model_versions SET is_active = 0 WHERE is_active = 1")

    DBInterface.execute(db, """
        INSERT OR REPLACE INTO model_versions
            (version_id, timestamp, mae_forecast, is_active, model_path)
        VALUES (?, ?, ?, ?, ?)
    """, (
        version.version_id,
        string(version.timestamp),
        version.mae_forecast,
        version.is_active ? 1 : 0,
        model_path
    ))

    @info "Version stored" version_id=version.version_id mae=version.mae_forecast
    return nothing
end

"""
    load_version_jld2(version_id::String, db_path::String) -> Union{ModelVersion,Nothing}
"""
function load_version_jld2(version_id::String, db_path::String)::Union{ModelVersion,Nothing}
    isfile(db_path) || return nothing
    db = SQLite.DB(db_path)

    result = collect(DBInterface.execute(db,
        "SELECT * FROM model_versions WHERE version_id = ?", (version_id,)))

    isempty(result) && return nothing
    row = first(result)

    model_path = row.model_path
    isnothing(model_path) && return nothing
    dpm_model = deserialize_model_jld2(model_path)

    return ModelVersion(
        row.version_id,
        ZonedDateTime(row.timestamp, tz"UTC"),
        dpm_model,
        row.mae_forecast,
        row.is_active == 1
    )
end

"""
    get_active_version_jld2(db_path::String) -> Union{ModelVersion,Nothing}
"""
function get_active_version_jld2(db_path::String)::Union{ModelVersion,Nothing}
    isfile(db_path) || return nothing
    db = SQLite.DB(db_path)
    result = collect(DBInterface.execute(db,
        "SELECT version_id FROM model_versions WHERE is_active = 1 ORDER BY timestamp DESC LIMIT 1"))
    isempty(result) && return nothing
    return load_version_jld2(first(result).version_id, db_path)
end

"""
    export_model_for_backtest(model::StickBreaking, filepath::String)

Export model for backtesting without SQLite dependency.
"""
function export_model_for_backtest(model::StickBreaking, filepath::String)
    jldsave(filepath;
        weights          = model.weights,
        atoms            = model.atoms,
        export_timestamp = string(now(UTC))
    )
    @info "Model exported for backtest" path=filepath
end
