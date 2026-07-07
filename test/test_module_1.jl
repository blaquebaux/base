module TestDataIngestion

using Test
using Dates, TimeZones

include("../src/module_1_data/module_1_data.jl")
using .DataIngestion

@testset "DataIngestion Module - Comprehensive" begin

    # =========================================================================
    # FeedConfig Tests
    # =========================================================================
    @testset "FeedConfig Structure" begin
        config = FeedConfig(
            "VIX",
            "https://www.cboe.com/tradable_products/vix/",
            "https://backup.cboe.com/vix/",
            Second(86400),
            Second(172800)
        )

        @test config.name == "VIX"
        @test config.primary_source == "https://www.cboe.com/tradable_products/vix/"
        @test config.backup_source == "https://backup.cboe.com/vix/"
        @test config.expected_cadence == Second(86400)
        @test config.staleness_threshold == Second(172800)
    end

    @testset "FeedConfig with Nothing Backup" begin
        config = FeedConfig("GSW", "https://fed.gov", nothing, Second(86400), Second(259200))
        @test config.backup_source === nothing
    end

    # =========================================================================
    # Observation Tests
    # =========================================================================
    @testset "Observation Structure" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = Observation(dt, 22.45, false, "CBOE")

        @test obs.timestamp == dt
        @test obs.value ≈ 22.45
        @test obs.is_stale == false
        @test obs.source == "CBOE"
    end

    @testset "Observation with Stale Flag" begin
        dt = now(tz"America/New_York") - Day(5)
        obs = Observation(dt, 25.0, true, "DELAYED")
        @test obs.is_stale == true
    end

    # =========================================================================
    # MarketState Tests
    # =========================================================================
    @testset "MarketState Assembly" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        state = assemble_market_state(dt)

        @test state.timestamp == dt
        @test state.vix.value > 0
        @test state.vxv.value > 0
        @test state.vvix.value > 0
        @test state.iv_rank.value >= 0
        @test state.gsw_2yr.value > 0
        @test state.gsw_10yr.value > 0
        @test state.gsw_30yr.value > 0
        @test state.ois_sofr_spread.value isa Float64
        @test state.tga_balance.value > 0
        @test 0.0 <= state.vix_vxv_ratio <= 1.0
        @test state.vix1d_available isa Bool
    end

    @testset "MarketState VIX1D Fallback" begin
        dt = ZonedDateTime(DateTime(2020, 1, 15, 16, 0, 0), tz"America/New_York")
        state = assemble_market_state(dt)

        # VIX1D didn't exist before 2022
        @test state.vix1d_available == false || isnan(state.vix1d.value)
    end

    @testset "MarketState with Current Date" begin
        dt = now(tz"America/New_York")
        state = assemble_market_state(dt)

        @test state.timestamp == dt
        @test !isnan(state.vix.value)
        @test !isnan(state.vxv.value)
    end

    # =========================================================================
    # Fetch and Normalize Tests
    # =========================================================================
    @testset "fetch_and_normalize VIX" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(VIX, dt)

        @test obs isa Observation
        @test obs.value > 0
        @test obs.source != ""
    end

    @testset "fetch_and_normalize VXV" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(VXV, dt)

        @test obs isa Observation
        @test obs.value > 0
    end

    @testset "fetch_and_normalize VVIX" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(VVIX, dt)

        @test obs isa Observation
        @test obs.value > 0
    end

    @testset "fetch_and_normalize VIX1D - Available" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(VIX1D, dt)

        @test obs isa Observation
        # Should be available for 2024
        @test !isnan(obs.value) || obs.is_stale
    end

    @testset "fetch_and_normalize VIX1D - Unavailable (Pre-2022)" begin
        dt = ZonedDateTime(DateTime(2021, 1, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(VIX1D, dt)

        @test obs.is_stale == true
        @test isnan(obs.value)
    end

    @testset "fetch_and_normalize IV_Rank_SPY" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(IV_Rank_SPY, dt)

        @test obs isa Observation
        @test 0.0 <= obs.value <= 100.0
    end

    @testset "fetch_and_normalize GSW - Valid Maturities" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")

        obs_2yr = fetch_and_normalize(GSW, 2, dt)
        obs_10yr = fetch_and_normalize(GSW, 10, dt)
        obs_30yr = fetch_and_normalize(GSW, 30, dt)

        @test obs_2yr.value > 0
        @test obs_10yr.value > 0
        @test obs_30yr.value > 0
    end

    @testset "fetch_and_normalize GSW - Invalid Maturity" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        @test_throws AssertionError fetch_and_normalize(GSW, 5, dt)
    end

    @testset "fetch_and_normalize OIS_SOFR_spread" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(OIS_SOFR_spread, dt)

        @test obs isa Observation
        @test !isnan(obs.value)
    end

    @testset "fetch_and_normalize TGA_balance" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        obs = fetch_and_normalize(TGA_balance, dt)

        @test obs isa Observation
        @test obs.value > 0
    end

    # =========================================================================
    # Staleness Detection Tests
    # =========================================================================
    @testset "is_stale - Fresh Observation" begin
        config = FeedConfig("TEST", "url", nothing, Second(60), Second(120))
        fresh_obs = Observation(now(tz"America/New_York"), 100.0, false, "test")

        @test is_stale(fresh_obs, config) == false
    end

    @testset "is_stale - Explicitly Stale" begin
        config = FeedConfig("TEST", "url", nothing, Second(60), Second(120))
        stale_obs = Observation(now(tz"America/New_York"), 100.0, true, "test")

        @test is_stale(stale_obs, config) == true
    end

    @testset "is_stale - Age Based" begin
        config = FeedConfig("TEST", "url", nothing, Second(60), Second(1))
        old_obs = Observation(now(tz"America/New_York") - Second(2), 100.0, false, "test")

        @test is_stale(old_obs, config) == true
    end

    @testset "count_stale_signals" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        state = assemble_market_state(dt)

        count = count_stale_signals(state)
        @test count >= 0
        @test count <= 10
    end

    # =========================================================================
    # Normalization Tests
    # =========================================================================
    @testset "normalize_vix - Typical Values" begin
        z1 = normalize_vix(20.0)
        z2 = normalize_vix(30.0)
        z3 = normalize_vix(15.0)

        @test z1 isa Float64
        @test z2 > z1  # Higher VIX → higher z-score
        @test z3 < z1  # Lower VIX → lower z-score
    end

    @testset "normalize_vix - Edge Cases" begin
        @test isnan(normalize_vix(0.0))
        @test isnan(normalize_vix(-5.0))
    end

    @testset "normalize_iv_rank - Clipping" begin
        @test normalize_iv_rank(50.0) == 50.0
        @test normalize_iv_rank(150.0) == 100.0
        @test normalize_iv_rank(-20.0) == 0.0
        @test normalize_iv_rank(0.0) == 0.0
        @test normalize_iv_rank(100.0) == 100.0
    end

    @testset "normalize_vix_vxv_ratio - Range" begin
        r1 = normalize_vix_vxv_ratio(20.0, 22.0)  # Contango
        r2 = normalize_vix_vxv_ratio(25.0, 22.0)  # Backwardation
        r3 = normalize_vix_vxv_ratio(18.0, 22.0)  # Deep contango

        @test 0.0 <= r1 <= 1.0
        @test 0.0 <= r2 <= 1.0
        @test 0.0 <= r3 <= 1.0
        @test r2 > r1  # Backwardation > contango
    end

    @testset "normalize_vix_vxv_ratio - Edge Cases" begin
        @test normalize_vix_vxv_ratio(20.0, 0.0) == 0.5  # Invalid VXV
        @test normalize_vix_vxv_ratio(30.0, 22.0) ≈ 1.0 atol=0.01  # Cap
        @test normalize_vix_vxv_ratio(15.0, 22.0) ≈ 0.0 atol=0.01  # Floor
    end

    # =========================================================================
    # Fallback Handling Tests
    # =========================================================================
    @testset "vix1d_unavailable_handling - Unavailable" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        state = assemble_market_state(dt)

        # Force VIX1D unavailable
        modified_state = MarketState(
            state.timestamp,
            state.vix, state.vxv, state.vvix,
            Observation(dt, NaN, true, "UNAVAILABLE"),
            state.iv_rank, state.gsw_2yr, state.gsw_10yr, state.gsw_30yr,
            state.ois_sofr_spread, state.tga_balance,
            state.vix_vxv_ratio, true
        )

        fallback = vix1d_unavailable_handling(modified_state)
        @test fallback.vix1d_available == false
        @test isnan(fallback.vix1d.value)
    end

    @testset "vix1d_unavailable_handling - Available" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        state = assemble_market_state(dt)

        if state.vix1d_available
            fallback = vix1d_unavailable_handling(state)
            @test fallback.vix1d_available == true
            @test fallback === state  # Should return same object
        end
    end

    # =========================================================================
    # Data Feed Types Tests
    # =========================================================================
    @testset "DataFeed Abstract Types" begin
        @test VIX <: DataFeed
        @test VXV <: DataFeed
        @test VVIX <: DataFeed
        @test VIX1D <: DataFeed
        @test IV_Rank_SPY <: DataFeed
        @test GSW <: DataFeed
        @test LW <: DataFeed
        @test OIS_SOFR_spread <: DataFeed
        @test TGA_balance <: DataFeed
    end

    # =========================================================================
    # Default Feeds Tests
    # =========================================================================
    @testset "DEFAULT_FEEDS" begin
        @test haskey(DEFAULT_FEEDS, "VIX")
        @test haskey(DEFAULT_FEEDS, "VXV")
        @test haskey(DEFAULT_FEEDS, "VVIX")
        @test haskey(DEFAULT_FEEDS, "VIX1D")
        @test haskey(DEFAULT_FEEDS, "IV_Rank_SPY")
        @test haskey(DEFAULT_FEEDS, "GSW")
        @test haskey(DEFAULT_FEEDS, "OIS_SOFR")
        @test haskey(DEFAULT_FEEDS, "TGA")
    end

    @testset "DEFAULT_FEEDS Configuration" begin
        vix_config = DEFAULT_FEEDS["VIX"]
        @test vix_config.expected_cadence == Second(86400)
        @test vix_config.staleness_threshold == Second(172800)

        vix1d_config = DEFAULT_FEEDS["VIX1D"]
        @test vix1d_config.staleness_threshold == Second(86400)  # Stricter
    end

end  # @testset DataIngestion Module

end  # module TestDataIngestion
