module PCACompression

using MultivariateStats, LinearAlgebra, Statistics, Dates, TimeZones

export VolSurfacePCA, YieldCurve, StateVector,
       fit_vol_pca, transform_vol_pca,
       litterman_scheinkman_factors,
       assemble_state_vector

# ============================================================================
# Volatility Surface PCA
# ============================================================================

"""
    VolSurfacePCA

Container for volatility surface inputs for PCA decomposition.

# Fields
- `vix::Vector{Float64}`: VIX spot values
- `vxv::Vector{Float64}`: VXV (90-day) values
- `vvix::Vector{Float64}`: VVIX (vol of vol) values
- `vix1d::Vector{Float64}`: VIX1D (1-day) values
- `iv_rank::Vector{Float64}`: IV Rank for SPY
"""
struct VolSurfacePCA
    vix::Vector{Float64}
    vxv::Vector{Float64}
    vvix::Vector{Float64}
    vix1d::Vector{Float64}
    iv_rank::Vector{Float64}
end

"""
    fit_vol_pca(data::VolSurfacePCA, n_components::Int=3) -> PCA

Fit PCA on volatility surface data to extract principal components.

# Arguments
- `data::VolSurfacePCA`: Volatility surface inputs
- `n_components::Int`: Number of components to retain (default: 3)

# Returns
- `PCA` object from MultivariateStats.jl

# PC Interpretation
- PC₁: Absolute fear level (level shift)
- PC₂: Term structure slope (short vs long dated vol)
- PC₃: Event vs structural (VIX1D contribution, excluded if unavailable)
"""
function fit_vol_pca(data::VolSurfacePCA, n_components::Int=3)
    # Assemble data matrix: each row = observation, each column = variable
    X = hcat(data.vix, data.vxv, data.vvix, data.vix1d, data.iv_rank)

    # Remove rows with NaN
    valid_rows = .!any(isnan.(X), dims=2)[:]
    X_clean = X[valid_rows, :]'

    @assert size(X_clean, 2) >= n_components "Not enough valid observations for PCA"

    # Standardize (z-score) each variable
    X_std = _standardize(X_clean)

    # Fit PCA
    pca_model = fit(PCA, X_std; maxoutdim=n_components)

    return pca_model
end

"""
    transform_vol_pca(pca::PCA, data::VolSurfacePCA) -> Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}

Transform volatility surface data using fitted PCA model.

# Returns
- `pc1::Vector{Float64}`: First principal component (absolute fear)
- `pc2::Vector{Float64}`: Second principal component (term structure)
- `pc3::Vector{Float64}`: Third principal component (event vs structural)
"""
function transform_vol_pca(pca, data::VolSurfacePCA)::Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}
    X = hcat(data.vix, data.vxv, data.vvix, data.vix1d, data.iv_rank)

    n = size(X, 1)
    pc1 = fill(NaN, n)
    pc2 = fill(NaN, n)
    pc3 = fill(NaN, n)

    # Transform each valid row
    for i in 1:n
        if !any(isnan.(X[i, :]))
            x_std = _standardize_row(X[i, :], pca)
            transformed = transform(pca, x_std)

            pc1[i] = transformed[1]
            if length(transformed) >= 2
                pc2[i] = transformed[2]
            end
            if length(transformed) >= 3
                pc3[i] = transformed[3]
            end
        end
    end

    return (pc1, pc2, pc3)
end

# ============================================================================
# Yield Curve Litterman-Scheinkman Factors
# ============================================================================

"""
    YieldCurve

Container for yield curve data.

# Fields
- `maturities::Vector{Float64}`: Maturities in years
- `yields::Matrix{Float64}`: Yield matrix (rows = days, columns = maturities)
"""
struct YieldCurve
    maturities::Vector{Float64}
    yields::Matrix{Float64}
end

"""
    litterman_scheinkman_factors(yield_curve::YieldCurve) -> Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}

Extract Litterman-Scheinkman three-factor decomposition from yield curve.

Factors:
- Level: Parallel shift (average yield across maturities)
- Slope: Steepness (long - short maturity yields)
- Curvature: Butterfly (2×mid - short - long)

# Arguments
- `yield_curve::YieldCurve`: Yield curve data with standard maturities

# Returns
- `level::Vector{Float64}`: Level factor time series
- `slope::Vector{Float64}`: Slope factor time series
- `curvature::Vector{Float64}`: Curvature factor time series
"""
function litterman_scheinkman_factors(
    yield_curve::YieldCurve
)::Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}

    maturities = yield_curve.maturities
    yields = yield_curve.yields
    n_obs = size(yields, 1)

    # Standard maturities for L-S factors
    # Use closest available: 3M, 2Y, 10Y for level, slope, curvature
    short_idx = _find_closest_maturity(maturities, 0.25)   # 3-month
    mid_idx = _find_closest_maturity(maturities, 2.0)      # 2-year
    long_idx = _find_closest_maturity(maturities, 10.0)    # 10-year

    level = Vector{Float64}(undef, n_obs)
    slope = Vector{Float64}(undef, n_obs)
    curvature = Vector{Float64}(undef, n_obs)

    for t in 1:n_obs
        y_short = yields[t, short_idx]
        y_mid = yields[t, mid_idx]
        y_long = yields[t, long_idx]

        # Level: average of key rates
        level[t] = (y_short + y_mid + y_long) / 3.0

        # Slope: long - short
        slope[t] = y_long - y_short

        # Curvature: 2*mid - short - long (butterfly)
        curvature[t] = 2.0 * y_mid - y_short - y_long
    end

    return (level, slope, curvature)
end

# ============================================================================
# 6-Dimensional State Vector Assembly
# ============================================================================

"""
    StateVector

Complete 6-dimensional state vector for Gamma-ARMA framework.

# Fields
- `timestamp::ZonedDateTime`: Observation timestamp
- `vol_pc1::Float64`: Volatility PC₁ (absolute fear level)
- `vol_pc2::Float64`: Volatility PC₂ (term structure)
- `vol_pc3::Float64`: Volatility PC₃ (event vs structural)
- `yield_level::Float64`: Yield curve level factor
- `yield_slope::Float64`: Yield curve slope factor
- `yield_curvature::Float64`: Yield curve curvature factor
"""
struct StateVector
    timestamp::ZonedDateTime
    vol_pc1::Float64
    vol_pc2::Float64
    vol_pc3::Float64
    yield_level::Float64
    yield_slope::Float64
    yield_curvature::Float64
end

"""
    assemble_state_vector(
        vol_pcs::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
        yield_factors::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
        vix1d_available::Bool,
        timestamps::Vector{ZonedDateTime}
    ) -> Vector{StateVector}

Assemble volatility PCs and yield factors into complete state vectors.

# Arguments
- `vol_pcs`: Tuple of (pc1, pc2, pc3) vectors
- `yield_factors`: Tuple of (level, slope, curvature) vectors
- `vix1d_available::Bool`: Whether VIX1D data is available (affects PC₃)
- `timestamps::Vector{ZonedDateTime}`: Observation timestamps

# Returns
- Vector of StateVector structs
"""
function assemble_state_vector(
    vol_pcs::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
    yield_factors::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
    vix1d_available::Bool,
    timestamps::Vector{ZonedDateTime}
)::Vector{StateVector}

    pc1, pc2, pc3 = vol_pcs
    level, slope, curvature = yield_factors

    n = length(timestamps)
    @assert all(length.(vol_pcs) .== n) "Vol PC vectors must match timestamp length"
    @assert all(length.(yield_factors) .== n) "Yield factor vectors must match timestamp length"

    state_vectors = Vector{StateVector}(undef, n)

    for i in 1:n
        # If VIX1D unavailable, set PC₃ to NaN (will be handled downstream)
        pc3_val = vix1d_available ? pc3[i] : NaN

        state_vectors[i] = StateVector(
            timestamps[i],
            pc1[i],
            pc2[i],
            pc3_val,
            level[i],
            slope[i],
            curvature[i]
        )
    end

    return state_vectors
end

"""
    assemble_state_vector(
        vol_pcs::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
        yield_factors::Tuple{Vector{Float64},Vector{Float64},Vector{Float64}},
        vix1d_available::Bool,
        timestamp::ZonedDateTime
    ) -> StateVector

Assemble a single state vector (convenience method for real-time updates).
"""
function assemble_state_vector(
    vol_pcs::Tuple{Float64,Float64,Float64},
    yield_factors::Tuple{Float64,Float64,Float64},
    vix1d_available::Bool,
    timestamp::ZonedDateTime
)::StateVector

    pc1, pc2, pc3 = vol_pcs
    level, slope, curvature = yield_factors

    pc3_val = vix1d_available ? pc3 : NaN

    return StateVector(
        timestamp,
        pc1, pc2, pc3_val,
        level, slope, curvature
    )
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

"""
    _standardize(X::Matrix{Float64}) -> Matrix{Float64}

Z-score standardize each row (variable) of matrix X.
"""
function _standardize(X::Matrix{Float64})::Matrix{Float64}
    X_std = similar(X)
    for i in 1:size(X, 1)
        row = X[i, :]
        mu = mean(row)
        sigma = std(row)
        if sigma > 0
            X_std[i, :] = (row .- mu) ./ sigma
        else
            X_std[i, :] .= 0.0
        end
    end
    return X_std
end

"""
    _standardize_row(x::Vector{Float64}, pca) -> Vector{Float64}

Standardize a single observation using PCA model statistics.
Simplified: assumes data was standardized before PCA fit.
"""
function _standardize_row(x::Vector{Float64}, pca)::Vector{Float64}
    # In production: store and use means/stds from training data
    # For now: assume input is already appropriately scaled
    return x
end

"""
    _find_closest_maturity(maturities::Vector{Float64}, target::Float64) -> Int

Find index of maturity closest to target.
"""
function _find_closest_maturity(maturities::Vector{Float64}, target::Float64)::Int
    distances = abs.(maturities .- target)
    return argmin(distances)
end

end  # module PCACompression
