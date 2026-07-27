#!/usr/bin/env julia

# Daily Recursive Update
# Run every trading day after market close

using Dates, TimeZones

# Include required modules
include("../src/module_1_data/module_1_data.jl")
include("../src/module_3_pca/module_3_pca.jl")
include("../src/module_5_dpm/module_5_dpm.jl")
include("../src/module_6_cascade/module_6_cascade.jl")
include("../src/module_7_execution/module_7_execution.jl")
include("../src/module_10_feedback/module_10_feedback.jl")

using .DataIngestion, .PCACompression, .DPM, .CascadeInterface, .ExecutionLayer, .FeedbackLayer

include("live_execution.jl")   # governed execution glue (build_live_controller, execute_rebalance!, ...)

"""
    compute_targets(probs, sizing, market_state) -> Dict{String,Float64}

STRATEGY SEAM (placeholder). Maps regime probabilities + position sizing → desired signed
share positions per symbol. The concrete mapping (pool universe × blended cascade weights)
does not exist yet, so this returns an empty dict and `execute_rebalance!` no-ops. Fill this
in to actually trade.
"""
compute_targets(probs, sizing, market_state) = Dict{String,Float64}()

"""
    run_daily_recursive()

Execute daily recursive update pipeline.

Pipeline:
1. Fetch new market data
2. Update state vector
3. Recursive update with forgetting factor ρ = 0.99
4. Compute regime probabilities
5. Blend cascade parameters
6. Send position sizing to execution layer
"""
function run_daily_recursive()
    @info "Starting daily recursive update" timestamp=now(tz"America/New_York")

    try
        # 1. Fetch new market data
        @info "Step 1: Fetching daily market data"
        dt = now(tz"America/New_York")
        market_state = DataIngestion.assemble_market_state(dt)

        stale_count = count_stale_signals(market_state)
        @info "Market state assembled" stale_signals=stale_count 
              vix=market_state.vix.value vxv=market_state.vxv.value

        if stale_count >= 3
            @warn "Multiple stale signals detected, proceeding with caution"
        end

        # 2. Update state vector
        @info "Step 2: Computing state vector"

        # In production: use PCA model from weekly EM
        # For now: simplified state vector from raw observations
        vol_pc1 = DataIngestion.normalize_vix(market_state.vix.value)
        vol_pc2 = DataIngestion.normalize_vix_vxv_ratio(
            market_state.vix.value, market_state.vxv.value
        )
        vol_pc3 = market_state.vix1d_available ? 
                  DataIngestion.normalize_vix(market_state.vix1d.value) : NaN

        yield_level = market_state.gsw_10yr.value
        yield_slope = market_state.gsw_10yr.value - market_state.gsw_2yr.value
        yield_curvature = 2 * market_state.gsw_10yr.value - 
                          market_state.gsw_2yr.value - market_state.gsw_30yr.value

        state_vector = StateVector(
            dt, vol_pc1, vol_pc2, vol_pc3,
            yield_level, yield_slope, yield_curvature
        )

        @info "State vector computed" vol_pc1=vol_pc1 vol_pc2=vol_pc2 yield_slope=yield_slope

        # 3. Recursive DPM update
        @info "Step 3: Recursive DPM update"

        # Load previous DPM parameters
        # In production: load from state file
        previous_params = StickBreaking(
            [0.33, 0.33, 0.34],  # Equal weights as default
            [nothing, nothing, nothing]
        )

        # Compute synthetic return from state change
        # In production: use actual asset return
        new_return = vol_pc1 * 0.01  # Scaled state change as proxy

        forgetting_factor = 0.99
        updated_params = recursive_update(previous_params, new_return, forgetting_factor)

        @info "DPM updated" weights=updated_params.weights

        # 4. Compute regime probabilities
        @info "Step 4: Computing regime probabilities"

        # Map DPM components to three regimes (Fixed, Growth, Floating)
        # Simplified: use top 3 components
        probs = RegimeProbs(updated_params.weights[1:3])

        @info "Regime probabilities" fixed=probs.p_fixed growth=probs.p_growth 
              floating=probs.p_floating

        # 5. Blend cascade parameters
        @info "Step 5: Blending cascade parameters"

        blended = blend_cascade_params(probs)

        @info "Blended parameters" trend=blended.trend_weight 
              meanrev=blended.meanrev_weight defensive=blended.defensive_weight
              stop_width=blended.stop_width_atr max_hold=blended.max_holding_days

        # 6. Position sizing
        @info "Step 6: Computing position sizing"

        total_capital = 10000.0  # Per regional pool
        sizing = compute_position_sizing(probs, total_capital)

        @info "Position sizing" active_pct=sizing.active_pct 
              defensive_pct=sizing.defensive_pct exposure=sizing.exposure

        # 7. Governed execution (DRAFT integration; gated off unless BB_LIVE_EXEC=yes).
        #    Routes through the venue-agnostic ExecutionController — every order-path invariant
        #    (idempotency, lineage, per-pool budget/loss/staleness, kill switch) is enforced,
        #    fills are recorded to the ledger with lineage, and positions reconcile vs the broker.
        @info "Step 7: Governed execution"

        regime_name = ("fixed", "growth", "floating")[argmax([probs.p_fixed, probs.p_growth, probs.p_floating])]

        cb_state = CircuitBreakerStateMachine()
        should_liquidate, _ = check_emergency_liquidation(
            market_state.vvix.value, market_state.vix.value,
            0.05, 0.02, cb_state)   # envelope width / 6-mo median (placeholders)

        if get(ENV, "BB_LIVE_EXEC", "no") != "yes"
            @info "Execution disabled (dry run). Set BB_LIVE_EXEC=yes with a paper Gateway to enable." should_liquidate=should_liquidate
        else
            built = build_live_controller()          # connects to IBKR (paper via IBKR_PORT)
            ctrl, ledger = built.ctrl, built.ledger
            try
                connect!(built.venue) || error("IBKR connect failed — is the paper Gateway running?")
                pool = "us"
                set_pool_budget!(ctrl, pool, 10_000.0)         # per-pool caps (placeholder values)
                set_pool_loss_limit!(ctrl, pool, 1_000.0)
                set_pool_staleness!(ctrl, pool, Minute(30))
                feed_staleness!(ctrl, pool; stale = stale_count >= 3)

                if should_liquidate
                    @warn "EMERGENCY — halt new emission, then flatten the book (REQ-GOV-002)"
                    halt!(ctrl, "emergency liquidation trigger (VVIX/envelope)")
                    liq = flatten!(ctrl, ledger; signal_id = "emergency", regime = regime_name,
                                   solve_id = Dates.format(dt, "yyyymmdd"))
                    @info "Emergency flatten complete" liquidation_orders=length(liq)
                else
                    targets = compute_targets(probs, sizing, market_state)   # STRATEGY SEAM (placeholder → empty)
                    prices  = Dict{String,Float64}()                         # decision-time ref prices (from market data)
                    res = execute_rebalance!(ctrl, ledger;
                        targets = targets, prices = prices,
                        signal_id = "daily", regime = regime_name,
                        solve_id = Dates.format(dt, "yyyymmdd"), pool_id = pool)
                    @info "Rebalance complete" orders=length(res.acks) fills=length(res.fills) reconciled=res.reconciled
                end
            finally
                disconnect!(built.venue)
                close_ledger(ledger)
            end
        end

        # Create GammaARMAOutput for risk engine
        gamma_output = create_gamma_arma_output(
            probs,
            market_state.vix.value / 100.0,  # Conditional vol proxy
            2.5,  # Tail index (placeholder)
            0.1   # Jump intensity (placeholder)
        )

        @info "Daily recursive update complete" 
              regime=argmax([probs.p_fixed, probs.p_growth, probs.p_floating])

    catch e
        @error "Daily recursive update failed" exception=e
        rethrow(e)
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_daily_recursive()
end
