module SignalSmoothing

using Loess, DSP, Statistics, Random

export LOWESSConfig, SGConfig, AdaptiveMedianConfig, BootstrapConfig, SmoothingPipelineConfig,
       lowess_smooth, savgol_filter, adaptive_rolling_median, block_bootstrap,
       smooth_correlation_series, detect_gibbs_artifacts

# ============================================================================
# Configuration Structures
# ============================================================================

"""
    LOWESSConfig

Configuration for Locally Weighted Scatterplot Smoothing (LOWESS).

# Fields
- `bandwidth::Float64`: Smoothing parameter h (default: 0.35)
- `iterations::Int`: Number of robustifying iterations (default: 3)
"""
struct LOWESSConfig
    bandwidth::Float64
    iterations::Int

    function LOWESSConfig(bandwidth::Float64=0.35, iterations::Int=3)
        @assert 0.0 < bandwidth <= 1.0 "Bandwidth must be in (0, 1]"
        @assert iterations >= 1 "At least 1 iteration required"
        new(bandwidth, iterations)
    end
end

"""
    SGConfig

Configuration for Savitzky-Golay filter.

# Fields
- `window_length::Int`: Filter window length (must be odd, default: 21)
- `polynomial_degree::Int`: Polynomial degree for fitting (default: 3)
"""
struct SGConfig
    window_length::Int
    polynomial_degree::Int

    function SGConfig(window_length::Int=21, polynomial_degree::Int=3)
        @assert isodd(window_length) "Window length must be odd"
        @assert window_length > polynomial_degree "Window length must exceed polynomial degree"
        new(window_length, polynomial_degree)
    end
end

"""
    AdaptiveMedianConfig

Configuration for adaptive rolling median with regime-dependent windows.

# Fields
- `calm_window::Int`: Window in calm regime (VIX/VXV < 0.9), default: 60
- `stress_window::Int`: Window in stress regime (VIX/VXV > 1.1), default: 10
- `transition_window::Int`: Window in transition (interpolated), default: 30
"""
struct AdaptiveMedianConfig
    calm_window::Int
    stress_window::Int
    transition_window::Int

    function AdaptiveMedianConfig(
        calm_window::Int=60, 
        stress_window::Int=10, 
        transition_window::Int=30
    )
        @assert calm_window > stress_window "Calm window must exceed stress window"
        new(calm_window, stress_window, transition_window)
    end
end

"""
    BootstrapConfig

Configuration for stationary block bootstrap.

# Fields
- `block_length::Int`: Expected block length (default: 60)
- `replications::Int`: Number of bootstrap replications (default: 5000)
- `confidence_level::Float64`: Confidence level for intervals (default: 0.95)
"""
struct BootstrapConfig
    block_length::Int
    replications::Int
    confidence_level::Float64

    function BootstrapConfig(
        block_length::Int=60, 
        replications::Int=5000, 
        confidence_level::Float64=0.95
    )
        @assert block_length >= 1 "Block length must be positive"
        @assert replications >= 100 "At least 100 replications recommended"
        @assert 0.0 < confidence_level < 1.0 "Confidence level must be in (0, 1)"
        new(block_length, replications, confidence_level)
    end
end

"""
    SmoothingPipelineConfig

Complete configuration for the 4-stage smoothing pipeline.
"""
struct SmoothingPipelineConfig
    lowess::LOWESSConfig
    sg::SGConfig
    adaptive_median::AdaptiveMedianConfig
    bootstrap::BootstrapConfig
end

# Default pipeline configuration
function SmoothingPipelineConfig()
    SmoothingPipelineConfig(
        LOWESSConfig(),
        SGConfig(),
        AdaptiveMedianConfig(),
        BootstrapConfig()
    )
end

# ============================================================================
# Stage 1: LOWESS Smoothing
# ============================================================================

"""
    lowess_smooth(x::Vector{Float64}, y::Vector{Float64}, config::LOWESSConfig) -> Vector{Float64}

Apply LOWESS smoothing to data (x, y).

Uses the Loess.jl package for robust locally weighted regression.
"""
function lowess_smooth(
    x::Vector{Float64}, 
    y::Vector{Float64}, 
    config::LOWESSConfig=LOWESSConfig()
)::Vector{Float64}
    @assert length(x) == length(y) "x and y must have same length"
    @assert length(x) >= 3 "Need at least 3 observations"

    n = length(x)

    # Handle NaN values
    valid_idx = findall(.!isnan.(x) .& .!isnan.(y))
    if length(valid_idx) < 3
        return fill(NaN, n)
    end

    x_valid = x[valid_idx]
    y_valid = y[valid_idx]

    # Fit Loess model
    model = loess(x_valid, y_valid, span=config.bandwidth)

    # Predict on full x grid
    smoothed = predict(model, x)

    # Robust iterations: re-weight by residuals
    for iter in 1:config.iterations
        residuals = y - smoothed
        mad_val = median(abs.(residuals[.!isnan.(residuals)]))

        if mad_val > 0
            weights = @. min(1.0, (6.0 * mad_val / abs(residuals))^2)
            weights[isnan.(weights)] .= 0.0

            # Re-fit with weights (simplified: use weighted least squares approximation)
            weighted_y = y .* weights
            model = loess(x_valid, y_valid[valid_idx], span=config.bandwidth)
            smoothed = predict(model, x)
        end
    end

    return smoothed
end

# Convenience method for time series (implicit x = 1:n)
function lowess_smooth(y::Vector{Float64}, config::LOWESSConfig=LOWESSConfig())::Vector{Float64}
    x = Float64.(1:length(y))
    lowess_smooth(x, y, config)
end

# ============================================================================
# Stage 2: Savitzky-Golay Filter
# ============================================================================

"""
    savgol_filter(signal::Vector{Float64}, config::SGConfig) -> Vector{Float64}

Apply Savitzky-Golay filter for noise reduction while preserving peaks.

Uses polynomial least-squares fitting within sliding window.
"""
function savgol_filter(
    signal::Vector{Float64}, 
    config::SGConfig=SGConfig()
)::Vector{Float64}
    n = length(signal)
    window = config.window_length
    half_window = div(window - 1, 2)
    polyorder = config.polynomial_degree

    @assert n >= window "Signal length must exceed window length"

    # Build Savitzky-Golay coefficients
    # Coefficients for central point of symmetric window
    coeffs = _savgol_coeffs(half_window, polyorder)

    filtered = similar(signal)

    for i in 1:n
        # Determine window bounds
        left = max(1, i - half_window)
        right = min(n, i + half_window)

        # Adjust coefficients for boundary
        window_vals = signal[left:right]
        window_size = length(window_vals)

        if window_size == window
            # Full window: use pre-computed coefficients
            filtered[i] = dot(coeffs, window_vals)
        else
            # Boundary: fit polynomial directly
            x_window = Float64.(1:window_size) .- Float64(div(window_size + 1, 2))
            filtered[i] = _polyfit_val(x_window, window_vals, polyorder, 0.0)
        end
    end

    return filtered
end

"""
    _savgol_coeffs(half_window::Int, polyorder::Int) -> Vector{Float64}

Compute Savitzky-Golay convolution coefficients for central point.
"""
function _savgol_coeffs(half_window::Int, polyorder::Int)::Vector{Float64}
    window_size = 2 * half_window + 1
    x = Float64.(-half_window:half_window)

    # Build Vandermonde matrix
    A = [x[i]^j for i in 1:window_size, j in 0:polyorder]

    # Coefficients for evaluating at x=0 (central point)
    # This is the first row of (A'A)^(-1)A'
    coeffs = (A * inv(A'A))[:, 1]

    return coeffs
end

"""
    _polyfit_val(x::Vector{Float64}, y::Vector{Float64}, order::Int, x_eval::Float64) -> Float64

Fit polynomial and evaluate at x_eval.
"""
function _polyfit_val(
    x::Vector{Float64}, 
    y::Vector{Float64}, 
    order::Int, 
    x_eval::Float64
)::Float64
    n = length(x)
    A = [x[i]^j for i in 1:n, j in 0:order]
    coeffs = A \ y

    result = 0.0
    for j in 0:order
        result += coeffs[j+1] * x_eval^j
    end
    return result
end

# ============================================================================
# Stage 3: Adaptive Rolling Median
# ============================================================================

"""
    adaptive_rolling_median(
        signal::Vector{Float64},
        vix_vxv_ratio::Vector{Float64},
        config::AdaptiveMedianConfig=AdaptiveMedianConfig()
    ) -> Vector{Float64}

Apply adaptive rolling median with window size determined by VIX/VXV regime.

# Regime Mapping
- VIX/VXV < 0.9: Calm → long window (60 days)
- VIX/VXV > 1.1: Stress → short window (10 days)
- 0.9 ≤ VIX/VXV ≤ 1.1: Transition → interpolated window (30 days)
"""
function adaptive_rolling_median(
    signal::Vector{Float64},
    vix_vxv_ratio::Vector{Float64},
    config::AdaptiveMedianConfig=AdaptiveMedianConfig()
)::Vector{Float64}
    n = length(signal)
    @assert n == length(vix_vxv_ratio) "signal and vix_vxv_ratio must have same length"

    result = similar(signal)

    for i in 1:n
        # Determine window size based on regime
        ratio = vix_vxv_ratio[i]

        window_size = if ratio < 0.9
            config.calm_window
        elseif ratio > 1.1
            config.stress_window
        else
            # Linear interpolation in transition zone
            t = (ratio - 0.9) / (1.1 - 0.9)
            round(Int, config.calm_window * (1 - t) + config.stress_window * t)
        end

        # Compute rolling median
        half_window = div(window_size, 2)
        left = max(1, i - half_window)
        right = min(n, i + half_window)

        window_vals = signal[left:right]
        valid_vals = window_vals[.!isnan.(window_vals)]

        if isempty(valid_vals)
            result[i] = NaN
        else
            result[i] = median(valid_vals)
        end
    end

    return result
end

# ============================================================================
# Stage 4: Stationary Block Bootstrap
# ============================================================================

"""
    block_bootstrap(
        data::Vector{Float64},
        config::BootstrapConfig=BootstrapConfig()
    ) -> Tuple{Float64, Float64, Float64, Float64}

Apply stationary block bootstrap to estimate confidence intervals.

# Returns
- `lower::Float64`: Lower confidence bound
- `median::Float64`: Bootstrap median
- `upper::Float64`: Upper confidence bound
- `envelope_width::Float64`: Upper - Lower (measure of uncertainty)
"""
function block_bootstrap(
    data::Vector{Float64},
    config::BootstrapConfig=BootstrapConfig()
)::Tuple{Float64, Float64, Float64, Float64}

    n = length(data)
    valid_data = data[.!isnan.(data)]

    if isempty(valid_data)
        return (NaN, NaN, NaN, NaN)
    end

    B = config.replications
    b = config.block_length
    alpha = 1.0 - config.confidence_level

    # Bootstrap replications
    bootstrap_medians = Vector{Float64}(undef, B)

    for rep in 1:B
        # Generate bootstrap sample using stationary blocks
        bootstrap_sample = _stationary_bootstrap_sample(valid_data, b)
        bootstrap_medians[rep] = median(bootstrap_sample)
    end

    # Compute confidence intervals
    sorted_medians = sort(bootstrap_medians)
    lower_idx = max(1, ceil(Int, alpha / 2 * B))
    upper_idx = min(B, floor(Int, (1 - alpha / 2) * B))

    lower = sorted_medians[lower_idx]
    upper = sorted_medians[upper_idx]
    med = median(bootstrap_medians)
    envelope = upper - lower

    return (lower, med, upper, envelope)
end

"""
    _stationary_bootstrap_sample(data::Vector{Float64}, block_length::Int) -> Vector{Float64}

Generate a single bootstrap sample using stationary block bootstrap.
Block lengths are geometrically distributed with mean block_length.
"""
function _stationary_bootstrap_sample(
    data::Vector{Float64}, 
    block_length::Int
)::Vector{Float64}
    n = length(data)
    p = 1.0 / block_length  # Geometric parameter

    sample = Float64[]

    while length(sample) < n
        # Random starting point
        start_idx = rand(1:n)
        # Geometric block length
        block_len = rand(Geometric(p)) + 1

        for j in 0:(block_len-1)
            if length(sample) >= n
                break
            end
            idx = mod(start_idx + j - 1, n) + 1  # Wrap around
            push!(sample, data[idx])
        end
    end

    return sample[1:n]
end

# Define Geometric distribution for block lengths
struct Geometric
    p::Float64
end

Base.rand(g::Geometric) = floor(Int, log(rand()) / log(1 - g.p))

# ============================================================================
# Combined Pipeline
# ============================================================================

"""
    smooth_correlation_series(
        raw_correlation::Vector{Float64},
        vix_vxv_ratio::Vector{Float64},
        config::SmoothingPipelineConfig=SmoothingPipelineConfig()
    ) -> Tuple{Vector{Float64}, Vector{Float64}}

Apply the complete 4-stage smoothing pipeline to a correlation series.

# Pipeline Stages
1. LOWESS robust smoothing
2. Savitzky-Golay on residuals
3. Adaptive rolling median
4. Block bootstrap for uncertainty envelope

# Returns
- `smoothed::Vector{Float64}`: Final smoothed series
- `envelope_width::Vector{Float64}`: Bootstrap uncertainty at each point
"""
function smooth_correlation_series(
    raw_correlation::Vector{Float64},
    vix_vxv_ratio::Vector{Float64},
    config::SmoothingPipelineConfig=SmoothingPipelineConfig()
)::Tuple{Vector{Float64}, Vector{Float64}}

    n = length(raw_correlation)

    # Stage 1: LOWESS
    lowess_smoothed = lowess_smooth(raw_correlation, config.lowess)

    # Stage 2: Savitzky-Golay on residuals
    residuals = raw_correlation - lowess_smoothed
    sg_residuals = savgol_filter(residuals, config.sg)

    # Combine: LOWESS trend + SG-smoothed residuals
    sg_combined = lowess_smoothed + sg_residuals

    # Stage 3: Adaptive rolling median
    adaptive_smoothed = adaptive_rolling_median(sg_combined, vix_vxv_ratio, config.adaptive_median)

    # Stage 4: Block bootstrap for uncertainty envelope
    # Apply bootstrap to local windows
    envelope_width = Vector{Float64}(undef, n)

    window_size = config.bootstrap.block_length
    half_window = div(window_size, 2)

    for i in 1:n
        left = max(1, i - half_window)
        right = min(n, i + half_window)
        local_data = adaptive_smoothed[left:right]

        _, _, _, width = block_bootstrap(local_data, config.bootstrap)
        envelope_width[i] = width
    end

    return (adaptive_smoothed, envelope_width)
end

# ============================================================================
# Gibbs Artifact Detection
# ============================================================================

"""
    detect_gibbs_artifacts(
        residuals::Vector{Float64},
        threshold_sigma::Float64=5.0
    ) -> Vector{Int}

Detect Gibbs phenomenon artifacts in residuals after SG filtering.

Artifacts appear as oscillatory patterns near sharp transitions.
Flag points where residual exceeds threshold_sigma standard deviations.

# Returns
- Vector of indices where artifacts are detected
"""
function detect_gibbs_artifacts(
    residuals::Vector{Float64},
    threshold_sigma::Float64=5.0
)::Vector{Int}
    valid_residuals = residuals[.!isnan.(residuals)]

    if isempty(valid_residuals)
        return Int[]
    end

    sigma = std(valid_residuals)
    mu = mean(valid_residuals)

    if sigma == 0
        return Int[]
    end

    artifact_indices = Int[]

    for i in eachindex(residuals)
        if !isnan(residuals[i])
            z_score = abs(residuals[i] - mu) / sigma
            if z_score > threshold_sigma
                push!(artifact_indices, i)
            end
        end
    end

    return artifact_indices
end

end  # module SignalSmoothing
