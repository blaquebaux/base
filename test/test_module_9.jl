# =============================================================================
# test_module_9.jl — Module 9 (0DTE overlay, ZeroDTE) load + smoke test (PRE-02).
# Confirms the module loads and its public API is defined; one pure helper is
# exercised. Deeper behavioural coverage is a later task.
# =============================================================================
isdefined(Main, :ZeroDTE) || include("../src/module_9_0dte/module_9_0dte.jl")
using .ZeroDTE
using Test

@testset "Module 9: ZeroDTE loads" begin
    for s in (:OptionGreeks, :ZeroDTEParams, :ZeroDTESignal, :screen_greeks,
              :compute_iv_rank, :classify_orb_iv_quadrant, :size_position,
              :evaluate_0dte_setup, :DEFAULT_PARAMS)
        @test isdefined(ZeroDTE, s)
    end
    # compute_iv_rank is a pure function: current IV at the top of its history
    # ranks at 1.0; empty history is the neutral 0.5.
    @test ZeroDTE.compute_iv_rank([0.10, 0.20, 0.30], 0.30) ≈ 1.0
    @test ZeroDTE.compute_iv_rank(Float64[], 0.25) ≈ 0.5
end
