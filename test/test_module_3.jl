module TestPCACompression

using Test, Dates, TimeZones

include("../src/module_3_pca/module_3_pca.jl")
using .PCACompression

@testset "PCACompression Module - Comprehensive" begin

    # =========================================================================
    # VolSurfacePCA Tests
    # =========================================================================
    @testset "VolSurfacePCA Structure" begin
        n = 100
        data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,   # VIX ~ 15-25
            rand(n) .* 8 .+ 18,    # VXV ~ 18-26
            rand(n) .* 20 .+ 80,   # VVIX ~ 80-100
            rand(n) .* 5 .+ 15,    # VIX1D ~ 15-20
            rand(n) .* 100         # IV Rank 0-100
        )

        @test length(data.vix) == n
        @test length(data.vxv) == n
        @test length(data.vvix) == n
        @test length(data.vix1d) == n
        @test length(data.iv_rank) == n
    end

    @testset "VolSurfacePCA - Empty" begin
        data = VolSurfacePCA(Float64[], Float64[], Float64[], Float64[], Float64[])
        @test length(data.vix) == 0
    end

    # =========================================================================
    # fit_vol_pca Tests
    # =========================================================================
    @testset "fit_vol_pca - Basic" begin
        n = 100
        data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        pca = fit_vol_pca(data, 3)
        @test pca !== nothing
    end

    @testset "fit_vol_pca - With NaN" begin
        n = 100
        vix = rand(n) .* 10 .+ 15
        vix[50] = NaN

        data = VolSurfacePCA(
            vix,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        pca = fit_vol_pca(data, 3)
        @test pca !== nothing
    end

    @testset "fit_vol_pca - Insufficient Data" begin
        n = 5
        data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        @test_throws AssertionError fit_vol_pca(data, 3)
    end

    # =========================================================================
    # transform_vol_pca Tests
    # =========================================================================
    @testset "transform_vol_pca - Basic" begin
        n = 100
        data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        pca = fit_vol_pca(data, 3)
        pc1, pc2, pc3 = transform_vol_pca(pca, data)

        @test length(pc1) == n
        @test length(pc2) == n
        @test length(pc3) == n
    end

    @testset "transform_vol_pca - With NaN Handling" begin
        n = 50
        vix = rand(n) .* 10 .+ 15
        vix[25] = NaN

        data = VolSurfacePCA(
            vix,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        pca = fit_vol_pca(data, 3)
        pc1, pc2, pc3 = transform_vol_pca(pca, data)

        @test isnan(pc1[25])
        @test isnan(pc2[25])
        @test isnan(pc3[25])
        @test !isnan(pc1[1])
    end

    # =========================================================================
    # YieldCurve Tests
    # =========================================================================
    @testset "YieldCurve Structure" begin
        maturities = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0, 20.0, 30.0]
        n_days = 50
        yields = rand(n_days, 10) .* 2.0 .+ 3.0

        yc = YieldCurve(maturities, yields)

        @test yc.maturities == maturities
        @test size(yc.yields) == (n_days, 10)
    end

    @testset "YieldCurve - Single Day" begin
        maturities = [2.0, 10.0, 30.0]
        yields = reshape([4.5, 4.2, 4.4], 1, 3)

        yc = YieldCurve(maturities, yields)
        @test size(yc.yields) == (1, 3)
    end

    # =========================================================================
    # litterman_scheinkman_factors Tests
    # =========================================================================
    @testset "litterman_scheinkman_factors - Standard Maturities" begin
        maturities = [0.25, 2.0, 10.0, 30.0]
        n_days = 50
        yields = rand(n_days, 4) .* 2.0 .+ 3.0

        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        @test length(level) == n_days
        @test length(slope) == n_days
        @test length(curvature) == n_days
    end

    @testset "litterman_scheinkman_factors - Level Interpretation" begin
        # When all yields equal, level = yield, slope = 0, curvature = 0
        maturities = [0.25, 2.0, 10.0]
        n_days = 5
        yields = fill(4.0, n_days, 3)

        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        @test all(level .≈ 4.0)
        @test all(abs.(slope) .< 1e-10)
        @test all(abs.(curvature) .< 1e-10)
    end

    @testset "litterman_scheinkman_factors - Upward Sloping" begin
        # Upward sloping curve: slope > 0
        maturities = [0.25, 2.0, 10.0]
        n_days = 5
        yields = hcat(
            fill(3.0, n_days),
            fill(4.0, n_days),
            fill(5.0, n_days)
        )

        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        @test all(slope .> 0)  # Positive slope
    end

    @testset "litterman_scheinkman_factors - Inverted Curve" begin
        # Inverted curve: slope < 0
        maturities = [0.25, 2.0, 10.0]
        n_days = 5
        yields = hcat(
            fill(5.0, n_days),
            fill(4.0, n_days),
            fill(3.0, n_days)
        )

        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        @test all(slope .< 0)  # Negative slope
    end

    @testset "litterman_scheinkman_factors - Humped Curve" begin
        # Humped curve: positive curvature
        maturities = [0.25, 2.0, 10.0]
        n_days = 5
        yields = hcat(
            fill(3.0, n_days),
            fill(5.0, n_days),
            fill(4.0, n_days)
        )

        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        @test all(curvature .> 0)  # Positive curvature (humped)
    end

    # =========================================================================
    # StateVector Tests
    # =========================================================================
    @testset "StateVector Structure" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        sv = StateVector(dt, 0.5, -0.3, 0.1, 4.2, -0.5, 0.2)

        @test sv.timestamp == dt
        @test sv.vol_pc1 ≈ 0.5
        @test sv.vol_pc2 ≈ -0.3
        @test sv.vol_pc3 ≈ 0.1
        @test sv.yield_level ≈ 4.2
        @test sv.yield_slope ≈ -0.5
        @test sv.yield_curvature ≈ 0.2
    end

    # =========================================================================
    # assemble_state_vector Tests (Vector)
    # =========================================================================
    @testset "assemble_state_vector - Vector Form" begin
        n = 50
        vol_pcs = (randn(n), randn(n), randn(n))
        yield_factors = (rand(n) .* 2 .+ 3, rand(n) .* 1 .- 0.5, rand(n) .* 0.5)
        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:n]

        states = assemble_state_vector(vol_pcs, yield_factors, true, timestamps)

        @test length(states) == n
        @test states[1].timestamp == timestamps[1]
        @test !isnan(states[1].vol_pc1)
        @test !isnan(states[1].vol_pc3)
    end

    @testset "assemble_state_vector - VIX1D Unavailable" begin
        n = 10
        vol_pcs = (randn(n), randn(n), randn(n))
        yield_factors = (rand(n), rand(n), rand(n))
        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:n]

        states = assemble_state_vector(vol_pcs, yield_factors, false, timestamps)

        @test all(isnan.(getfield.(states, :vol_pc3)))
        @test all(.!isnan.(getfield.(states, :vol_pc1)))
        @test all(.!isnan.(getfield.(states, :yield_level)))
    end

    @testset "assemble_state_vector - Length Validation" begin
        vol_pcs = (randn(10), randn(10), randn(10))
        yield_factors = (randn(8), randn(8), randn(8))  # Mismatched length
        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:10]

        @test_throws AssertionError assemble_state_vector(vol_pcs, yield_factors, true, timestamps)
    end

    @testset "assemble_state_vector - Timestamp Validation" begin
        vol_pcs = (randn(10), randn(10), randn(10))
        yield_factors = (randn(10), randn(10), randn(10))
        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:8]

        @test_throws AssertionError assemble_state_vector(vol_pcs, yield_factors, true, timestamps)
    end

    # =========================================================================
    # assemble_state_vector Tests (Scalar)
    # =========================================================================
    @testset "assemble_state_vector - Scalar Form" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        vol_pcs = (0.5, -0.3, 0.1)
        yield_factors = (4.2, -0.5, 0.2)

        state = assemble_state_vector(vol_pcs, yield_factors, true, dt)

        @test state isa StateVector
        @test state.timestamp == dt
        @test state.vol_pc1 ≈ 0.5
        @test state.vol_pc3 ≈ 0.1
    end

    @testset "assemble_state_vector - Scalar VIX1D Unavailable" begin
        dt = ZonedDateTime(DateTime(2024, 6, 15, 16, 0, 0), tz"America/New_York")
        vol_pcs = (0.5, -0.3, 0.1)
        yield_factors = (4.2, -0.5, 0.2)

        state = assemble_state_vector(vol_pcs, yield_factors, false, dt)

        @test isnan(state.vol_pc3)
        @test state.vol_pc1 ≈ 0.5
    end

    # =========================================================================
    # Integration Tests
    # =========================================================================
    @testset "Full Pipeline - VolSurfacePCA to StateVector" begin
        n = 100

        # Create synthetic volatility surface data
        vol_data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            rand(n) .* 5 .+ 15,
            rand(n) .* 100
        )

        # Fit PCA
        pca = fit_vol_pca(vol_data, 3)
        pc1, pc2, pc3 = transform_vol_pca(pca, vol_data)

        # Create yield curve
        maturities = [0.25, 2.0, 10.0, 30.0]
        yields = rand(n, 4) .* 2.0 .+ 3.0
        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        # Assemble state vectors
        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:n]
        states = assemble_state_vector((pc1, pc2, pc3), (level, slope, curvature), true, timestamps)

        @test length(states) == n
        @test all(.!isnan.(getfield.(states, :vol_pc1)))
        @test all(.!isnan.(getfield.(states, :yield_level)))
    end

    @testset "Full Pipeline - With Missing VIX1D" begin
        n = 50

        vol_data = VolSurfacePCA(
            rand(n) .* 10 .+ 15,
            rand(n) .* 8 .+ 18,
            rand(n) .* 20 .+ 80,
            fill(NaN, n),  # VIX1D unavailable
            rand(n) .* 100
        )

        pca = fit_vol_pca(vol_data, 3)
        pc1, pc2, pc3 = transform_vol_pca(pca, vol_data)

        maturities = [0.25, 2.0, 10.0]
        yields = rand(n, 3) .* 2.0 .+ 3.0
        yc = YieldCurve(maturities, yields)
        level, slope, curvature = litterman_scheinkman_factors(yc)

        timestamps = [ZonedDateTime(DateTime(2024, 1, i+1, 16, 0), tz"America/New_York") for i in 1:n]
        states = assemble_state_vector((pc1, pc2, pc3), (level, slope, curvature), false, timestamps)

        @test all(isnan.(getfield.(states, :vol_pc3)))
    end

end  # @testset PCACompression Module

end  # module TestPCACompression
