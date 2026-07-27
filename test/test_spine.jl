module TestSpine

# Unit tests for the validated Path-B spine (src/module_13_portfolio/spine.jl):
# the TSMOM trend signal, its inverse-vol weighting, the vol-target overlay, and the
# composed spine allocation. Deterministic — no network, no market data. Verifies the
# *properties* the validation relied on (causal signs, risk equalization, de-levering
# as forecast vol rises), not the historical numbers (those live in the Python study).

using Test, Random, LinearAlgebra

include("../src/module_13_portfolio/module_13_portfolio.jl")
using .PortfolioOptModule

@testset "tsmom_signal — causal trend sign" begin
    R = hcat(fill(0.01, 300), fill(-0.01, 300), fill(0.0, 300))   # up / down / flat
    s = tsmom_signal(R; lookback = 252)
    @test s == [1.0, -1.0, 0.0]
    # Uses all rows when T < lookback (no lookahead, no error).
    @test tsmom_signal(fill(0.02, 10, 2); lookback = 252) == [1.0, 1.0]
    # Only the trailing `lookback` matters: an early crash outside the window is ignored.
    Rmix = vcat(fill(-0.5, 40, 1), fill(0.01, 300, 1))
    @test tsmom_signal(Rmix; lookback = 252) == [1.0]
end

@testset "tsmom_weights — inverse-vol, gross-normalized long/short" begin
    σ = [0.1, 0.2, 0.4]
    w = tsmom_weights(σ, [1.0, -1.0, 1.0])
    @test sum(abs, w) ≈ 1.0                      # gross-normalized
    @test sign.(w) == [1.0, -1.0, 1.0]           # signs follow the trend
    @test abs(w[1]) > abs(w[3])                  # lower-vol asset gets the larger position
    @test all(tsmom_weights(σ, [0.0, 0.0, 0.0]) .== 0.0)   # nothing trending → flat
end

@testset "voltarget_exposure — de-levers as ex-ante vol rises" begin
    # single asset engineered to 24% annual vol → exposure = target/vol = 0.12/0.24 = 0.5
    Σ = reshape([0.24^2 / 252], 1, 1)
    @test voltarget_exposure([1.0], Σ; target_vol = 0.12, cap = 1.5) ≈ 0.5 atol = 1e-6
    # de-risk-only cap: never levers above 1.0 even when calm
    calm = reshape([1e-8], 1, 1)
    @test voltarget_exposure([1.0], calm; target_vol = 0.12, cap = 1.0) ≈ 1.0
    # higher target ⇒ more exposure (monotone), still capped
    e_lo = voltarget_exposure([1.0], Σ; target_vol = 0.06, cap = 1.5)
    e_hi = voltarget_exposure([1.0], Σ; target_vol = 0.18, cap = 1.5)
    @test e_lo < e_hi
end

@testset "spine_weights — well-formed, deterministic, risk-timed" begin
    Random.seed!(20260727)
    base = randn(320, 4) .* 0.01
    w = spine_weights(base; sleeve_vol = 0.08, cap = 1.5)
    @test length(w) == 4
    @test all(isfinite, w)
    @test sum(abs, w) ≤ 1.5 + 1e-9               # gross never exceeds the cap

    # Determinism: identical input ⇒ identical output.
    @test spine_weights(base) == spine_weights(base)

    # Risk-timing: same structure, higher vol ⇒ smaller gross book (the overlay de-levers).
    calm = 0.2 .* base
    vol  = 5.0 .* base
    @test sum(abs, spine_weights(vol)) < sum(abs, spine_weights(calm))

    # de-risk-only cap keeps the book net-unlevered
    @test sum(abs, spine_weights(calm; cap = 1.0)) ≤ 1.0 + 1e-9

    # all three base constructions run and stay finite
    for b in (:erc, :invvar, :invvol)
        @test all(isfinite, spine_weights(base; base = b))
    end
end

@testset "spine_strategy — plugs into the walk-forward backtester" begin
    Random.seed!(1)
    # 4 assets with mild positive drift + idiosyncratic noise; deterministic.
    T, N = 700, 4
    R = randn(T, N) .* 0.01 .+ 0.0003
    bt = backtest(R, spine_strategy(); lookback = 252, rebalance = 21, cost_bps = 2.0)
    @test length(bt.returns) > 0
    @test all(isfinite, bt.returns)
    @test isfinite(sharpe(bt.returns))
    @test size(bt.weights, 1) == N               # one weight per asset per rebalance
end

# Walk a SpineState over a panel; return (final weights, state).
function walk_spine(R; lb = 252, kwargs...)
    N = size(R, 2); st = SpineState(N; kwargs...); w = zeros(N)
    for t in lb:size(R, 1)
        w = spine_step!(st, @view R[t-lb+1:t, :])
    end
    return w, st
end

@testset "SpineState — stateful production spine" begin
    Random.seed!(7)
    R = randn(400, 3) .* 0.01
    w, st = walk_spine(R)
    @test length(w) == 3 && all(isfinite, w)
    @test st.n == 400 - 252 + 1                       # one step per bar past warmup
    @test walk_spine(R)[1] == w                       # deterministic

    # de-levering: same structure, higher vol ⇒ smaller gross book. Isolate on the base
    # sleeve (base_weight=1) so the overlay is visible — with the 50/50 blend a fully
    # down-trending panel makes trend exactly oppose base and the book nets to flat (that
    # cancellation is the crash-protection behavior, tested separately).
    wc, _ = walk_spine(0.2 .* R; base_weight = 1.0); wv, _ = walk_spine(5.0 .* R; base_weight = 1.0)
    @test sum(abs, wv) < sum(abs, wc)

    # crash protection: when every asset down-trends, long base and short trend cancel ⇒ ~flat book
    Rdown = -0.003 .+ 0.001 .* randn(400, 3)
    wdn, _ = walk_spine(Rdown; base_weight = 0.5)
    @test sum(abs, wdn) < 0.2                          # de-risked toward cash in a broad downtrend

    # trend engagement: asset 1 up-trend, asset 2 down-trend ⇒ long 1 / short 2
    Rtr = hcat(0.004 .+ 0.001 .* randn(400), -0.004 .+ 0.001 .* randn(400), 0.001 .* randn(400))
    _, sttr = walk_spine(Rtr)
    @test sttr.trend_w[1] > 0
    @test sttr.trend_w[2] < 0
end

@testset "spine_targets — weights to signed shares" begin
    t = spine_targets([0.5, -0.25], ["A", "B"], [10.0, 20.0], 1000.0)
    @test t["A"] ≈ 50.0                               # 0.5·1000/10
    @test t["B"] ≈ -12.5                              # short: -0.25·1000/20
end

@testset "regime_multiplier + regime overlay (d-5)" begin
    W = randn(260, 3) .* 0.01
    @test regime_multiplier(W, :none) == 1.0          # baseline identity
    for k in (:vol, :trend, :both, :dd)               # every regime bounded in (0,1]
        m = regime_multiplier(W, k); @test 0.0 < m <= 1.0
    end
    rising = fill(0.003, 260, 3)                       # market at its peak ⇒ no cut
    drawn  = vcat(fill(0.003, 200, 3), fill(-0.005, 60, 3))  # ~26% below peak ⇒ cut
    @test regime_multiplier(rising, :dd) == 1.0
    @test regime_multiplier(drawn, :dd) < 1.0

    # applied inside spine_step!: :dd de-risks the (long-only) book in a drawdown vs :none
    Rdd = vcat(fill(0.002, 160, 2), fill(-0.008, 120, 2))
    wn,  _ = walk_spine(Rdd; regime = :none, base_weight = 1.0)
    wdd, _ = walk_spine(Rdd; regime = :dd,   base_weight = 1.0)
    @test sum(abs, wdd) < sum(abs, wn)
end

end # module
