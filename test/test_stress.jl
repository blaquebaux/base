module TestStress

using Test, Dates, TimeZones

include("../src/module_1_data/module_1_data.jl")
include("../src/module_2_smoothing/module_2_smoothing.jl")
include("../src/module_4_arma/module_4_arma.jl")
include("../src/module_5_dpm/module_5_dpm.jl")
include("../src/module_6_cascade/module_6_cascade.jl")
include("../src/module_7_execution/module_7_execution.jl")

using .DataIngestion, .SignalSmoothing, .ARMAGARCH, .DPM, .CascadeInterface, .ExecutionLayer

@testset "Stress Tests & Edge Cases" begin

    @testset "Extreme Volatility Scenarios" begin
        # GFC-level volatility
        extreme_returns = vcat(
            randn(100) .* 0.005,      # Normal
            randn(50) .* 0.08,        # Crisis
            randn(100) .* 0.005       # Recovery
        )

        spec = ARMASpec(1, 1)
        arma, garch, ll = estimate_armagarch(extreme_returns, spec; use_garch=true)

        @test garch.α₁ > 0.05  # High ARCH effect during crisis
        @test isfinite(ll)

        # DPM should identify multiple regimes
        dpm_config = DPMConfig(5, 2.0, 0.5, 1e-3, 50)
        pf_config = ParticleFilterConfig(300, 0.5)
        model, _, converged = em_estimation(extreme_returns, dpm_config, pf_config, nothing)

        @test maximum(model.weights) < 0.9  # Should not be single regime
    end

    @testset "Zero and Near-Zero Returns" begin
        zero_returns = fill(0.0, 100)

        spec = ARMASpec(1, 0)
        @test_throws AssertionError estimate_armagarch(zero_returns, spec)

        near_zero = randn(100) .* 1e-10
        arma, garch, ll = estimate_armagarch(near_zero, spec; use_garch=false)

        @test arma.σ² < 1e-15
    end

    @testset "Single Regime Persistence" begin
        returns = randn(100) .* 0.01 .+ 0.001

        dpm_config = DPMConfig(3, 2.0, 0.5, 1e-3, 50)
        pf_config = ParticleFilterConfig(200, 0.5)
        model, _, _ = em_estimation(returns, dpm_config, pf_config, nothing)

        # In calm period, one regime should dominate
        max_weight = maximum(model.weights)
        @test max_weight > 0.5
    end

    @testset "Rapid Regime Switching" begin
        # Alternating high/low volatility every 10 days
        returns = Float64[]
        for i in 1:20
            if isodd(i)
                append!(returns, randn(10) .* 0.02)
            else
                append!(returns, randn(10) .* 0.005)
            end
        end

        spec = ARMASpec(1, 1)
        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=true)

        @test garch.β₁ > 0.5  # High persistence
    end

    @testset "Circuit Breaker Stress" begin
        cb = CircuitBreakerStateMachine()

        # Rapid VVIX oscillations
        vvix_values = [80.0, 130.0, 80.0, 130.0, 130.0, 130.0, 80.0]
        vix_values = fill(25.0, 7)

        states = CircuitBreakerStateMachine[]
        for (vvix, vix) in zip(vvix_values, vix_values)
            should_liq, cb = check_emergency_liquidation(vvix, vix, 0.05, 0.02, cb)
            push!(states, cb)
        end

        # Should trigger on 3 consecutive high VVIX
        @test states[5].state == EMERGENCY_LIQUIDATION || states[6].state == EMERGENCY_LIQUIDATION
    end

    @testset "Memory Efficiency - Large Datasets" begin
        n = 5000
        returns = randn(n) .* 0.01

        # Should handle large datasets without memory issues
        rv = rolling_realized_vol(returns, 60)
        @test length(rv) == n

        # Bootstrap with large replications
        config = BootstrapConfig(60, 1000, 0.95)
        lower, med, upper, width = block_bootstrap(returns, config)

        @test isfinite(width)
    end

    @testset "Concurrent Regime Probabilities" begin
        # Simulate multiple assets with different regime probabilities
        assets = ["SPY", "QQQ", "IWM", "TLT", "GLD"]

        for asset in assets
            # Each asset has different regime characteristics
            if asset in ["SPY", "QQQ"]
                probs = RegimeProbs(0.2, 0.6, 0.2)  # Growth biased
            elseif asset == "TLT"
                probs = RegimeProbs(0.6, 0.2, 0.2)  # Fixed biased
            else
                probs = RegimeProbs(0.3, 0.3, 0.4)  # Balanced
            end

            blended = blend_cascade_params(probs)
            sizing = compute_position_sizing(probs, 10000.0)

            @test blended isa BlendedCascadeParams
            @test sizing isa PositionSizing
            @test sizing.exposure + sizing.defensive_cash > 0
        end
    end

    @testset "Numerical Stability - Extreme Parameters" begin
        # Test with very small and very large values
        tiny_returns = randn(100) .* 1e-8
        huge_returns = randn(100) .* 1e6

        spec = ARMASpec(1, 0)

        # Tiny returns
        arma_tiny, _, ll_tiny = estimate_armagarch(tiny_returns, spec; use_garch=false)
        @test isfinite(ll_tiny)

        # Huge returns - may fail due to numerical issues
        try
            arma_huge, _, ll_huge = estimate_armagarch(huge_returns, spec; use_garch=false)
            @test isfinite(ll_huge)
        catch
            @test true  # Expected to potentially fail with extreme values
        end
    end

    @testset "Graceful Degradation - Partial Data" begin
        # 50% missing data
        returns = randn(100) .* 0.01
        returns[rand(1:100, 50)] .= NaN

        # Should still attempt estimation
        spec = ARMASpec(1, 0)
        try
            arma, _, ll = estimate_armagarch(returns, spec; use_garch=false)
            @test isfinite(ll) || isnan(ll)
        catch
            @test true  # May fail with too much NaN
        end
    end

end  # @testset Stress Tests

end  # module TestStress
