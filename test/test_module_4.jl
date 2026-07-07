module TestARMAGARCH

using Test

include("../src/module_4_arma/module_4_arma.jl")
using .ARMAGARCH

@testset "ARMAGARCH Module - Comprehensive" begin

    # =========================================================================
    # ARMASpec Tests
    # =========================================================================
    @testset "ARMASpec - Valid Specifications" begin
        spec_11 = ARMASpec(1, 1)
        @test spec_11.p == 1
        @test spec_11.q == 1

        spec_20 = ARMASpec(2, 0)
        @test spec_20.p == 2
        @test spec_20.q == 0

        spec_02 = ARMASpec(0, 2)
        @test spec_02.p == 0
        @test spec_02.q == 2

        spec_22 = ARMASpec(2, 2)
        @test spec_22.p == 2
        @test spec_22.q == 2
    end

    @testset "ARMASpec - Invalid Specifications" begin
        @test_throws AssertionError ARMASpec(3, 1)   # p > 2
        @test_throws AssertionError ARMASpec(1, 3)   # q > 2
        @test_throws AssertionError ARMASpec(0, 0)   # p + q = 0
        @test_throws AssertionError ARMASpec(-1, 1)  # p < 0
        @test_throws AssertionError ARMASpec(1, -1)  # q < 0
    end

    # =========================================================================
    # ARMAParams Tests
    # =========================================================================
    @testset "ARMAParams - Valid" begin
        params = ARMAParams(0.001, [0.3], [0.2], 0.0004)
        @test params.μ ≈ 0.001
        @test params.φ ≈ [0.3]
        @test params.θ ≈ [0.2]
        @test params.σ² ≈ 0.0004
    end

    @testset "ARMAParams - Zero Variance" begin
        @test_throws AssertionError ARMAParams(0.0, [0.1], [0.1], 0.0)
    end

    @testset "ARMAParams - Negative Variance" begin
        @test_throws AssertionError ARMAParams(0.0, [0.1], [0.1], -0.001)
    end

    @testset "ARMAParams - Multiple Coefficients" begin
        params = ARMAParams(0.001, [0.3, 0.1], [0.2, 0.05], 0.0004)
        @test length(params.φ) == 2
        @test length(params.θ) == 2
    end

    # =========================================================================
    # GARCHParams Tests
    # =========================================================================
    @testset "GARCHParams - Valid" begin
        garch = GARCHParams(0.00001, 0.1, 0.85)
        @test garch.ω ≈ 0.00001
        @test garch.α₁ ≈ 0.1
        @test garch.β₁ ≈ 0.85
        @test garch.γ ≈ 0.0
        @test garch.α₁ + garch.β₁ < 1.0
    end

    @testset "GARCHParams - With Jump" begin
        garch = GARCHParams(0.00001, 0.1, 0.85, 0.5)
        @test garch.γ ≈ 0.5
    end

    @testset "GARCHParams - Stationarity Boundary" begin
        # α + β = 0.999 (just under 1.0)
        garch = GARCHParams(0.00001, 0.149, 0.85)
        @test garch.α₁ + garch.β₁ ≈ 0.999
    end

    @testset "GARCHParams - Invalid" begin
        @test_throws AssertionError GARCHParams(-0.01, 0.1, 0.85)   # ω < 0
        @test_throws AssertionError GARCHParams(0.01, -0.1, 0.85)  # α < 0
        @test_throws AssertionError GARCHParams(0.01, 0.1, -0.85)   # β < 0
        @test_throws AssertionError GARCHParams(0.01, 0.6, 0.5)    # α + β >= 1
    end

    # =========================================================================
    # RegimeModel Tests
    # =========================================================================
    @testset "RegimeModel - Complete" begin
        arma = ARMAParams(0.0, [0.1], [0.1], 0.001)
        garch = GARCHParams(0.00001, 0.1, 0.85)

        regime = RegimeModel(
            ARMASpec(1, 1), arma, garch, 2.5, 5.0, 0.02
        )

        @test regime.arma_spec.p == 1
        @test regime.tail_index ≈ 2.5
        @test regime.dof_ν ≈ 5.0
        @test regime.vol_scale ≈ 0.02
    end

    @testset "RegimeModel - No GARCH (Floating)" begin
        arma = ARMAParams(0.0, Float64[], Float64[], 0.01)

        regime = RegimeModel(
            ARMASpec(0, 0), arma, nothing, 1.8, nothing, 0.05
        )

        @test regime.garch_params === nothing
        @test regime.dof_ν === nothing
        @test regime.tail_index ≈ 1.8
    end

    @testset "RegimeModel - Tail Index Bounds" begin
        arma = ARMAParams(0.0, [0.1], [0.1], 0.001)

        @test_throws AssertionError RegimeModel(
            ARMASpec(1, 1), arma, nothing, 1.2, nothing, 0.02
        )  # α < 1.5

        @test_throws AssertionError RegimeModel(
            ARMASpec(1, 1), arma, nothing, 4.5, nothing, 0.02
        )  # α > 4.0
    end

    @testset "RegimeModel - Edge Tail Index" begin
        arma = ARMAParams(0.0, [0.1], [0.1], 0.001)

        regime_low = RegimeModel(ARMASpec(1, 1), arma, nothing, 1.5, nothing, 0.02)
        @test regime_low.tail_index ≈ 1.5

        regime_high = RegimeModel(ARMASpec(1, 1), arma, nothing, 4.0, nothing, 0.02)
        @test regime_high.tail_index ≈ 4.0
    end

    # =========================================================================
    # ARMA Log-Likelihood Tests
    # =========================================================================
    @testset "arma_loglikelihood - Basic" begin
        returns = randn(50) .* 0.01
        spec = ARMASpec(1, 0)
        params = [0.0, 0.1, log(0.0001)]

        ll = arma_loglikelihood(returns, params, spec)
        @test ll > 0  # Negative log-likelihood is positive
        @test isfinite(ll)
    end

    @testset "arma_loglikelihood - MA Component" begin
        returns = randn(50) .* 0.01
        spec = ARMASpec(0, 1)
        params = [0.0, 0.1, log(0.0001)]

        ll = arma_loglikelihood(returns, params, spec)
        @test ll > 0
        @test isfinite(ll)
    end

    @testset "arma_loglikelihood - ARMA(1,1)" begin
        returns = randn(50) .* 0.01
        spec = ARMASpec(1, 1)
        params = [0.0, 0.1, 0.1, log(0.0001)]

        ll = arma_loglikelihood(returns, params, spec)
        @test ll > 0
        @test isfinite(ll)
    end

    @testset "arma_loglikelihood - Invalid Variance" begin
        returns = randn(50) .* 0.01
        spec = ARMASpec(1, 0)
        params = [0.0, 0.1, log(-0.0001)]  # Invalid: will exp to small positive

        ll = arma_loglikelihood(returns, params, spec)
        @test isfinite(ll)
    end

    # =========================================================================
    # GARCH Log-Likelihood Tests
    # =========================================================================
    @testset "garch_loglikelihood - Basic" begin
        returns = randn(100) .* 0.01
        arma = ARMAParams(0.0, [0.1], [0.1], 0.0001)
        garch = GARCHParams(0.00001, 0.1, 0.85)

        ll = garch_loglikelihood(returns, arma, garch)
        @test ll > 0
        @test isfinite(ll)
    end

    @testset "garch_loglikelihood - No GARCH" begin
        returns = randn(100) .* 0.01
        arma = ARMAParams(0.0, [0.1], Float64[], 0.0001)
        garch = GARCHParams(0.00001, 0.0, 0.0)

        ll = garch_loglikelihood(returns, arma, garch)
        @test ll > 0
    end

    # =========================================================================
    # estimate_armagarch Tests
    # =========================================================================
    @testset "estimate_armagarch - AR(1)" begin
        returns = randn(100) .* 0.01
        spec = ARMASpec(1, 0)

        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=false)

        @test arma isa ARMAParams
        @test garch === nothing
        @test ll < 0  # Actual log-likelihood (not negated)
        @test isfinite(ll)
    end

    @testset "estimate_armagarch - MA(1)" begin
        returns = randn(100) .* 0.01
        spec = ARMASpec(0, 1)

        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=false)

        @test arma isa ARMAParams
        @test length(arma.φ) == 0
        @test length(arma.θ) == 1
    end

    @testset "estimate_armagarch - ARMA(1,1) with GARCH" begin
        returns = randn(200) .* 0.01
        spec = ARMASpec(1, 1)

        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=true)

        @test arma isa ARMAParams
        @test garch isa GARCHParams
        @test garch.ω > 0
        @test garch.α₁ >= 0
        @test garch.β₁ >= 0
        @test garch.α₁ + garch.β₁ < 1.0
        @test ll < 0
    end

    @testset "estimate_armagarch - ARMA(2,2)" begin
        returns = randn(200) .* 0.01
        spec = ARMASpec(2, 2)

        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=false)

        @test length(arma.φ) == 2
        @test length(arma.θ) == 2
    end

    @testset "estimate_armagarch - Insufficient Data" begin
        returns = randn(5) .* 0.01
        spec = ARMASpec(1, 1)

        @test_throws AssertionError estimate_armagarch(returns, spec)
    end

    @testset "estimate_armagarch - Warm Start" begin
        returns = randn(100) .* 0.01
        spec = ARMASpec(1, 0)

        initial = ARMAParams(0.0, [0.05], Float64[], 0.0001)
        arma, garch, ll = estimate_armagarch(returns, spec; 
                                             use_garch=false, 
                                             initial_params=initial)

        @test arma isa ARMAParams
    end

    # =========================================================================
    # Rolling Realized Volatility Tests
    # =========================================================================
    @testset "rolling_realized_vol - Basic" begin
        returns = randn(100) .* 0.01
        rv = rolling_realized_vol(returns, 10)

        @test length(rv) == length(returns)
        @test all(isnan.(rv[1:9]))
        @test all(.!isnan.(rv[10:end]))
    end

    @testset "rolling_realized_vol - Window Size" begin
        returns = randn(50) .* 0.01
        rv = rolling_realized_vol(returns, 20)

        @test all(isnan.(rv[1:19]))
        @test all(.!isnan.(rv[20:end]))
    end

    @testset "rolling_realized_vol - With NaN" begin
        returns = randn(50) .* 0.01
        returns[15:25] .= NaN

        rv = rolling_realized_vol(returns, 10)

        @test length(rv) == 50
        # Some values should still be computed with partial data
        @test any(.!isnan.(rv[25:end]))
    end

    @testset "rolling_realized_vol - Annualization" begin
        returns = fill(0.01, 30)  # 1% daily return
        rv = rolling_realized_vol(returns, 10)

        valid_rv = rv[.!isnan.(rv)]
        @test all(valid_rv .> 0)  # Annualized vol should be positive
        @test all(valid_rv .< 1.0)  # Should be reasonable magnitude
    end

    @testset "rolling_realized_vol - Zero Returns" begin
        returns = fill(0.0, 30)
        rv = rolling_realized_vol(returns, 10)

        @test all(isnan.(rv))  # Zero variance → NaN
    end

    # =========================================================================
    # Tail Index Tests
    # =========================================================================
    @testset "tail_index_from_vol_scale - Normal" begin
        α = tail_index_from_vol_scale(0.02, 0.02)
        @test 1.5 <= α <= 4.0
        @test α ≈ 4.0 atol=0.01  # Equal vol → max tail index
    end

    @testset "tail_index_from_vol_scale - High Volatility" begin
        α = tail_index_from_vol_scale(0.06, 0.02)
        @test 1.5 <= α <= 4.0
        @test α < 4.0  # Higher vol → lower tail index
    end

    @testset "tail_index_from_vol_scale - Extreme Volatility" begin
        α = tail_index_from_vol_scale(0.10, 0.02)
        @test α ≈ 1.5 atol=0.01  # Very high vol → min tail index
    end

    @testset "tail_index_from_vol_scale - Zero Baseline" begin
        α = tail_index_from_vol_scale(0.02, 0.0)
        @test α ≈ 2.0  # Default when baseline is zero
    end

    @testset "tail_index_from_vol_scale - Monotonicity" begin
        α1 = tail_index_from_vol_scale(0.02, 0.02)
        α2 = tail_index_from_vol_scale(0.04, 0.02)
        α3 = tail_index_from_vol_scale(0.06, 0.02)

        @test α1 > α2 > α3  # Increasing vol → decreasing tail index
    end

    @testset "dof_from_tail_index - Finite Variance" begin
        ν = dof_from_tail_index(2.5)
        @test ν > 2.0
        @test isfinite(ν)
    end

    @testset "dof_from_tail_index - Infinite Variance" begin
        ν = dof_from_tail_index(1.8)
        @test ν == Inf

        ν2 = dof_from_tail_index(2.0)
        @test ν2 == Inf
    end

    @testset "dof_from_tail_index - High Tail Index" begin
        ν = dof_from_tail_index(4.0)
        @test ν ≈ 8.0 / 3.0 atol=0.01
    end

    @testset "dof_from_tail_index - Formula Check" begin
        # ν = 2α/(α-1)
        for α in [2.5, 3.0, 3.5]
            ν = dof_from_tail_index(α)
            expected = 2.0 * α / (α - 1.0)
            @test ν ≈ expected atol=1e-10
        end
    end

    # =========================================================================
    # Internal Helper Tests
    # =========================================================================
    @testset "_compute_innovations" begin
        returns = randn(50) .* 0.01
        spec = ARMASpec(1, 1)
        params = ARMAParams(0.0, [0.1], [0.1], 0.0001)

        ε = ARMAGARCH._compute_innovations(returns, params, spec)

        @test length(ε) == length(returns)
        @test all(isfinite.(ε))
    end

    @testset "_sigmoid and _logit" begin
        @test ARMAGARCH._sigmoid(0.0) ≈ 0.5
        @test ARMAGARCH._sigmoid(10.0) ≈ 1.0 atol=0.001
        @test ARMAGARCH._sigmoid(-10.0) ≈ 0.0 atol=0.001

        @test ARMAGARCH._logit(0.5) ≈ 0.0 atol=1e-10
        @test ARMAGARCH._logit(0.9) > 0
        @test ARMAGARCH._logit(0.1) < 0

        # Round-trip
        for x in [-2.0, -1.0, 0.0, 1.0, 2.0]
            @test ARMAGARCH._logit(ARMAGARCH._sigmoid(x)) ≈ x atol=1e-10
        end
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full ARMA-GARCH Pipeline" begin
        # Generate ARMA(1,1)-GARCH(1,1) data
        n = 200
        ε = randn(n) .* 0.01
        returns = zeros(n)
        σ² = fill(0.0001, n)

        for t in 2:n
            σ²[t] = 0.00001 + 0.1 * ε[t-1]^2 + 0.85 * σ²[t-1]
            returns[t] = 0.001 + 0.3 * returns[t-1] + 0.2 * ε[t-1] + ε[t]
        end

        spec = ARMASpec(1, 1)
        arma, garch, ll = estimate_armagarch(returns, spec; use_garch=true)

        @test arma isa ARMAParams
        @test garch isa GARCHParams
        @test arma.μ > 0  # Should recover positive drift
        @test ll < 0
    end

    @testset "Regime Model Construction" begin
        # Build complete regime model
        spec = ARMASpec(1, 1)
        arma = ARMAParams(0.001, [0.3], [0.2], 0.0004)
        garch = GARCHParams(0.00001, 0.1, 0.85)

        σ_regime = sqrt(garch.ω / (1 - garch.α₁ - garch.β₁))
        σ_baseline = 0.015
        α = tail_index_from_vol_scale(σ_regime, σ_baseline)
        ν = α > 2.0 ? dof_from_tail_index(α) : nothing

        regime = RegimeModel(spec, arma, garch, α, ν, σ_regime)

        @test regime.tail_index == α
        @test regime.vol_scale ≈ σ_regime
        if α > 2.0
            @test regime.dof_ν ≈ ν
        else
            @test regime.dof_ν === nothing
        end
    end

end  # @testset ARMAGARCH Module

end  # module TestARMAGARCH
