#!/usr/bin/env julia

# Weekly EM Estimation Job
# Run every Friday after market close

using Dates, TimeZones

# Include all modules
include("../src/module_1_data/module_1_data.jl")
include("../src/module_2_smoothing/module_2_smoothing.jl")
include("../src/module_3_pca/module_3_pca.jl")
include("../src/module_4_arma/module_4_arma.jl")
include("../src/module_5_dpm/module_5_dpm.jl")
include("../src/module_8_governance/module_8_governance.jl")

using .DataIngestion, .SignalSmoothing, .PCACompression, .ARMAGARCH, .DPM, .Governance

"""
    run_weekly_em()

Execute weekly EM estimation pipeline.

Pipeline:
1. Fetch data for past year (252 trading days)
2. Run smoothing pipeline on correlation series
3. Compute 6-dimensional state vectors
4. EM estimation warm-started from current recursive parameters
5. If converged: replace recursive parameters, store version
6. If failed: keep recursive, log warning
"""
function run_weekly_em()
    @info "Starting weekly EM estimation" timestamp=now(tz"America/New_York")

    try
        # 1. Fetch data for past year
        @info "Step 1: Fetching market data"
        end_date = now(tz"America/New_York")
        start_date = end_date - Day(365)

        # Generate trading dates (simplified: weekdays only)
        dates = Date(start_date):Day(1):Date(end_date)
        trading_dates = filter(d -> !(dayofweek(d) in [Saturday, Sunday]), collect(dates))

        # Fetch all market states
        market_states = MarketState[]
        for dt in trading_dates
            zdt = ZonedDateTime(DateTime(dt, Time(16, 0)), tz"America/New_York")  # 4pm close
            state = DataIngestion.assemble_market_state(zdt)
            push!(market_states, state)
        end

        @info "Fetched $(length(market_states)) market states"

        # 2. Run smoothing pipeline
        @info "Step 2: Running smoothing pipeline"

        # Extract correlation proxy (VIX/VXV ratio)
        vix_vxv_ratios = [state.vix_vxv_ratio for state in market_states]

        # Smooth correlation series
        pipeline_config = SmoothingPipelineConfig()
        smoothed, envelope = smooth_correlation_series(vix_vxv_ratios, vix_vxv_ratios, pipeline_config)

        @info "Smoothing complete" envelope_mean=mean(envelope[.!isnan.(envelope)])

        # 3. Compute state vectors
        @info "Step 3: Computing PCA state vectors"

        # Extract volatility surface data
        vol_data = VolSurfacePCA(
            [s.vix.value for s in market_states],
            [s.vxv.value for s in market_states],
            [s.vvix.value for s in market_states],
            [s.vix1d.value for s in market_states],
            [s.iv_rank.value for s in market_states]
        )

        # Fit and transform PCA
        pca_model = fit_vol_pca(vol_data, 3)
        pc1, pc2, pc3 = transform_vol_pca(pca_model, vol_data)

        # Yield curve factors (simplified: use GSW yields)
        yields = hcat(
            [s.gsw_2yr.value for s in market_states],
            [s.gsw_10yr.value for s in market_states],
            [s.gsw_30yr.value for s in market_states]
        )
        yield_curve = YieldCurve([2.0, 10.0, 30.0], yields)
        level, slope, curvature = litterman_scheinkman_factors(yield_curve)

        # Assemble state vectors
        timestamps = [s.timestamp for s in market_states]
        vix1d_avail = [s.vix1d_available for s in market_states]
        state_vectors = assemble_state_vector(
            (pc1, pc2, pc3),
            (level, slope, curvature),
            all(vix1d_avail),
            timestamps
        )

        @info "State vectors computed" n_vectors=length(state_vectors)

        # 4. EM Estimation
        @info "Step 4: Running EM estimation"

        # Generate synthetic returns from state vectors for DPM
        # In production: use actual asset returns
        returns = diff([sv.vol_pc1 for sv in state_vectors])
        returns = [isnan(r) ? 0.0 : r for r in returns]

        dpm_config = DPMConfig(max_components=20)
        pf_config = ParticleFilterConfig(n_particles=2000)

        # Warm-start from previous parameters if available
        initial_params = nothing  # In production: load from recursive state

        final_model, ll_history, converged = em_estimation(
            returns, dpm_config, pf_config, initial_params
        )

        @info "EM estimation complete" converged=converged 
              final_ll=ll_history[end] iterations=length(ll_history)

        # 5. Store version if converged
        if converged
            @info "Step 5: Storing model version"

            version_id = "v_$(Dates.format(today(), "YYYY_mm_dd"))"

            # Compute MAE on Friday close
            mae = mean(abs.(returns[.!isnan.(returns)]))

            version = ModelVersion(
                version_id,
                now(tz"America/New_York"),
                final_model,
                mae,
                true
            )

            db_path = "../data/model_registry.db"
            store_version(version, db_path)

            @info "Model version stored" version_id=version_id mae=mae
        else
            @warn "EM did not converge, keeping previous recursive parameters"
        end

        @info "Weekly EM estimation complete"

    catch e
        @error "Weekly EM estimation failed" exception=e
        rethrow(e)
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_weekly_em()
end
