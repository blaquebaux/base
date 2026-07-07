module TestExecutionLayer

using Test, Dates, TimeZones

include("../src/module_7_execution/module_7_execution.jl")
using .ExecutionLayer

@testset "ExecutionLayer Module - Comprehensive" begin

    # =========================================================================
    # OrderType Enum Tests
    # =========================================================================
    @testset "OrderType" begin
        @test LIMIT isa OrderType
        @test MARKET isa OrderType
        @test LIMIT != MARKET
    end

    # =========================================================================
    # IBKROrder Tests
    # =========================================================================
    @testset "IBKROrder - Limit Order" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("SPY", LIMIT, 450.0, 100, "MAIN", dt)

        @test order.symbol == "SPY"
        @test order.order_type == LIMIT
        @test order.limit_price ≈ 450.0
        @test order.quantity == 100
        @test order.account == "MAIN"
        @test order.timestamp == dt
    end

    @testset "IBKROrder - Market Order" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("QQQ", MARKET, nothing, -50, "MAIN", dt)

        @test order.symbol == "QQQ"
        @test order.order_type == MARKET
        @test order.limit_price === nothing
        @test order.quantity == -50
    end

    @testset "IBKROrder - Convenience Constructor" begin
        order = IBKROrder("SPY", LIMIT, 450.0, 100, "MAIN")

        @test order.symbol == "SPY"
        @test order.timestamp <= now(tz"America/New_York")
    end

    @testset "IBKROrder - Validation" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")

        # Limit order without price
        @test_throws AssertionError IBKROrder("SPY", LIMIT, nothing, 100, "MAIN", dt)

        # Zero quantity
        @test_throws AssertionError IBKROrder("SPY", MARKET, nothing, 0, "MAIN", dt)

        # Negative limit price
        @test_throws AssertionError IBKROrder("SPY", LIMIT, -100.0, 100, "MAIN", dt)
    end

    # =========================================================================
    # CircuitBreakerState Tests
    # =========================================================================
    @testset "CircuitBreakerState" begin
        @test NORMAL isa CircuitBreakerState
        @test VVIX_WATCH isa CircuitBreakerState
        @test BOOTSTRAP_WATCH isa CircuitBreakerState
        @test EMERGENCY_LIQUIDATION isa CircuitBreakerState
        @test COOLDOWN isa CircuitBreakerState

        @test NORMAL != EMERGENCY_LIQUIDATION
    end

    # =========================================================================
    # CircuitBreakerStateMachine Tests
    # =========================================================================
    @testset "CircuitBreakerStateMachine - Default" begin
        cb = CircuitBreakerStateMachine()

        @test cb.state == NORMAL
        @test cb.vvix_breached_count == 0
        @test cb.bootstrap_envelope_3x == false
        @test cb.cooldown_until === nothing
    end

    @testset "CircuitBreakerStateMachine - Mutable" begin
        cb = CircuitBreakerStateMachine()
        cb.state = VVIX_WATCH
        cb.vvix_breached_count = 2

        @test cb.state == VVIX_WATCH
        @test cb.vvix_breached_count == 2
    end

    # =========================================================================
    # check_emergency_liquidation Tests
    # =========================================================================
    @testset "check_emergency_liquidation - Normal" begin
        cb = CircuitBreakerStateMachine()
        should_liq, new_cb = check_emergency_liquidation(
            80.0, 20.0, 0.05, 0.02, cb
        )

        @test should_liq == false
        @test new_cb.state == NORMAL
    end

    @testset "check_emergency_liquidation - VIX > 40" begin
        cb = CircuitBreakerStateMachine()
        should_liq, new_cb = check_emergency_liquidation(
            80.0, 45.0, 0.05, 0.02, cb
        )

        @test should_liq == true
        @test new_cb.state == EMERGENCY_LIQUIDATION
        @test new_cb.cooldown_until !== nothing
    end

    @testset "check_emergency_liquidation - VVIX Persistence (1 breach)" begin
        cb = CircuitBreakerStateMachine()
        should_liq, new_cb = check_emergency_liquidation(
            125.0, 20.0, 0.05, 0.02, cb
        )

        @test should_liq == false
        @test new_cb.state == VVIX_WATCH
        @test new_cb.vvix_breached_count == 1
    end

    @testset "check_emergency_liquidation - VVIX Persistence (2 breaches)" begin
        cb = CircuitBreakerStateMachine()
        _, cb1 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb)
        should_liq, cb2 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb1)

        @test should_liq == false
        @test cb2.vvix_breached_count == 2
    end

    @testset "check_emergency_liquidation - VVIX Persistence (3 breaches)" begin
        cb = CircuitBreakerStateMachine()
        _, cb1 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb)
        _, cb2 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb1)
        should_liq, cb3 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb2)

        @test should_liq == true
        @test cb3.state == EMERGENCY_LIQUIDATION
        @test cb3.vvix_breached_count == 3
    end

    @testset "check_emergency_liquidation - VVIX Recovery" begin
        cb = CircuitBreakerStateMachine()
        _, cb1 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb)
        should_liq, cb2 = check_emergency_liquidation(80.0, 20.0, 0.05, 0.02, cb1)

        @test should_liq == false
        @test cb2.vvix_breached_count == 0
        @test cb2.state == NORMAL
    end

    @testset "check_emergency_liquidation - Bootstrap 3x" begin
        cb = CircuitBreakerStateMachine()
        should_liq, new_cb = check_emergency_liquidation(
            80.0, 20.0, 0.15, 0.05, cb
        )

        @test should_liq == true
        @test new_cb.state == BOOTSTRAP_WATCH
        @test new_cb.bootstrap_envelope_3x == true
    end

    @testset "check_emergency_liquidation - Multiple Triggers" begin
        cb = CircuitBreakerStateMachine()
        # VIX > 40 AND bootstrap 3x
        should_liq, new_cb = check_emergency_liquidation(
            80.0, 45.0, 0.15, 0.05, cb
        )

        @test should_liq == true
        @test new_cb.state == EMERGENCY_LIQUIDATION
    end

    @testset "check_emergency_liquidation - Cooldown" begin
        cb = CircuitBreakerStateMachine()
        _, cb1 = check_emergency_liquidation(80.0, 45.0, 0.05, 0.02, cb)

        # During cooldown, should not liquidate again
        should_liq, cb2 = check_emergency_liquidation(
            80.0, 45.0, 0.05, 0.02, cb1
        )

        @test should_liq == false
    end

    @testset "check_emergency_liquidation - Cooldown Expired" begin
        cb = CircuitBreakerStateMachine()
        _, cb1 = check_emergency_liquidation(80.0, 45.0, 0.05, 0.02, cb)

        # Manually expire cooldown
        cb1.cooldown_until = now(tz"America/New_York") - Minute(1)

        should_liq, cb2 = check_emergency_liquidation(
            80.0, 45.0, 0.05, 0.02, cb1
        )

        @test should_liq == true
    end

    # =========================================================================
    # send_order Tests
    # =========================================================================
    @testset "send_order - Market Order" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("SPY", MARKET, nothing, 100, "MAIN", dt)

        success, order_id, error = send_order(order)

        @test success == true
        @test !isempty(order_id)
        @test error === nothing
    end

    @testset "send_order - Limit Order" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("SPY", LIMIT, 450.0, -50, "MAIN", dt)

        success, order_id, error = send_order(order)

        @test success == true
        @test !isempty(order_id)
    end

    @testset "send_order - Large Quantity" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("SPY", MARKET, nothing, 2000000, "MAIN", dt)

        success, order_id, error = send_order(order)

        @test success == false
        @test error !== nothing
    end

    # =========================================================================
    # cancel_order Tests
    # =========================================================================
    @testset "cancel_order" begin
        @test cancel_order("TEST_123") == true
        @test cancel_order("") == true
    end

    # =========================================================================
    # get_current_positions Tests
    # =========================================================================
    @testset "get_current_positions" begin
        positions = get_current_positions("MAIN")

        @test positions isa Dict{String, Float64}
    end

    # =========================================================================
    # LatencyMetrics Tests
    # =========================================================================
    @testset "LatencyMetrics" begin
        metrics = LatencyMetrics(2.0, 0.5, 1.0)

        @test metrics.daily_rebalance_latency ≈ 2.0
        @test metrics.intraday_trigger_latency ≈ 0.5
        @test metrics.emergency_liquidation_latency ≈ 1.0
    end

    @testset "measure_latency" begin
        result, elapsed = measure_latency() do
            sleep(0.01)
            42
        end

        @test result == 42
        @test elapsed >= 0.01
    end

    # =========================================================================
    # apply_position_floor Tests
    # =========================================================================
    @testset "apply_position_floor - Notional" begin
        @test apply_position_floor(1000.0, 500.0) ≈ 1000.0
        @test apply_position_floor(500.0, 500.0) ≈ 500.0
        @test apply_position_floor(499.99, 500.0) ≈ 0.0
        @test apply_position_floor(100.0, 500.0) ≈ 0.0
        @test apply_position_floor(0.0, 500.0) ≈ 0.0
    end

    @testset "apply_position_floor - Quantity" begin
        @test apply_position_floor(100, 450.0, 500.0) == 100
        @test apply_position_floor(2, 450.0, 500.0) == 0  # 2 * 450 = 900 > 500
        @test apply_position_floor(1, 450.0, 500.0) == 0  # 1 * 450 = 450 < 500
        @test apply_position_floor(-1, 450.0, 500.0) == 0
    end

    @testset "apply_position_floor - Custom Floor" begin
        @test apply_position_floor(300.0, 250.0) ≈ 300.0
        @test apply_position_floor(200.0, 250.0) ≈ 0.0
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full Order Lifecycle" begin
        # Create order
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")
        order = IBKROrder("SPY", LIMIT, 450.0, 100, "MAIN", dt)

        # Send order
        success, order_id, error = send_order(order)
        @test success == true

        # Cancel order
        cancelled = cancel_order(order_id)
        @test cancelled == true
    end

    @testset "Emergency Liquidation Workflow" begin
        cb = CircuitBreakerStateMachine()

        # Normal state
        should_liq1, cb1 = check_emergency_liquidation(80.0, 20.0, 0.05, 0.02, cb)
        @test should_liq1 == false

        # VVIX breach
        should_liq2, cb2 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb1)
        @test should_liq2 == false

        # Second VVIX breach
        should_liq3, cb3 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb2)
        @test should_liq3 == false

        # Third VVIX breach - triggers liquidation
        should_liq4, cb4 = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb3)
        @test should_liq4 == true
        @test cb4.state == EMERGENCY_LIQUIDATION

        # Create and send liquidation order
        liq_order = IBKROrder("SPY", MARKET, nothing, -100, "MAIN")
        success, order_id, _ = send_order(liq_order)
        @test success == true

        # Verify cooldown prevents re-liquidation
        should_liq5, _ = check_emergency_liquidation(125.0, 20.0, 0.05, 0.02, cb4)
        @test should_liq5 == false
    end

    @testset "Position Sizing with Floor" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 10, 30, 0), tz"America/New_York")

        # Large order passes floor
        order_large = IBKROrder("SPY", LIMIT, 450.0, 100, "MAIN", dt)
        notional_large = abs(order_large.quantity * order_large.limit_price)
        @test apply_position_floor(notional_large, 500.0) > 0

        # Small order fails floor
        order_small = IBKROrder("SPY", LIMIT, 450.0, 1, "MAIN", dt)
        notional_small = abs(order_small.quantity * order_small.limit_price)
        @test apply_position_floor(notional_small, 500.0) == 0.0
    end

end  # @testset ExecutionLayer Module

end  # module TestExecutionLayer
