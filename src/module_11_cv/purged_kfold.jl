module PurgedKFold

# ============================================================================
# PURGED K-FOLD + EMBARGO CROSS-VALIDATION
# Gap 2 — López de Prado (AFML Ch. 7) implementation
#
# Standard K-Fold leaks information between train and test folds because:
#   (a) label construction windows overlap fold boundaries
#   (b) autocorrelation in returns means adjacent observations are not i.i.d.
#
# Fix has two parts:
#   PURGE  — remove training observations whose label window overlaps the test
#             fold, eliminating direct look-ahead contamination
#   EMBARGO — after purging, also drop the N observations immediately following
#             the test fold, sized to the autocorrelation half-life of the
#             residuals, eliminating indirect leakage through serial correlation
#
# CPCV (Combinatorial Purged Cross-Validation):
#   Instead of K sequential folds, enumerate all C(K,2) train/test splits.
#   Produces a full backtest path rather than K disjoint test windows.
#   Preferred over standard purged K-Fold for regime-switching models.
# ============================================================================

using Statistics, Dates, Logging, Random, LinearAlgebra

export PurgedKFoldConfig, CPCVConfig, CVFold,
       acf_half_life, compute_embargo_size,
       purged_kfold_split, cpcv_split,
       cross_val_score_purged, cross_val_score_cpcv

# ── Configuration ─────────────────────────────────────────────────────────────

"""
    PurgedKFoldConfig

Configuration for purged K-Fold cross-validation.

# Fields
- `n_splits::Int`: Number of folds K (default: 5)
- `embargo_pct::Float64`: Embargo as fraction of total sample (default: 0.01)
    Set to 0.0 to use `embargo_bars` directly, or leave > 0 to auto-compute
    from sample size. Overridden by explicit `embargo_bars` if > 0.
- `embargo_bars::Int`: Fixed embargo length in bars (0 = use `embargo_pct`)
- `purge_overlap::Bool`: Whether to purge overlapping label windows (default: true)
"""
struct PurgedKFoldConfig
    n_splits::Int
    embargo_pct::Float64
    embargo_bars::Int
    purge_overlap::Bool
end

function PurgedKFoldConfig(;
    n_splits::Int       = 5,
    embargo_pct::Float64 = 0.01,
    embargo_bars::Int   = 0,
    purge_overlap::Bool = true
)
    PurgedKFoldConfig(n_splits, embargo_pct, embargo_bars, purge_overlap)
end

"""
    CPCVConfig

Configuration for Combinatorial Purged Cross-Validation.

# Fields
- `n_splits::Int`: Total number of groups G to split the data into (default: 6)
- `n_test_splits::Int`: Number of groups held out as test in each combination (default: 2)
- `embargo_bars::Int`: Embargo length in bars (0 = compute from ACF half-life)
- `max_combinations::Int`: Cap on combinations evaluated (default: 0 = all)
"""
struct CPCVConfig
    n_splits::Int
    n_test_splits::Int
    embargo_bars::Int
    max_combinations::Int
end

function CPCVConfig(;
    n_splits::Int       = 6,
    n_test_splits::Int  = 2,
    embargo_bars::Int   = 0,
    max_combinations::Int = 0
)
    @assert n_test_splits < n_splits "n_test_splits must be < n_splits"
    CPCVConfig(n_splits, n_test_splits, embargo_bars, max_combinations)
end

"""
    CVFold

A single train/test split with embargo metadata.

# Fields
- `train_idx::Vector{Int}`: Training observation indices (purged + embargoed)
- `test_idx::Vector{Int}`: Test observation indices
- `purged_count::Int`: Number of observations removed by purging
- `embargo_count::Int`: Number of observations removed by embargo
- `fold_id::String`: Human-readable fold identifier
"""
struct CVFold
    train_idx::Vector{Int}
    test_idx::Vector{Int}
    purged_count::Int
    embargo_count::Int
    fold_id::String
end

# ── Autocorrelation and embargo sizing ────────────────────────────────────────

"""
    acf_half_life(x::Vector{Float64}; max_lag::Int=50) -> Int

Estimate the autocorrelation half-life of series `x`.

Computes ACF at lags 1..max_lag and finds the first lag where the ACF
decays below 0.5 * ACF(1). This is the lag at which serial correlation
has halved — the natural embargo period for return-based labels.

Returns 1 if the series shows no meaningful autocorrelation (ACF(1) < 0.05).

# López de Prado AFML reference:
Chapter 7, equation 7.2 — embargo set to the number of lags required for
the ACF to decay below half its initial value.
"""
function acf_half_life(x::Vector{Float64}; max_lag::Int=50)::Int
    n = length(x)
    max_lag = min(max_lag, n ÷ 4)  # can't compute ACF beyond n/4 reliably

    x̄ = mean(x)
    σ² = var(x)
    σ² < 1e-12 && return 1  # constant series

    # ACF at lag 1
    acf1 = sum((x[i] - x̄) * (x[i-1] - x̄) for i in 2:n) / ((n-1) * σ²)
    abs(acf1) < 0.05 && return 1  # negligible autocorrelation

    half_target = abs(acf1) * 0.5

    for lag in 2:max_lag
        acf_lag = sum((x[i] - x̄) * (x[i-lag] - x̄) for i in lag+1:n) / ((n-lag) * σ²)
        if abs(acf_lag) <= half_target
            return lag
        end
    end

    return max_lag  # still above half-life at max_lag
end

"""
    compute_embargo_size(returns::Vector{Float64}, config::PurgedKFoldConfig) -> Int

Determine embargo length in bars from config, falling back to ACF half-life
if `embargo_bars` is 0 and `embargo_pct` is 0.
"""
function compute_embargo_size(
    returns::Vector{Float64},
    config::PurgedKFoldConfig
)::Int
    config.embargo_bars > 0 && return config.embargo_bars
    config.embargo_pct  > 0 && return max(1, round(Int, length(returns) * config.embargo_pct))
    return acf_half_life(returns)
end

# ── Purged K-Fold ─────────────────────────────────────────────────────────────

"""
    purged_kfold_split(
        n_obs, config;
        returns, label_endtimes
    ) -> Vector{CVFold}

Generate purged K-Fold splits.

# Arguments
- `n_obs::Int`: Total number of observations
- `config::PurgedKFoldConfig`: CV configuration

# Keyword arguments
- `returns::Vector{Float64}`: Used to compute ACF half-life embargo if needed
- `label_endtimes::Vector{Int}`: Bar index at which each label's look-forward
    window closes. Length must equal `n_obs`. If empty, assumes no overlap
    (point-in-time labels). This is the key input for purging.

# Returns
- `Vector{CVFold}`: K folds with purged training sets

# Purging logic
For each test fold [t_start, t_end], any training observation i is purged if:
    label_endtimes[i] >= t_start
That is: observation i's label extends into or past the test period.

# Embargo logic
Additionally purge the `embargo_bars` observations immediately after t_end.
"""
function purged_kfold_split(
    n_obs::Int,
    config::PurgedKFoldConfig;
    returns::Vector{Float64}    = Float64[],
    label_endtimes::Vector{Int} = Int[]
)::Vector{CVFold}

    fold_size = n_obs ÷ config.n_splits
    embargo   = isempty(returns) ? config.embargo_bars :
                compute_embargo_size(returns, config)

    use_label_overlap = config.purge_overlap && !isempty(label_endtimes)
    @assert !use_label_overlap || length(label_endtimes) == n_obs

    folds = CVFold[]

    for k in 1:config.n_splits
        # Test fold boundaries
        t_start = (k - 1) * fold_size + 1
        t_end   = k == config.n_splits ? n_obs : k * fold_size
        test_idx = collect(t_start:t_end)

        # Candidate training indices = everything outside test
        train_candidates = vcat(1:t_start-1, t_end+1:n_obs)

        purged_count  = 0
        embargo_count = 0

        if use_label_overlap
            # Purge: remove training obs whose label window touches the test fold
            before_purge = length(train_candidates)
            train_candidates = filter(train_candidates) do i
                label_endtimes[i] < t_start
            end
            purged_count = before_purge - length(train_candidates)
        end

        if embargo > 0 && t_end < n_obs
            # Embargo: drop the `embargo` bars immediately after the test fold
            embargo_zone = (t_end + 1):min(t_end + embargo, n_obs)
            before_embargo = length(train_candidates)
            train_candidates = filter(i -> i ∉ embargo_zone, train_candidates)
            embargo_count = before_embargo - length(train_candidates)
        end

        push!(folds, CVFold(
            train_candidates, test_idx,
            purged_count, embargo_count,
            "K$(config.n_splits)_fold$(k)"
        ))

        @info "Purged K-Fold" fold=k test_range="$(t_start):$(t_end)" n_train=length(train_candidates) purged=purged_count embargoed=embargo_count
    end

    return folds
end

# ── CPCV ──────────────────────────────────────────────────────────────────────

"""
    cpcv_split(n_obs, config; returns) -> Vector{CVFold}

Generate Combinatorial Purged Cross-Validation splits.

Partitions `n_obs` into `config.n_splits` groups of equal size, then
enumerates all C(n_splits, n_test_splits) combinations of test groups.
Each combination yields one fold with:
  - Test: the chosen n_test_splits groups
  - Train: remaining groups, purged and embargoed at each test boundary

CPCV produces a full backtest path (multiple non-contiguous test windows per
combination) rather than K disjoint test windows, making it preferable for
regime-switching models where contiguous OOS windows may miss regime cycles.

# Returns
- `Vector{CVFold}`: One CVFold per combination (n_splits choose n_test_splits)
"""
function cpcv_split(
    n_obs::Int,
    config::CPCVConfig;
    returns::Vector{Float64} = Float64[]
)::Vector{CVFold}

    G   = config.n_splits
    k   = config.n_test_splits
    grp = n_obs ÷ G

    embargo = config.embargo_bars > 0 ? config.embargo_bars :
              (!isempty(returns) ? acf_half_life(returns) : 1)

    # Group index ranges: explicit UnitRange per group
    group_ranges = UnitRange{Int}[]
    for g in 1:G
        g_start = (g - 1) * grp + 1
        g_end   = g == G ? n_obs : g * grp
        push!(group_ranges, g_start:g_end)
    end

    # All C(G, k) combinations of test groups
    combos = _combinations(1:G, k)
    if config.max_combinations > 0 && length(combos) > config.max_combinations
        combos = combos[1:config.max_combinations]
        @warn "CPCV: capped at $(config.max_combinations) combinations ($(length(combos)) total)"
    end

    folds = CVFold[]

    for (combo_idx, test_groups) in enumerate(combos)
        train_groups = setdiff(1:G, test_groups)

        test_idx_raw     = vcat([collect(group_ranges[g]) for g in test_groups]...)
        sort!(test_idx_raw)
        train_candidates = vcat([collect(group_ranges[g]) for g in train_groups]...)
        sort!(train_candidates)

        # Embargo: after each test group's last bar, drop the next `embargo` bars
        embargo_set = Set{Int}()
        for tg in test_groups
            t_end = last(group_ranges[tg])
            for b in (t_end+1):min(t_end + embargo, n_obs)
                push!(embargo_set, b)
            end
        end

        before = length(train_candidates)
        train_candidates = filter(i -> i ∉ embargo_set, train_candidates)
        embargo_count = before - length(train_candidates)

        push!(folds, CVFold(
            train_candidates, test_idx_raw,
            0, embargo_count,
            "CPCV_$(combo_idx)_of_$(length(combos))"
        ))
    end

    @info "CPCV generated" n_combinations=length(folds) n_splits=G n_test_splits=k embargo_bars=embargo

    return folds
end

# ── Cross-validation scorers ──────────────────────────────────────────────────

"""
    cross_val_score_purged(
        estimator_fn, scorer_fn, X, y, config;
        returns, label_endtimes
    ) -> Vector{Float64}

Run purged K-Fold CV and return one score per fold.

# Arguments
- `estimator_fn(X_train, y_train) -> model`: Fits a model and returns it
- `scorer_fn(model, X_test, y_test) -> Float64`: Scores the fitted model
- `X::Matrix{Float64}`: Feature matrix (n_obs × n_features)
- `y::Vector{Float64}`: Labels / targets
- `config::PurgedKFoldConfig`: CV configuration

# Returns
- `Vector{Float64}`: Score per fold (length = config.n_splits)
- Reports mean ± std across folds via @info

# Notes
For the DPM/ARMA use case:
  `estimator_fn` = `(returns, _) -> em_estimation(returns, dpm_config, pf_config, nothing)`
  `scorer_fn`    = `(model, returns_test, _) -> -mae_forecast(model, returns_test)`
  `X`            = returns reshaped as a column matrix
  `y`            = returns (same, since DPM is unsupervised)
"""
function cross_val_score_purged(
    estimator_fn,
    scorer_fn,
    X::Matrix{Float64},
    y::Vector{Float64},
    config::PurgedKFoldConfig;
    returns::Vector{Float64}    = vec(X[:, 1]),
    label_endtimes::Vector{Int} = Int[]
)::Vector{Float64}

    folds  = purged_kfold_split(size(X, 1), config;
                                returns=returns, label_endtimes=label_endtimes)
    scores = Float64[]

    for fold in folds
        isempty(fold.train_idx) && continue

        X_train = X[fold.train_idx, :]
        y_train = y[fold.train_idx]
        X_test  = X[fold.test_idx, :]
        y_test  = y[fold.test_idx]

        try
            model = estimator_fn(X_train, y_train)
            s     = scorer_fn(model, X_test, y_test)
            push!(scores, s)
            @info "Fold score" fold=fold.fold_id score=round(s, digits=6)
        catch e
            @warn "Fold failed" fold=fold.fold_id exception=e
            push!(scores, NaN)
        end
    end

    valid = filter(!isnan, scores)
    if !isempty(valid)
        @info "Purged K-Fold CV complete" n_folds=length(scores) mean_score=round(mean(valid), digits=6) std_score=round(std(valid), digits=6)
    end

    return scores
end

"""
    cross_val_score_cpcv(
        estimator_fn, scorer_fn, X, y, config;
        returns
    ) -> Vector{Float64}

Run CPCV and return one score per combination.
"""
function cross_val_score_cpcv(
    estimator_fn,
    scorer_fn,
    X::Matrix{Float64},
    y::Vector{Float64},
    config::CPCVConfig;
    returns::Vector{Float64} = vec(X[:, 1])
)::Vector{Float64}

    folds  = cpcv_split(size(X, 1), config; returns=returns)
    scores = Float64[]

    for fold in folds
        isempty(fold.train_idx) && continue

        X_train = X[fold.train_idx, :]
        y_train = y[fold.train_idx]
        X_test  = X[fold.test_idx, :]
        y_test  = y[fold.test_idx]

        try
            model = estimator_fn(X_train, y_train)
            s     = scorer_fn(model, X_test, y_test)
            push!(scores, s)
        catch e
            @warn "CPCV combination failed" combo=fold.fold_id exception=e
            push!(scores, NaN)
        end
    end

    valid = filter(!isnan, scores)
    if !isempty(valid)
        @info "CPCV complete" n_combinations=length(scores) mean_score=round(mean(valid), digits=6) std_score=round(std(valid), digits=6) sharpe=round(mean(valid)/max(std(valid),1e-9), digits=4)
    end

    return scores
end

# ── Internal utilities ────────────────────────────────────────────────────────

"""
    _combinations(items, k) -> Vector{Vector{T}}

All k-element combinations of `items` without repetition.
"""
function _combinations(items, k::Int)
    items = collect(items)
    n = length(items)
    result = Vector{Vector{eltype(items)}}()
    _comb_helper!(result, items, k, 1, eltype(items)[])
    return result
end

function _comb_helper!(result, items, k, start, current)
    length(current) == k && (push!(result, copy(current)); return)
    for i in start:length(items)
        push!(current, items[i])
        _comb_helper!(result, items, k, i+1, current)
        pop!(current)
    end
end

end  # module PurgedKFold
