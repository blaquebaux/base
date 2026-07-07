module TestCascadeInterface

using Test

include("../src/module_6_cascade/module_6_cascade.jl")
using .CascadeInterface

@testset "CascadeInterface Module - Comprehensive" begin

    # =========================================================================
    # RegimeProbs Tests
    # =========================================================================
    @testset "RegimeProbs - Valid" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        @test probs.p_fixed ≈ 0.3
        @test probs.p_growth ≈ 0.5
        @test probs.p_floating ≈ 0.2
    end

    @testset "RegimeProbs - Equal" begin
        probs = RegimeProbs(0.33, 0.33, 0.34)
        @test sum([probs.p_fixed, probs.p_growth, probs.p_floating]) ≈ 1.0
    end

    @testset "RegimeProbs - Extreme" begin
        probs = RegimeProbs(0.0, 1.0, 0.0)
        @test probs.p_growth ≈ 1.0
    end

    @testset "RegimeProbs - From Vector" begin
        probs = RegimeProbs([0.2, 0.5, 0.3])
        @test probs.p_fixed ≈ 0.2
        @test probs.p_growth ≈ 0.5
        @test probs.p_floating ≈ 0.3
    end

    @testset "RegimeProbs - Invalid" begin
        @test_throws AssertionError RegimeProbs(0.5, 0.5, 0.5)    # Sum > 1
        @test_throws AssertionError RegimeProbs(0.5, 0.5, 0.0)    # Sum < 1
        @test_throws AssertionError RegimeProbs(-0.1, 0.6, 0.5)   # Negative
        @test_throws AssertionError RegimeProbs([0.5, 0.5])       # Wrong length
    end

    # =========================================================================
    # CASCADE_PARAMS Tests
    # =========================================================================
    @testset "CASCADE_PARAMS - Keys" begin
        @test haskey(CASCADE_PARAMS, "fixed")
        @test haskey(CASCADE_PARAMS, "growth")
        @test haskey(CASCADE_PARAMS, "floating")
    end

    @testset "CASCADE_PARAMS - Fixed Regime" begin
        fixed = CASCADE_PARAMS["fixed"]
        @test fixed.trend_weight ≈ 0.20
        @test fixed.meanrev_weight ≈ 0.60
        @test fixed.momentum_weight ≈ 0.20
        @test fixed.defensive_weight ≈ 0.00
        @test fixed.stop_width ≈ 1.5
        @test fixed.max_hold_days == 20

        # Weights sum to 1
        total = fixed.trend_weight + fixed.meanrev_weight + 
                fixed.momentum_weight + fixed.defensive_weight
        @test total ≈ 1.0
    end

    @testset "CASCADE_PARAMS - Growth Regime" begin
        growth = CASCADE_PARAMS["growth"]
        @test growth.trend_weight ≈ 0.70
        @test growth.meanrev_weight ≈ 0.10
        @test growth.momentum_weight ≈ 0.20
        @test growth.defensive_weight ≈ 0.00
        @test growth.stop_width ≈ 3.0
        @test growth.max_hold_days == 60

        total = growth.trend_weight + growth.meanrev_weight + 
                growth.momentum_weight + growth.defensive_weight
        @test total ≈ 1.0
    end

    @testset "CASCADE_PARAMS - Floating Regime" begin
        floating = CASCADE_PARAMS["floating"]
        @test floating.trend_weight ≈ 0.10
        @test floating.meanrev_weight ≈ 0.10
        @test floating.momentum_weight ≈ 0.10
        @test floating.defensive_weight ≈ 0.70
        @test floating.stop_width ≈ 0.5
        @test floating.max_hold_days == 3

        total = floating.trend_weight + floating.meanrev_weight + 
                floating.momentum_weight + floating.defensive_weight
        @test total ≈ 1.0
    end

    @testset "CASCADE_PARAMS - Regime Characteristics" begin
        fixed = CASCADE_PARAMS["fixed"]
        growth = CASCADE_PARAMS["growth"]
        floating = CASCADE_PARAMS["floating"]

        # Growth has highest trend weight
        @test growth.trend_weight > fixed.trend_weight
        @test growth.trend_weight > floating.trend_weight

        # Fixed has highest mean reversion
        @test fixed.meanrev_weight > growth.meanrev_weight
        @test fixed.meanrev_weight > floating.meanrev_weight

        # Floating has highest defensive
        @test floating.defensive_weight > fixed.defensive_weight
        @test floating.defensive_weight > growth.defensive_weight

        # Growth has widest stops
        @test growth.stop_width > fixed.stop_width
        @test growth.stop_width > floating.stop_width

        # Floating has tightest stops
        @test floating.stop_width < fixed.stop_width
        @test floating.stop_width < growth.stop_width
    end

    # =========================================================================
    # blend_cascade_params Tests
    # =========================================================================
    @testset "blend_cascade_params - Equal Weights" begin
        probs = RegimeProbs(0.33, 0.33, 0.34)
        blended = blend_cascade_params(probs)

        @test blended isa BlendedCascadeParams
        @test blended.trend_weight >= 0
        @test blended.defensive_weight >= 0
        @test blended.stop_width_atr > 0
        @test blended.max_holding_days > 0
    end

    @testset "blend_cascade_params - Pure Fixed" begin
        probs = RegimeProbs(1.0, 0.0, 0.0)
        blended = blend_cascade_params(probs)

        fixed = CASCADE_PARAMS["fixed"]
        @test blended.trend_weight ≈ fixed.trend_weight
        @test blended.meanrev_weight ≈ fixed.meanrev_weight
        @test blended.stop_width_atr ≈ fixed.stop_width
        @test blended.max_holding_days == fixed.max_hold_days
    end

    @testset "blend_cascade_params - Pure Growth" begin
        probs = RegimeProbs(0.0, 1.0, 0.0)
        blended = blend_cascade_params(probs)

        growth = CASCADE_PARAMS["growth"]
        @test blended.trend_weight ≈ growth.trend_weight
        @test blended.stop_width_atr ≈ growth.stop_width
        @test blended.max_holding_days == growth.max_hold_days
    end

    @testset "blend_cascade_params - Pure Floating" begin
        probs = RegimeProbs(0.0, 0.0, 1.0)
        blended = blend_cascade_params(probs)

        floating = CASCADE_PARAMS["floating"]
        @test blended.defensive_weight ≈ floating.defensive_weight
        @test blended.stop_width_atr ≈ floating.stop_width
        @test blended.max_holding_days == floating.max_hold_days
    end

    @testset "blend_cascade_params - Weighted Average" begin
        probs = RegimeProbs(0.5, 0.3, 0.2)
        blended = blend_cascade_params(probs)

        fixed = CASCADE_PARAMS["fixed"]
        growth = CASCADE_PARAMS["growth"]
        floating = CASCADE_PARAMS["floating"]

        expected_trend = 0.5 * fixed.trend_weight + 0.3 * growth.trend_weight + 
                        0.2 * floating.trend_weight
        @test blended.trend_weight ≈ expected_trend
    end

    # =========================================================================
    # compute_position_sizing Tests
    # =========================================================================
    @testset "compute_position_sizing - Default Capital" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        sizing = compute_position_sizing(probs)

        @test sizing isa PositionSizing
        @test sizing.total_capital ≈ 10000.0
        @test sizing.active_pct + sizing.defensive_pct ≈ 1.0
        @test sizing.exposure >= 0
        @test sizing.defensive_cash >= 0
    end

    @testset "compute_position_sizing - Custom Capital" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        sizing = compute_position_sizing(probs, 50000.0)

        @test sizing.total_capital ≈ 50000.0
    end

    @testset "compute_position_sizing - Pure Fixed" begin
        probs = RegimeProbs(1.0, 0.0, 0.0)
        sizing = compute_position_sizing(probs, 10000.0)

        @test sizing.active_pct ≈ 0.70
        @test sizing.defensive_pct ≈ 0.30
    end

    @testset "compute_position_sizing - Pure Growth" begin
        probs = RegimeProbs(0.0, 1.0, 0.0)
        sizing = compute_position_sizing(probs, 10000.0)

        @test sizing.active_pct ≈ 0.90
        @test sizing.defensive_pct ≈ 0.10
    end

    @testset "compute_position_sizing - Pure Floating" begin
        probs = RegimeProbs(0.0, 0.0, 1.0)
        sizing = compute_position_sizing(probs, 10000.0)

        @test sizing.active_pct ≈ 0.20
        @test sizing.defensive_pct ≈ 0.80
    end

    @testset "compute_position_sizing - Exposure Check" begin
        probs = RegimeProbs(0.5, 0.3, 0.2)
        sizing = compute_position_sizing(probs, 10000.0)

        # Exposure + defensive cash should approximately equal total
        @test sizing.exposure + sizing.defensive_cash ≈ sizing.total_capital * 
              (sizing.active_pct * sizing.multiplier + sizing.defensive_pct) atol=1.0
    end

    @testset "compute_position_sizing - Multiplier Range" begin
        probs_high = RegimeProbs(0.0, 1.0, 0.0)
        sizing_high = compute_position_sizing(probs_high, 10000.0)

        probs_low = RegimeProbs(0.33, 0.33, 0.34)
        sizing_low = compute_position_sizing(probs_low, 10000.0)

        # Higher conviction → higher multiplier
        @test sizing_high.multiplier >= sizing_low.multiplier
    end

    # =========================================================================
    # apply_global_risk_off Tests
    # =========================================================================
    @testset "apply_global_risk_off - No Risk Off" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        adjusted = apply_global_risk_off(probs, 0.0)

        @test adjusted.p_fixed ≈ probs.p_fixed atol=1e-10
        @test adjusted.p_growth ≈ probs.p_growth atol=1e-10
        @test adjusted.p_floating ≈ probs.p_floating atol=1e-10
    end

    @testset "apply_global_risk_off - Full Risk Off" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        adjusted = apply_global_risk_off(probs, 1.0)

        @test adjusted.p_floating > probs.p_floating
        @test adjusted.p_floating ≈ 1.0 atol=0.01
    end

    @testset "apply_global_risk_off - Partial" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        adjusted = apply_global_risk_off(probs, 0.5)

        @test adjusted.p_floating > probs.p_floating
        @test adjusted.p_floating < 1.0
        @test adjusted.p_fixed + adjusted.p_growth + adjusted.p_floating ≈ 1.0
    end

    @testset "apply_global_risk_off - Clamping" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)

        # Should clamp to [0, 1]
        adjusted_low = apply_global_risk_off(probs, -0.5)
        @test adjusted_low.p_fixed ≈ probs.p_fixed atol=1e-10

        adjusted_high = apply_global_risk_off(probs, 1.5)
        @test adjusted_high.p_floating ≈ 1.0 atol=0.01
    end

    @testset "apply_global_risk_off - Floating Already Dominant" begin
        probs = RegimeProbs(0.1, 0.1, 0.8)
        adjusted = apply_global_risk_off(probs, 0.5)

        @test adjusted.p_floating >= probs.p_floating
    end

    # =========================================================================
    # GammaARMAOutput Tests
    # =========================================================================
    @testset "create_gamma_arma_output - Valid" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        output = create_gamma_arma_output(probs, 0.25, 2.5, 0.1)

        @test output isa GammaARMAOutput
        @test output.cond_vol ≈ 0.25
        @test output.tail_alpha ≈ 2.5
        @test output.jump_intensity ≈ 0.1
    end

    @testset "create_gamma_arma_output - Default Jump" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        output = create_gamma_arma_output(probs, 0.25, 2.5)

        @test output.jump_intensity ≈ 0.0
    end

    @testset "create_gamma_arma_output - Invalid Volatility" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        @test_throws AssertionError create_gamma_arma_output(probs, -0.1, 2.5, 0.1)
    end

    @testset "create_gamma_arma_output - Invalid Tail Index" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        @test_throws AssertionError create_gamma_arma_output(probs, 0.25, 1.2, 0.1)
        @test_throws AssertionError create_gamma_arma_output(probs, 0.25, 4.5, 0.1)
    end

    @testset "create_gamma_arma_output - Invalid Jump" begin
        probs = RegimeProbs(0.3, 0.5, 0.2)
        @test_throws AssertionError create_gamma_arma_output(probs, 0.25, 2.5, -0.1)
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full Cascade Pipeline" begin
        # Simulate regime probabilities
        probs = RegimeProbs(0.2, 0.6, 0.2)

        # Blend parameters
        blended = blend_cascade_params(probs)

        # Compute sizing
        sizing = compute_position_sizing(probs, 10000.0)

        # Apply global risk-off
        adjusted_probs = apply_global_risk_off(probs, 0.3)

        # Create output
        output = create_gamma_arma_output(adjusted_probs, 0.25, 2.5, 0.1)

        @test blended isa BlendedCascadeParams
        @test sizing isa PositionSizing
        @test output isa GammaARMAOutput
        @test output.regime_probs.p_floating >= probs.p_floating
    end

    @testset "Crisis Scenario" begin
        # High floating probability (crisis)
        probs = RegimeProbs(0.1, 0.1, 0.8)
        blended = blend_cascade_params(probs)
        sizing = compute_position_sizing(probs, 10000.0)

        @test blended.defensive_weight > 0.5
        @test sizing.defensive_pct > 0.5
        @test sizing.active_pct < 0.5
    end

    @testset "Growth Scenario" begin
        # High growth probability
        probs = RegimeProbs(0.1, 0.8, 0.1)
        blended = blend_cascade_params(probs)
        sizing = compute_position_sizing(probs, 10000.0)

        @test blended.trend_weight > 0.5
        @test sizing.active_pct > 0.7
    end

end  # @testset CascadeInterface Module

end  # module TestCascadeInterface
