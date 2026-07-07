module TestDPM

using Test

include("../src/module_5_dpm/module_5_dpm.jl")
using .DPM

@testset "DPM Module - Comprehensive" begin

    # =========================================================================
    # DPMConfig Tests
    # =========================================================================
    @testset "DPMConfig - Default" begin
        config = DPMConfig()
        @test config.max_components == 30
        @test config.concentration_prior_shape == 2.0
        @test config.concentration_prior_rate == 0.5
        @test config.convergence_threshold == 1e-4
        @test config.max_iterations == 500
    end

    @testset "DPMConfig - Custom" begin
        config = DPMConfig(20, 1.5, 0.3, 1e-3, 100)
        @test config.max_components == 20
        @test config.concentration_prior_shape == 1.5
        @test config.concentration_prior_rate == 0.3
        @test config.convergence_threshold == 1e-3
        @test config.max_iterations == 100
    end

    @testset "DPMConfig - Validation" begin
        @test_throws AssertionError DPMConfig(3, 2.0, 0.5)    # max_components < 5
        @test_throws AssertionError DPMConfig(20, -1.0, 0.5)  # shape < 0
        @test_throws AssertionError DPMConfig(20, 2.0, -0.5)   # rate < 0
    end

    # =========================================================================
    # StickBreaking Tests
    # =========================================================================
    @testset "StickBreaking - Basic" begin
        weights = [0.4, 0.35, 0.25]
        atoms = [Dict(:μ => 0.0), Dict(:μ => 0.01), Dict(:μ => -0.01)]
        sb = StickBreaking(weights, atoms)

        @test length(sb.weights) == 3
        @test length(sb.atoms) == 3
        @test sum(sb.weights) ≈ 1.0 atol=1e-10
    end

    @testset "StickBreaking - Equal Weights" begin
        weights = fill(0.2, 5)
        atoms = fill(Dict(:μ => 0.0), 5)
        sb = StickBreaking(weights, atoms)

        @test all(sb.weights .≈ 0.2)
    end

    @testset "StickBreaking - Single Component" begin
        weights = [1.0]
        atoms = [Dict(:μ => 0.0)]
        sb = StickBreaking(weights, atoms)

        @test sb.weights[1] ≈ 1.0
    end

    # =========================================================================
    # ParticleFilterConfig Tests
    # =========================================================================
    @testset "ParticleFilterConfig - Default" begin
        config = ParticleFilterConfig()
        @test config.n_particles == 2000
        @test config.resampling_threshold == 0.5
    end

    @testset "ParticleFilterConfig - Custom" begin
        config = ParticleFilterConfig(1000, 0.3)
        @test config.n_particles == 1000
        @test config.resampling_threshold == 0.3
    end

    @testset "ParticleFilterConfig - Validation" begin
        @test_throws AssertionError ParticleFilterConfig(50, 0.5)   # n < 100
        @test_throws AssertionError ParticleFilterConfig(1000, 0.0)  # threshold = 0
        @test_throws AssertionError ParticleFilterConfig(1000, 1.5)  # threshold > 1
    end

    # =========================================================================
    # particle_filter_estep Tests
    # =========================================================================
    @testset "particle_filter_estep - Basic" begin
        returns = randn(50) .* 0.01
        weights = [0.4, 0.35, 0.25]
        atoms = [Dict(:μ => 0.0, :σ² => 0.0001), 
                 Dict(:μ => 0.001, :σ² => 0.0004),
                 Dict(:μ => -0.001, :σ² => 0.0009)]
        sb = StickBreaking(weights, atoms)

        pf_config = ParticleFilterConfig(200, 0.5)
        regime_probs, smoothed_weights = particle_filter_estep(returns, sb, pf_config)

        @test size(regime_probs) == (50, 3)
        @test all(regime_probs .>= 0)
        @test all(sum(regime_probs, dims=2) .≈ 1.0)
        @test length(smoothed_weights) == 3
        @test sum(smoothed_weights) ≈ 1.0 atol=1e-6
    end

    @testset "particle_filter_estep - Single Component" begin
        returns = randn(30) .* 0.01
        weights = [1.0]
        atoms = [Dict(:μ => 0.0, :σ² => 0.0001)]
        sb = StickBreaking(weights, atoms)

        pf_config = ParticleFilterConfig(100, 0.5)
        regime_probs, smoothed_weights = particle_filter_estep(returns, sb, pf_config)

        @test size(regime_probs) == (30, 1)
        @test all(regime_probs .≈ 1.0)
    end

    @testset "particle_filter_estep - Many Components" begin
        returns = randn(50) .* 0.01
        K = 10
        weights = fill(1.0/K, K)
        atoms = [Dict(:μ => randn()*0.001, :σ² => 0.0001 + rand()*0.001) for _ in 1:K]
        sb = StickBreaking(weights, atoms)

        pf_config = ParticleFilterConfig(200, 0.5)
        regime_probs, smoothed_weights = particle_filter_estep(returns, sb, pf_config)

        @test size(regime_probs) == (50, K)
        @test all(sum(regime_probs, dims=2) .≈ 1.0)
    end

    # =========================================================================
    # mstep_update Tests
    # =========================================================================
    @testset "mstep_update - Basic" begin
        returns = randn(50) .* 0.01
        regime_probs = rand(50, 3)
        regime_probs ./= sum(regime_probs, dims=2)

        atoms = [Dict(:μ => 0.0, :σ² => 0.0001), 
                 Dict(:μ => 0.001, :σ² => 0.0004),
                 Dict(:μ => -0.001, :σ² => 0.0009)]

        updated = mstep_update(returns, regime_probs, atoms)

        @test length(updated) == 3
        @test all(haskey.(updated, :μ))
        @test all(haskey.(updated, :σ²))
    end

    @testset "mstep_update - Negligible Weight" begin
        returns = randn(50) .* 0.01
        regime_probs = fill(1e-7, 50, 3)  # Very small weights
        regime_probs[:, 1] .= 1.0 - 2e-7

        atoms = [Dict(:μ => 0.0, :σ² => 0.0001), 
                 Dict(:μ => 0.001, :σ² => 0.0004),
                 Dict(:μ => -0.001, :σ² => 0.0009)]

        updated = mstep_update(returns, regime_probs, atoms)

        # Components with negligible weight should keep old params
        @test updated[2] == atoms[2]
        @test updated[3] == atoms[3]
    end

    # =========================================================================
    # update_concentration_parameter Tests
    # =========================================================================
    @testset "update_concentration_parameter - Basic" begin
        γ_new = update_concentration_parameter(1.0, 5, 100, 2.0, 0.5)

        @test γ_new > 0
        @test isfinite(γ_new)
    end

    @testset "update_concentration_parameter - Monotonicity" begin
        γ1 = update_concentration_parameter(1.0, 5, 100, 2.0, 0.5)
        γ2 = update_concentration_parameter(1.0, 10, 100, 2.0, 0.5)

        @test γ2 > γ1  # More active components → higher γ
    end

    @testset "update_concentration_parameter - Floor" begin
        γ = update_concentration_parameter(0.001, 1, 10, 2.0, 0.5)
        @test γ >= 0.01  # Floor at 0.01
    end

    # =========================================================================
    # em_estimation Tests
    # =========================================================================
    @testset "em_estimation - Basic" begin
        returns = randn(100) .* 0.01
        dpm_config = DPMConfig(10, 2.0, 0.5, 1e-3, 50)
        pf_config = ParticleFilterConfig(200, 0.5)

        model, ll_history, converged = em_estimation(returns, dpm_config, pf_config, nothing)

        @test model isa StickBreaking
        @test length(model.weights) == 10
        @test all(model.weights .>= 0)
        @test length(ll_history) > 0
        @test converged isa Bool
    end

    @testset "em_estimation - Convergence" begin
        returns = randn(100) .* 0.01
        dpm_config = DPMConfig(5, 2.0, 0.5, 1e-2, 100)
        pf_config = ParticleFilterConfig(100, 0.5)

        model, ll_history, converged = em_estimation(returns, dpm_config, pf_config, nothing)

        if converged
            @test length(ll_history) < 100
        end
    end

    @testset "em_estimation - Warm Start" begin
        returns = randn(100) .* 0.01
        dpm_config = DPMConfig(5, 2.0, 0.5, 1e-2, 50)
        pf_config = ParticleFilterConfig(100, 0.5)

        # First run
        model1, _, _ = em_estimation(returns, dpm_config, pf_config, nothing)

        # Second run with warm start
        model2, ll_history2, converged2 = em_estimation(returns, dpm_config, pf_config, model1)

        @test model2 isa StickBreaking
    end

    # =========================================================================
    # recursive_update Tests
    # =========================================================================
    @testset "recursive_update - Basic" begin
        prev = StickBreaking([0.33, 0.33, 0.34], [nothing, nothing, nothing])
        updated = recursive_update(prev, 0.01, 0.99)

        @test length(updated.weights) == 3
        @test sum(updated.weights) ≈ 1.0 atol=1e-6
        @test all(updated.weights .>= 0)
    end

    @testset "recursive_update - Forgetting Factor" begin
        prev = StickBreaking([0.5, 0.3, 0.2], [nothing, nothing, nothing])

        updated_99 = recursive_update(prev, 0.01, 0.99)
        updated_95 = recursive_update(prev, 0.01, 0.95)

        # More forgetting → more weight change
        @test maximum(abs.(updated_95.weights - prev.weights)) > 
              maximum(abs.(updated_99.weights - prev.weights))
    end

    @testset "recursive_update - Large Return" begin
        prev = StickBreaking([0.33, 0.33, 0.34], [nothing, nothing, nothing])
        updated = recursive_update(prev, 0.5, 0.99)  # Large return

        @test sum(updated.weights) ≈ 1.0 atol=1e-6
    end

    # =========================================================================
    # detect_crisis_regime Tests
    # =========================================================================
    @testset "detect_crisis_regime - All True" begin
        @test detect_crisis_regime(nothing, true, true, true, true) == true
    end

    @testset "detect_crisis_regime - Three True" begin
        @test detect_crisis_regime(nothing, true, true, true, false) == true
        @test detect_crisis_regime(nothing, true, true, false, true) == true
        @test detect_crisis_regime(nothing, true, false, true, true) == true
        @test detect_crisis_regime(nothing, false, true, true, true) == true
    end

    @testset "detect_crisis_regime - Two True" begin
        @test detect_crisis_regime(nothing, true, true, false, false) == false
        @test detect_crisis_regime(nothing, true, false, true, false) == false
        @test detect_crisis_regime(nothing, true, false, false, true) == false
        @test detect_crisis_regime(nothing, false, true, true, false) == false
        @test detect_crisis_regime(nothing, false, true, false, true) == false
        @test detect_crisis_regime(nothing, false, false, true, true) == false
    end

    @testset "detect_crisis_regime - One True" begin
        @test detect_crisis_regime(nothing, true, false, false, false) == false
        @test detect_crisis_regime(nothing, false, true, false, false) == false
        @test detect_crisis_regime(nothing, false, false, true, false) == false
        @test detect_crisis_regime(nothing, false, false, false, true) == false
    end

    @testset "detect_crisis_regime - All False" begin
        @test detect_crisis_regime(nothing, false, false, false, false) == false
    end

    # =========================================================================
    # Internal Helper Tests
    # =========================================================================
    @testset "_categorical_sample" begin
        probs = [0.5, 0.3, 0.2]

        # Run many times to verify distribution
        counts = zeros(Int, 3)
        for _ in 1:1000
            idx = DPM._categorical_sample(probs)
            counts[idx] += 1
        end

        @test counts[1] > counts[2] > counts[3]  # Should follow probabilities
        @test all(counts .> 0)
    end

    @testset "_stick_breaking_weights" begin
        v = [0.5, 0.5, 0.5]
        weights = DPM._stick_breaking_weights(v)

        @test length(weights) == 3
        @test sum(weights) ≈ 1.0 atol=1e-10
        @test weights[1] ≈ 0.5
        @test weights[2] ≈ 0.25 atol=1e-10
        @test weights[3] ≈ 0.125 atol=1e-10
    end

    @testset "_collapse_components" begin
        weights = [0.5, 0.3, 0.15, 0.05]
        atoms = fill(nothing, 4)
        γ = 1.0

        collapsed = DPM._collapse_components(weights, atoms, γ)

        @test length(collapsed) == 4
        @test collapsed[4] == 0.0  # Small component collapsed
        @test sum(collapsed) ≈ 1.0 atol=1e-10
    end

    @testset "_regime_likelihood" begin
        atom = Dict(:μ => 0.0, :σ² => 0.0001)
        lik = DPM._regime_likelihood(0.0, atom)

        @test lik > 0
        @test isfinite(lik)

        # Likelihood should decrease for extreme values
        lik_far = DPM._regime_likelihood(0.1, atom)
        @test lik_far < lik
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full EM Pipeline" begin
        # Generate mixture data
        n = 200
        returns = vcat(
            randn(100) .* 0.008 .+ 0.001,   # Low vol regime
            randn(50) .* 0.02 .+ 0.0005,    # High vol regime
            randn(50) .* 0.005 .- 0.001     # Negative drift regime
        )

        dpm_config = DPMConfig(5, 2.0, 0.5, 1e-3, 100)
        pf_config = ParticleFilterConfig(300, 0.5)

        model, ll_history, converged = em_estimation(returns, dpm_config, pf_config, nothing)

        @test model isa StickBreaking
        @test length(ll_history) > 0

        # Check log-likelihood improvement
        if length(ll_history) > 1
            @test ll_history[end] > ll_history[1]  # Should improve
        end
    end

    @testset "Recursive Update Sequence" begin
        # Simulate 30 days of recursive updates
        params = StickBreaking([0.33, 0.33, 0.34], [nothing, nothing, nothing])

        for t in 1:30
            ret = randn() * 0.01
            params = recursive_update(params, ret, 0.99)

            @test sum(params.weights) ≈ 1.0 atol=1e-6
            @test all(params.weights .>= 0)
        end
    end

end  # @testset DPM Module

end  # module TestDPM
