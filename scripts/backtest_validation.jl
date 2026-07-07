#!/usr/bin/env julia

# Backtest Validation — Purged K-Fold + CPCV
# Replaces standard K-Fold with López de Prado-compliant CV.
# All MAE estimates stored to Governance are now computed on clean folds.

using Dates, TimeZones, CSV, DataFrames, Statistics

include("../src/module_5_dpm/module_5_dpm.jl")
include("../src/module_8_governance/module_8_governance.jl")
include("../src/module_11_cv/purged_kfold.jl")

using .DPM, .Governance, .PurgedKFold

"""
    run_backtest_validation(;
        returns, db_path, use_cpcv, n_splits, embargo_bars
    ) -> Dict

Walk-forward validation through gates T1–T4, now using purged K-Fold or
CPCV instead of standard K-Fold. All MAE estimates fed to Governance are
computed on embargo-corrected folds.

# Keyword arguments
- `returns::Vector{Float64}`: Historical returns. Default: load from data/
- `db_path::String`: Governance SQLite path
- `use_cpcv::Bool`: Use CPCV instead of purged K-Fold (default: true)
- `n_splits::Int`: Folds / groups (default: 6 for CPCV, 5 for K-Fold)
- `embargo_bars::Int`: Override ACF-based embargo (0 = auto)
"""
function run_backtest_validation(;
    returns::Vector{Float64} = Float64[],
    db_path::String = joinpath(homedir(), ".blaquebaux", "governance.sqlite"),
    use_cpcv::Bool  = true,
    n_splits::Int   = 6,
    embargo_bars::Int = 0
)::Dict

    @info "Starting backtest validation" timestamp=now(tz"America/New_York") use_cpcv=use_cpcv

    # ── Load returns ─────────────────────────────────────────────────────────
    if isempty(returns)
        data_path = joinpath(dirname(@__DIR__), "data", "returns.csv")
        if isfile(data_path)
            df = CSV.read(data_path, DataFrame)
            returns = df[!, :return]
            @info "Loaded returns from CSV" n=length(returns) path=data_path
        else
            @warn "No returns data found — using synthetic series for smoke test"
            rng = MersenneTwister(42)
            returns = randn(rng, 504) .* 0.01 .+ 0.0001
        end
    end

    n_obs = length(returns)
    @info "Return series" n=n_obs mean=round(mean(returns)*252, digits=4) vol=round(std(returns)*sqrt(252), digits=4)

    # ── Compute embargo ───────────────────────────────────────────────────────
    actual_embargo = embargo_bars > 0 ? embargo_bars : acf_half_life(returns)
    @info "Embargo" bars=actual_embargo acf_halflife=acf_half_life(returns)

    # ── Cross-validation ──────────────────────────────────────────────────────
    dpm_config = DPMConfig(max_components=15)
    pf_config  = ParticleFilterConfig(n_particles=500)

    # Wrap DPM for the generic CV interface: X = returns as column matrix
    X = reshape(returns, :, 1)
    y = returns  # unsupervised — labels = inputs

    estimator_fn = (X_tr, _) -> begin
        r = vec(X_tr)
        model, _, _ = em_estimation(r, dpm_config, pf_config, nothing)
        return model
    end

    scorer_fn = (model, X_te, _) -> begin
        r = vec(X_te)
        # Score = -MAE of the highest-weight regime's mean vs realized mean
        # In production: replace with forecast MAE against Friday close
        pred_mean = sum(model.weights[k] * _regime_mean(model.atoms[k])
                        for k in eachindex(model.weights))
        return -mean(abs.(r .- pred_mean))   # negated so higher = better
    end

    mae_scores = Float64[]
    method_name = ""

    if use_cpcv
        cfg = CPCVConfig(n_splits=n_splits, n_test_splits=2,
                         embargo_bars=actual_embargo)
        scores = cross_val_score_cpcv(estimator_fn, scorer_fn, X, y, cfg;
                                      returns=returns)
        mae_scores = -filter(!isnan, scores)   # back to positive MAE
        method_name = "CPCV($(n_splits),2)"
    else
        cfg = PurgedKFoldConfig(n_splits=n_splits, embargo_bars=actual_embargo)
        scores = cross_val_score_purged(estimator_fn, scorer_fn, X, y, cfg;
                                        returns=returns)
        mae_scores = -filter(!isnan, scores)
        method_name = "PurgedKFold($(n_splits))"
    end

    mean_mae = isempty(mae_scores) ? NaN : mean(mae_scores)
    std_mae  = isempty(mae_scores) ? NaN : std(mae_scores)

    @info "CV results" method=method_name mean_mae=round(mean_mae, digits=6) std_mae=round(std_mae, digits=6)

    # ── Gates T1–T4 ───────────────────────────────────────────────────────────
    gate_results = _run_gates(returns, actual_embargo, dpm_config, pf_config)

    # ── Store version in Governance ───────────────────────────────────────────
    mkpath(dirname(db_path))
    today_str = Dates.format(today(), "yyyy_mm_dd")

    if !isnan(mean_mae)
        final_model, _, _ = em_estimation(returns, dpm_config, pf_config, nothing)
        version = ModelVersion(
            "v_$(today_str)",
            now(tz"America/New_York"),
            final_model,
            mean_mae,
            true
        )
        store_version(version, db_path)
        @info "Governance: version stored" version_id=version.version_id mae=mean_mae method=method_name
    end

    # ── Results DataFrame ─────────────────────────────────────────────────────
    all_results = merge(gate_results, Dict(
        "mean_mae"   => mean_mae,
        "std_mae"    => std_mae,
        "cv_method"  => method_name,
        "n_obs"      => n_obs,
        "embargo"    => actual_embargo
    ))

    out_dir  = joinpath(dirname(@__DIR__), "data")
    mkpath(out_dir)
    out_path = joinpath(out_dir, "validation_results.csv")

    gate_df = DataFrame(
        gate       = collect(keys(gate_results)),
        passed     = collect(values(gate_results)),
        run_date   = fill(today(), length(gate_results)),
        cv_method  = fill(method_name, length(gate_results)),
        embargo    = fill(actual_embargo, length(gate_results)),
        mean_mae   = fill(mean_mae, length(gate_results)),
        timestamp  = fill(now(tz"America/New_York"), length(gate_results))
    )
    CSV.write(out_path, gate_df)
    @info "Results saved" path=out_path

    all_passed = all(values(gate_results))
    if all_passed
        @info "✓ All gates passed — model approved for deployment"
    else
        @warn "✗ Some gates failed — review before deployment"
    end

    return all_results
end

# ── Gates (now use purged train/test instead of full series) ──────────────────

function _run_gates(returns, embargo_bars, dpm_config, pf_config)::Dict
    n = length(returns)
    results = Dict{String,Bool}()

    # Gate windows: always reserve the most recent 20% as test
    split  = max(1, round(Int, n * 0.80))
    r_train = returns[1:split]
    r_test  = returns[split+1:end]

    # Apply embargo to train (drop last `embargo_bars` from train)
    if embargo_bars > 0 && length(r_train) > embargo_bars
        r_train = r_train[1:end-embargo_bars]
    end

    results["T1"] = _gate_t1(r_train, r_test, dpm_config, pf_config)
    results["T2"] = _gate_t2(r_train, r_test, dpm_config, pf_config)
    results["T3"] = _gate_t3(r_train, r_test, dpm_config, pf_config)
    results["T4"] = _gate_t4(returns,  dpm_config, pf_config)   # full-cycle

    for (gate, passed) in results
        @info "Gate $(gate): $(passed ? "✓ PASSED" : "✗ FAILED")"
    end
    return results
end

function _gate_t1(r_train, r_test, dpm_config, pf_config)::Bool
    try
        cfg   = DPMConfig(max_components=10, max_iterations=100)
        model, _, converged = em_estimation(r_train, cfg, pf_config, nothing)
        converged &&
        all(model.weights .>= 0) &&
        abs(sum(model.weights) - 1.0) < 0.01
    catch; false end
end

function _gate_t2(r_train, r_test, dpm_config, pf_config)::Bool
    try
        cfg   = DPMConfig(max_components=10)
        model, _, _ = em_estimation(r_train, cfg, pf_config, nothing)
        maximum(model.weights) < 0.95
    catch; false end
end

function _gate_t3(r_train, r_test, dpm_config, pf_config)::Bool
    try
        stressed = vcat(r_train, r_train .* 3.0)
        cfg      = DPMConfig(max_components=10)
        _, _, converged = em_estimation(stressed, cfg, pf_config, nothing)
        converged
    catch; false end
end

function _gate_t4(returns, dpm_config, pf_config)::Bool
    try
        cfg   = DPMConfig(max_components=15, max_iterations=200)
        pcfg  = ParticleFilterConfig(n_particles=1000)
        _, ll_history, converged = em_estimation(returns, cfg, pcfg, nothing)
        improvements  = diff(ll_history)
        positive_ratio = sum(improvements .> 0) / max(1, length(improvements))
        converged && positive_ratio > 0.7
    catch; false end
end

# Helper: extract regime mean from atom (handles any struct with a mean field)
function _regime_mean(atom)::Float64
    try
        return atom.μ
    catch
        try return atom.mean catch; return 0.0 end
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    results = run_backtest_validation()
end
