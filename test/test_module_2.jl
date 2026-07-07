module TestSignalSmoothing

using Test

include("../src/module_2_smoothing/module_2_smoothing.jl")
using .SignalSmoothing

@testset "SignalSmoothing Module - Comprehensive" begin

    # =========================================================================
    # Configuration Structure Tests
    # =========================================================================
    @testset "LOWESSConfig" begin
        config = LOWESSConfig(0.35, 3)
        @test config.bandwidth == 0.35
        @test config.iterations == 3

        # Default constructor
        default = LOWESSConfig()
        @test default.bandwidth == 0.35
        @test default.iterations == 3
    end

    @testset "LOWESSConfig Validation" begin
        @test_throws AssertionError LOWESSConfig(1.5, 3)  # bandwidth > 1
        @test_throws AssertionError LOWESSConfig(0.35, 0)  # iterations < 1
        @test_throws AssertionError LOWESSConfig(-0.1, 3)  # bandwidth < 0
    end

    @testset "SGConfig" begin
        config = SGConfig(21, 3)
        @test config.window_length == 21
        @test config.polynomial_degree == 3
        @test isodd(config.window_length)

        default = SGConfig()
        @test default.window_length == 21
        @test default.polynomial_degree == 3
    end

    @testset "SGConfig Validation" begin
        @test_throws AssertionError SGConfig(20, 3)   # even window
        @test_throws AssertionError SGConfig(21, 21)  # degree >= window
        @test_throws AssertionError SGConfig(3, 5)    # degree > window
    end

    @testset "AdaptiveMedianConfig" begin
        config = AdaptiveMedianConfig(60, 10, 30)
        @test config.calm_window == 60
        @test config.stress_window == 10
        @test config.transition_window == 30

        default = AdaptiveMedianConfig()
        @test default.calm_window == 60
        @test default.stress_window == 10
    end

    @testset "AdaptiveMedianConfig Validation" begin
        @test_throws AssertionError AdaptiveMedianConfig(10, 20, 15)  # calm < stress
    end

    @testset "BootstrapConfig" begin
        config = BootstrapConfig(60, 5000, 0.95)
        @test config.block_length == 60
        @test config.replications == 5000
        @test config.confidence_level == 0.95

        default = BootstrapConfig()
        @test default.block_length == 60
    end

    @testset "BootstrapConfig Validation" begin
        @test_throws AssertionError BootstrapConfig(0, 1000, 0.95)   # block_length < 1
        @test_throws AssertionError BootstrapConfig(60, 50, 0.95)    # replications < 100
        @test_throws AssertionError BootstrapConfig(60, 1000, 1.5)  # confidence > 1
        @test_throws AssertionError BootstrapConfig(60, 1000, 0.0)  # confidence = 0
    end

    @testset "SmoothingPipelineConfig" begin
        config = SmoothingPipelineConfig()
        @test config.lowess isa LOWESSConfig
        @test config.sg isa SGConfig
        @test config.adaptive_median isa AdaptiveMedianConfig
        @test config.bootstrap isa BootstrapConfig
    end

    # =========================================================================
    # LOWESS Smoothing Tests
    # =========================================================================
    @testset "lowess_smooth - Basic" begin
        x = Float64.(1:100)
        y = sin.(x ./ 10) .+ randn(100) .* 0.1

        config = LOWESSConfig(0.3, 2)
        smoothed = lowess_smooth(x, y, config)

        @test length(smoothed) == length(y)
        @test all(.!isnan.(smoothed))
    end

    @testset "lowess_smooth - With NaN" begin
        x = Float64.(1:100)
        y = sin.(x ./ 10)
        y[50] = NaN

        config = LOWESSConfig(0.3, 2)
        smoothed = lowess_smooth(x, y, config)

        @test length(smoothed) == 100
    end

    @testset "lowess_smooth - Time Series Convenience" begin
        y = randn(50)
        config = LOWESSConfig(0.3, 2)
        smoothed = lowess_smooth(y, config)

        @test length(smoothed) == 50
    end

    @testset "lowess_smooth - Input Validation" begin
        @test_throws AssertionError lowess_smooth([1.0, 2.0], [1.0, 2.0, 3.0], LOWESSConfig())
        @test_throws AssertionError lowess_smooth([1.0], [1.0], LOWESSConfig())
    end

    @testset "lowess_smooth - Smoothing Effect" begin
        x = Float64.(1:100)
        y = sin.(x ./ 10) .+ randn(100) .* 0.5  # Noisy

        config = LOWESSConfig(0.5, 3)
        smoothed = lowess_smooth(x, y, config)

        # Smoothed should have lower variance
        orig_var = var(y)
        smooth_var = var(smoothed)
        @test smooth_var < orig_var
    end

    # =========================================================================
    # Savitzky-Golay Filter Tests
    # =========================================================================
    @testset "savgol_filter - Linear Signal" begin
        signal = Float64.(1:100)
        config = SGConfig(21, 3)
        filtered = savgol_filter(signal, config)

        @test length(filtered) == length(signal)
        # Should approximately preserve linear trend
        @test filtered[end] > filtered[1]
    end

    @testset "savgol_filter - Sine Wave" begin
        signal = sin.(Float64.(1:100) ./ 5)
        config = SGConfig(21, 3)
        filtered = savgol_filter(signal, config)

        @test length(filtered) == length(signal)
        @test all(.!isnan.(filtered))
    end

    @testset "savgol_filter - Boundary Handling" begin
        signal = randn(30)
        config = SGConfig(21, 3)
        filtered = savgol_filter(signal, config)

        @test length(filtered) == 30
        @test all(.!isnan.(filtered))
    end

    @testset "savgol_filter - Input Validation" begin
        signal = randn(10)
        config = SGConfig(21, 3)
        @test_throws AssertionError savgol_filter(signal, config)
    end

    # =========================================================================
    # Adaptive Rolling Median Tests
    # =========================================================================
    @testset "adaptive_rolling_median - Calm Regime" begin
        signal = randn(100)
        ratios = fill(0.85, 100)  # VIX/VXV < 0.9 → calm

        config = AdaptiveMedianConfig(60, 10, 30)
        result = adaptive_rolling_median(signal, ratios, config)

        @test length(result) == length(signal)
        @test all(.!isnan.(result))
    end

    @testset "adaptive_rolling_median - Stress Regime" begin
        signal = randn(100)
        ratios = fill(1.2, 100)  # VIX/VXV > 1.1 → stress

        config = AdaptiveMedianConfig(60, 10, 30)
        result = adaptive_rolling_median(signal, ratios, config)

        @test length(result) == length(signal)
    end

    @testset "adaptive_rolling_median - Transition Regime" begin
        signal = randn(100)
        ratios = fill(1.0, 100)  # 0.9 < VIX/VXV < 1.1 → transition

        config = AdaptiveMedianConfig(60, 10, 30)
        result = adaptive_rolling_median(signal, ratios, config)

        @test length(result) == length(signal)
    end

    @testset "adaptive_rolling_median - Mixed Regimes" begin
        signal = randn(100)
        ratios = vcat(fill(0.85, 33), fill(1.0, 34), fill(1.2, 33))

        config = AdaptiveMedianConfig()
        result = adaptive_rolling_median(signal, ratios, config)

        @test length(result) == 100
    end

    @testset "adaptive_rolling_median - With NaN" begin
        signal = randn(50)
        signal[25] = NaN
        ratios = fill(0.85, 50)

        config = AdaptiveMedianConfig()
        result = adaptive_rolling_median(signal, ratios, config)

        @test length(result) == 50
    end

    @testset "adaptive_rolling_median - Input Validation" begin
        signal = randn(50)
        ratios = rand(40)
        @test_throws AssertionError adaptive_rolling_median(signal, ratios, AdaptiveMedianConfig())
    end

    # =========================================================================
    # Block Bootstrap Tests
    # =========================================================================
    @testset "block_bootstrap - Normal Data" begin
        data = randn(200)
        config = BootstrapConfig(30, 1000, 0.95)

        lower, med, upper, width = block_bootstrap(data, config)

        @test lower < med
        @test med < upper
        @test width > 0
        @test width == upper - lower
    end

    @testset "block_bootstrap - Confidence Levels" begin
        data = randn(200)

        config_95 = BootstrapConfig(30, 1000, 0.95)
        l1, m1, u1, w1 = block_bootstrap(data, config_95)

        config_80 = BootstrapConfig(30, 1000, 0.80)
        l2, m2, u2, w2 = block_bootstrap(data, config_80)

        # 80% CI should be narrower than 95% CI
        @test w2 < w1
    end

    @testset "block_bootstrap - Median Near Zero" begin
        data = randn(500)
        config = BootstrapConfig(30, 2000, 0.95)

        lower, med, upper, width = block_bootstrap(data, config)

        # Median should be close to 0 for standard normal
        @test abs(med) < 0.2
    end

    @testset "block_bootstrap - With NaN" begin
        data = vcat(randn(190), fill(NaN, 10))
        config = BootstrapConfig(30, 500, 0.95)

        lower, med, upper, width = block_bootstrap(data, config)

        @test all(.!isnan.([lower, med, upper, width]))
    end

    @testset "block_bootstrap - All NaN" begin
        data = fill(NaN, 100)
        config = BootstrapConfig(30, 500, 0.95)

        lower, med, upper, width = block_bootstrap(data, config)

        @test all(isnan.([lower, med, upper, width]))
    end

    # =========================================================================
    # Combined Pipeline Tests
    # =========================================================================
    @testset "smooth_correlation_series - Full Pipeline" begin
        raw_corr = randn(200) .* 0.5
        ratios = rand(200) .* 0.4 .+ 0.7

        config = SmoothingPipelineConfig()
        smoothed, envelope = smooth_correlation_series(raw_corr, ratios, config)

        @test length(smoothed) == length(raw_corr)
        @test length(envelope) == length(raw_corr)
        @test all(.!isnan.(smoothed))
        @test all(envelope .>= 0)
    end

    @testset "smooth_correlation_series - Custom Config" begin
        raw_corr = randn(100)
        ratios = fill(0.9, 100)

        config = SmoothingPipelineConfig(
            LOWESSConfig(0.2, 2),
            SGConfig(21, 3),
            AdaptiveMedianConfig(40, 8, 20),
            BootstrapConfig(20, 500, 0.90)
        )

        smoothed, envelope = smooth_correlation_series(raw_corr, ratios, config)

        @test length(smoothed) == 100
    end

    @testset "smooth_correlation_series - Smoothing Effect" begin
        # Create a signal with known trend
        raw_corr = sin.(Float64.(1:200) ./ 20) .+ randn(200) .* 0.3
        ratios = fill(0.85, 200)

        config = SmoothingPipelineConfig()
        smoothed, envelope = smooth_correlation_series(raw_corr, ratios, config)

        # Smoothed should have lower variance than raw
        @test var(smoothed) < var(raw_corr)
    end

    # =========================================================================
    # Gibbs Artifact Detection Tests
    # =========================================================================
    @testset "detect_gibbs_artifacts - Spike Detection" begin
        residuals = randn(100) .* 0.1
        residuals[50] = 10.0  # Large spike

        artifacts = detect_gibbs_artifacts(residuals, 3.0)

        @test 50 in artifacts
        @test length(artifacts) >= 1
    end

    @testset "detect_gibbs_artifacts - No Artifacts" begin
        residuals = randn(100) .* 0.1

        artifacts = detect_gibbs_artifacts(residuals, 5.0)

        @test length(artifacts) == 0
    end

    @testset "detect_gibbs_artifacts - Multiple Spikes" begin
        residuals = randn(100) .* 0.1
        residuals[25] = 8.0
        residuals[50] = -9.0
        residuals[75] = 7.5

        artifacts = detect_gibbs_artifacts(residuals, 3.0)

        @test 25 in artifacts
        @test 50 in artifacts
        @test 75 in artifacts
    end

    @testset "detect_gibbs_artifacts - With NaN" begin
        residuals = randn(50) .* 0.1
        residuals[25] = NaN
        residuals[30] = 10.0

        artifacts = detect_gibbs_artifacts(residuals, 3.0)

        @test 30 in artifacts
    end

    @testset "detect_gibbs_artifacts - All NaN" begin
        residuals = fill(NaN, 50)
        artifacts = detect_gibbs_artifacts(residuals, 3.0)

        @test length(artifacts) == 0
    end

    @testset "detect_gibbs_artifacts - Zero Std" begin
        residuals = fill(0.5, 50)
        artifacts = detect_gibbs_artifacts(residuals, 3.0)

        @test length(artifacts) == 0
    end

end  # @testset SignalSmoothing Module

end  # module TestSignalSmoothing
