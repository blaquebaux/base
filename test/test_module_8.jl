module TestGovernance

using Test, Dates, TimeZones

include("../src/module_8_governance/module_8_governance.jl")
using .Governance

@testset "Governance Module - Comprehensive" begin

    # =========================================================================
    # ModelVersion Tests
    # =========================================================================
    @testset "ModelVersion - Structure" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        version = ModelVersion(
            "v_2024_06_15",
            dt,
            nothing,
            0.05,
            true
        )

        @test version.version_id == "v_2024_06_15"
        @test version.timestamp == dt
        @test version.mae_forecast ≈ 0.05
        @test version.is_active == true
    end

    @testset "ModelVersion - Inactive" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        version = ModelVersion(
            "v_2024_06_14",
            dt,
            nothing,
            0.06,
            false
        )

        @test version.is_active == false
    end

    # =========================================================================
    # check_rollback Tests
    # =========================================================================
    @testset "check_rollback - No Degradation" begin
        should_roll, reason = check_rollback(0.05, 0.05, 1.2)

        @test should_roll == false
        @test occursin("within acceptable", reason)
    end

    @testset "check_rollback - Slight Degradation" begin
        should_roll, reason = check_rollback(0.058, 0.05, 1.2)

        @test should_roll == false
        @test occursin("ratio:", reason)
    end

    @testset "check_rollback - Threshold Degradation (exactly 1.2x)" begin
        should_roll, reason = check_rollback(0.06, 0.05, 1.2)

        @test should_roll == true
        @test occursin("degraded", reason)
    end

    @testset "check_rollback - Severe Degradation" begin
        should_roll, reason = check_rollback(0.08, 0.05, 1.2)

        @test should_roll == true
        @test occursin("60.0%", reason)
    end

    @testset "check_rollback - No Previous MAE" begin
        should_roll, reason = check_rollback(0.05, 0.0, 1.2)

        @test should_roll == false
        @test occursin("No previous MAE", reason)
    end

    @testset "check_rollback - Negative Previous MAE" begin
        should_roll, reason = check_rollback(0.05, -0.01, 1.2)

        @test should_roll == false
    end

    @testset "check_rollback - Custom Threshold" begin
        # With threshold 1.5, 0.07/0.05 = 1.4 should not trigger
        should_roll1, _ = check_rollback(0.07, 0.05, 1.5)
        @test should_roll1 == false

        # But 0.08/0.05 = 1.6 should trigger
        should_roll2, _ = check_rollback(0.08, 0.05, 1.5)
        @test should_roll2 == true
    end

    @testset "check_rollback - Improvement" begin
        should_roll, reason = check_rollback(0.04, 0.05, 1.2)

        @test should_roll == false
        @test occursin("within acceptable", reason)
    end

    # =========================================================================
    # ValidationGate Tests
    # =========================================================================
    @testset "ValidationGate - Structure" begin
        gate = ValidationGate(
            "T1",
            Date(2024, 1, 1),
            Date(2024, 1, 31),
            (returns, config) -> length(returns) > 10
        )

        @test gate.name == "T1"
        @test gate.start_date == Date(2024, 1, 1)
        @test gate.end_date == Date(2024, 1, 31)
    end

    @testset "ValidationGate - Success Criterion" begin
        gate = ValidationGate(
            "T1",
            Date(2024, 1, 1),
            Date(2024, 1, 31),
            (returns, config) -> length(returns) > 10
        )

        @test gate.success_criterion(randn(20), nothing) == true
        @test gate.success_criterion(randn(5), nothing) == false
    end

    @testset "ValidationGate - Complex Criterion" begin
        gate = ValidationGate(
            "T2",
            Date(2024, 1, 1),
            Date(2024, 3, 31),
            (returns, config) -> std(returns) < 0.05 && mean(returns) > -0.01
        )

        low_vol = randn(50) .* 0.01
        @test gate.success_criterion(low_vol, nothing) == true

        high_vol = randn(50) .* 0.1
        @test gate.success_criterion(high_vol, nothing) == false
    end

    # =========================================================================
    # run_walk_forward_validation Tests
    # =========================================================================
    @testset "run_walk_forward_validation - All Pass" begin
        returns = randn(100) .* 0.01

        gates = ValidationGate[
            ValidationGate("T1", Date(2024, 1, 1), Date(2024, 1, 31), 
                          (r, c) -> true),
            ValidationGate("T2", Date(2024, 2, 1), Date(2024, 2, 29), 
                          (r, c) -> true),
            ValidationGate("T3", Date(2024, 3, 1), Date(2024, 3, 31), 
                          (r, c) -> true)
        ]

        results = run_walk_forward_validation(gates, returns, nothing)

        @test results isa Dict{String, Bool}
        @test results["T1"] == true
        @test results["T2"] == true
        @test results["T3"] == true
        @test all(values(results))
    end

    @testset "run_walk_forward_validation - Some Fail" begin
        returns = randn(100) .* 0.01

        gates = ValidationGate[
            ValidationGate("T1", Date(2024, 1, 1), Date(2024, 1, 31), 
                          (r, c) -> true),
            ValidationGate("T2", Date(2024, 2, 1), Date(2024, 2, 29), 
                          (r, c) -> false),
            ValidationGate("T3", Date(2024, 3, 1), Date(2024, 3, 31), 
                          (r, c) -> true)
        ]

        results = run_walk_forward_validation(gates, returns, nothing)

        @test results["T1"] == true
        @test results["T2"] == false
        @test results["T3"] == true
        @test !all(values(results))
    end

    @testset "run_walk_forward_validation - Empty Gates" begin
        returns = randn(50) .* 0.01
        results = run_walk_forward_validation(ValidationGate[], returns, nothing)

        @test isempty(results)
    end

    # =========================================================================
    # PMOMetrics Tests
    # =========================================================================
    @testset "PMOMetrics - Structure" begin
        metrics = PMOMetrics(0.85, 0.92, 0.01, 0.02, 0.03, 3)

        @test metrics.classification_accuracy ≈ 0.85
        @test metrics.bootstrap_coverage ≈ 0.92
        @test metrics.mse_fixed ≈ 0.01
        @test metrics.mse_growth ≈ 0.02
        @test metrics.mse_floating ≈ 0.03
        @test metrics.arma_order_changes == 3
    end

    @testset "compute_pmo_metrics - Perfect Classification" begin
        n = 100
        regime_probs = zeros(n, 3)
        for i in 1:n
            regime_probs[i, mod(i, 3) + 1] = 1.0
        end

        ex_post = [mod(i, 3) + 1 for i in 1:n]
        intervals = [(rand()-0.5, rand()+0.5) for _ in 1:n]
        actuals = randn(n)
        mse_by_regime = (fixed=0.01, growth=0.02, floating=0.03)
        change_log = Pair{String, Date}[]

        metrics = compute_pmo_metrics(
            regime_probs, ex_post, intervals, actuals, mse_by_regime, change_log
        )

        @test metrics.classification_accuracy ≈ 1.0
        @test metrics.arma_order_changes == 0
    end

    @testset "compute_pmo_metrics - Random Classification" begin
        n = 100
        regime_probs = rand(n, 3)
        regime_probs ./= sum(regime_probs, dims=2)

        ex_post = rand(1:3, n)
        intervals = [(-1.0, 1.0) for _ in 1:n]
        actuals = randn(n)
        mse_by_regime = (fixed=0.01, growth=0.02, floating=0.03)
        change_log = ["AR(1)" => Date(2024, 1, 15), "MA(1)" => Date(2024, 3, 1)]

        metrics = compute_pmo_metrics(
            regime_probs, ex_post, intervals, actuals, mse_by_regime, change_log
        )

        @test 0.0 <= metrics.classification_accuracy <= 1.0
        @test 0.0 <= metrics.bootstrap_coverage <= 1.0
        @test metrics.arma_order_changes > 0
    end

    @testset "compute_pmo_metrics - Bootstrap Coverage" begin
        n = 100
        regime_probs = rand(n, 3)
        regime_probs ./= sum(regime_probs, dims=2)
        ex_post = rand(1:3, n)

        # All intervals contain actuals
        actuals = fill(0.0, n)
        intervals = [(-1.0, 1.0) for _ in 1:n]

        mse_by_regime = (fixed=0.01, growth=0.02, floating=0.03)
        change_log = Pair{String, Date}[]

        metrics = compute_pmo_metrics(
            regime_probs, ex_post, intervals, actuals, mse_by_regime, change_log
        )

        @test metrics.bootstrap_coverage ≈ 1.0
    end

    @testset "compute_pmo_metrics - Zero Coverage" begin
        n = 100
        regime_probs = rand(n, 3)
        regime_probs ./= sum(regime_probs, dims=2)
        ex_post = rand(1:3, n)

        # No intervals contain actuals
        actuals = fill(10.0, n)
        intervals = [(-1.0, 1.0) for _ in 1:n]

        mse_by_regime = (fixed=0.01, growth=0.02, floating=0.03)
        change_log = Pair{String, Date}[]

        metrics = compute_pmo_metrics(
            regime_probs, ex_post, intervals, actuals, mse_by_regime, change_log
        )

        @test metrics.bootstrap_coverage ≈ 0.0
    end

    # =========================================================================
    # check_escalation_threshold Tests
    # =========================================================================
    @testset "check_escalation_threshold - All Good" begin
        metrics = PMOMetrics(0.9, 0.95, 0.01, 0.02, 0.03, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 0)

        @test needs_esc == false
        @test isempty(failed)
    end

    @testset "check_escalation_threshold - Classification Fail" begin
        metrics = PMOMetrics(0.6, 0.95, 0.01, 0.02, 0.03, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 0)

        @test needs_esc == false  # First failure, no escalation yet
        @test "classification_accuracy" in failed
    end

    @testset "check_escalation_threshold - Bootstrap Fail" begin
        metrics = PMOMetrics(0.9, 0.85, 0.01, 0.02, 0.03, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 0)

        @test needs_esc == false
        @test "bootstrap_coverage" in failed
    end

    @testset "check_escalation_threshold - MSE Fail" begin
        metrics = PMOMetrics(0.9, 0.95, 0.01, 0.02, 0.06, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 0)

        @test needs_esc == false
        @test "mse" in failed
    end

    @testset "check_escalation_threshold - Multiple Failures" begin
        metrics = PMOMetrics(0.6, 0.85, 0.01, 0.02, 0.06, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 0)

        @test length(failed) == 3
        @test needs_esc == false  # First check
    end

    @testset "check_escalation_threshold - Escalation Trigger" begin
        metrics = PMOMetrics(0.6, 0.95, 0.01, 0.02, 0.03, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        # 3 consecutive failures
        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 3)

        @test needs_esc == true
        @test "classification_accuracy" in failed
    end

    @testset "check_escalation_threshold - No Failures" begin
        metrics = PMOMetrics(0.9, 0.95, 0.01, 0.02, 0.03, 2)
        thresholds = (
            classification_accuracy_min=0.7,
            bootstrap_coverage_min=0.9,
            mse_max=0.05
        )

        needs_esc, failed = check_escalation_threshold(metrics, thresholds, 5)

        @test needs_esc == false  # No failures even with high count
        @test isempty(failed)
    end

    # =========================================================================
    # Internal Helper Tests
    # =========================================================================
    @testset "_init_version_db" begin
        # Test database initialization
        db_path = "test_registry.db"

        # Clean up if exists
        isfile(db_path) && rm(db_path)

        Governance._init_version_db(db_path)

        @test isfile(db_path)

        # Clean up
        rm(db_path)
    end

    @testset "_serialize_model and _deserialize_model" begin
        model = Dict(:test => "value")
        serialized = Governance._serialize_model(model)

        @test serialized isa Vector{UInt8}
        @test length(serialized) > 0

        deserialized = Governance._deserialize_model(serialized)
        @test deserialized === nothing  # Placeholder implementation
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full Governance Pipeline" begin
        # Create metrics
        metrics = PMOMetrics(0.75, 0.88, 0.02, 0.03, 0.04, 5)

        # Check escalation
        thresholds = (
            classification_accuracy_min=0.8,
            bootstrap_coverage_min=0.9,
            mse_max=0.03
        )

        needs_esc1, failed1 = check_escalation_threshold(metrics, thresholds, 1)
        @test needs_esc1 == false
        @test !isempty(failed1)

        needs_esc3, failed3 = check_escalation_threshold(metrics, thresholds, 3)
        @test needs_esc3 == true

        # Check rollback
        should_roll, reason = check_rollback(0.07, 0.05, 1.2)
        @test should_roll == true

        # Create validation gates
        gates = ValidationGate[
            ValidationGate("T1", Date(2024, 1, 1), Date(2024, 1, 31), 
                          (r, c) -> length(r) > 50),
            ValidationGate("T2", Date(2024, 2, 1), Date(2024, 2, 29), 
                          (r, c) -> std(r) < 0.05)
        ]

        returns = randn(100) .* 0.01
        results = run_walk_forward_validation(gates, returns, nothing)

        @test haskey(results, "T1")
        @test haskey(results, "T2")
    end

    @testset "Rollback Decision Workflow" begin
        # Current model performing well
        should_roll1, _ = check_rollback(0.045, 0.05, 1.2)
        @test should_roll1 == false

        # Current model degraded slightly
        should_roll2, _ = check_rollback(0.055, 0.05, 1.2)
        @test should_roll2 == false

        # Current model degraded significantly
        should_roll3, _ = check_rollback(0.07, 0.05, 1.2)
        @test should_roll3 == true

        # If rollback needed, check escalation
        if should_roll3
            metrics = PMOMetrics(0.6, 0.85, 0.04, 0.05, 0.06, 8)
            thresholds = (
                classification_accuracy_min=0.7,
                bootstrap_coverage_min=0.9,
                mse_max=0.03
            )

            needs_esc, failed = check_escalation_threshold(metrics, thresholds, 3)
            @test needs_esc == true
        end
    end

    @testset "Version Lifecycle" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")

        # Create version
        v1 = ModelVersion("v_2024_06_15", dt, nothing, 0.05, true)
        @test v1.is_active == true

        # Create newer version
        v2 = ModelVersion("v_2024_06_22", dt + Day(7), nothing, 0.06, true)
        @test v2.mae_forecast > v1.mae_forecast

        # Check if rollback needed
        should_roll, reason = check_rollback(v2.mae_forecast, v1.mae_forecast, 1.2)
        @test should_roll == false  # 0.06/0.05 = 1.2, exactly at threshold
    end

end  # @testset Governance Module

end  # module TestGovernance
