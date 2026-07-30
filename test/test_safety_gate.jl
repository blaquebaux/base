module TestSafetyGate

# Unit tests for the Layer-3 live-money safety gate (src/module_8_governance/safety_gate.jl).
# Exhaustively exercises the decision logic — every guard must trip on its scenario and the
# all-clear case must pass. No network. This is the confidence backbone for real-money trading.

using Test, Dates

include("../src/module_8_governance/safety_gate.jl")
using .SafetyGate

# A known-good baseline set of preflight inputs; each test perturbs ONE thing.
ok_args() = (; account_status = "ACTIVE", trading_blocked = false, account_blocked = false,
             equity = 100_000.0, hwm = 100_000.0, last_equity = 100_000.0, buying_power = 100_000.0,
             data_fresh = true, targets = Dict("SPY" => 30.0, "IEF" => 700.0),
             prices = Dict("SPY" => 680.0, "IEF" => 95.0), limits = SafetyLimits())

@testset "drawdown" begin
    @test drawdown(90.0, 100.0) ≈ -0.10
    @test drawdown(110.0, 100.0) ≈ 0.10
    @test drawdown(100.0, -Inf) == 0.0        # no HWM yet → no drawdown
    @test drawdown(100.0, 0.0) == 0.0
end

@testset "kill switch + HWM persistence" begin
    d = mktempdir()
    kp = joinpath(d, "HALT"); hp = joinpath(d, "hwm.txt")
    @test kill_switch_active(kp) == false
    write(kp, ""); @test kill_switch_active(kp) == true
    @test load_hwm(hp) == -Inf               # none yet
    save_hwm(123456.0, hp); @test load_hwm(hp) ≈ 123456.0
end

@testset "preflight — all clear" begin
    ok, reasons = preflight(; ok_args()...)
    @test ok == true
    @test isempty(reasons)
end

@testset "preflight — each guard trips" begin
    # account not active
    @test preflight(; ok_args()..., account_status = "ONBOARDING")[1] == false
    @test preflight(; ok_args()..., trading_blocked = true)[1] == false
    @test preflight(; ok_args()..., account_blocked = true)[1] == false
    # stale data
    @test preflight(; ok_args()..., data_fresh = false)[1] == false
    # equity / buying power
    @test preflight(; ok_args()..., equity = 0.0)[1] == false
    @test preflight(; ok_args()..., buying_power = 10.0)[1] == false
    # drawdown breach: equity 80k vs hwm 100k = -20% > 15% limit
    @test preflight(; ok_args()..., equity = 80_000.0, hwm = 100_000.0)[1] == false
    # daily loss breach: equity 97k vs last 100k = -3k > 2k limit
    @test preflight(; ok_args()..., equity = 97_000.0, last_equity = 100_000.0)[1] == false
    # gross leverage breach: huge position
    @test preflight(; ok_args()..., targets = Dict("SPY" => 1000.0),
                    prices = Dict("SPY" => 680.0))[1] == false   # 680k / 100k = 6.8x
    # per-name breach: one name > 85% of equity (130 SPY * 680 = 88.4k = 88% > 85% cap)
    @test preflight(; ok_args()..., targets = Dict("SPY" => 130.0), prices = Dict("SPY" => 680.0),
                    limits = SafetyLimits(max_gross_leverage = 10.0))[1] == false
    # bad price
    @test preflight(; ok_args()..., prices = Dict("SPY" => 0.0, "IEF" => 95.0))[1] == false
    @test preflight(; ok_args()..., prices = Dict("SPY" => NaN, "IEF" => 95.0))[1] == false
    # too many orders
    big = Dict("S$i" => 1.0 for i in 1:60); bigpx = Dict("S$i" => 1.0 for i in 1:60)
    @test preflight(; ok_args()..., targets = big, prices = bigpx)[1] == false
    # kill switch (temp path that exists)
    d = mktempdir(); kp = joinpath(d, "HALT"); write(kp, "")
    @test preflight(; ok_args()..., kill_path = kp)[1] == false
end

@testset "preflight — reasons are complete (all failures listed)" begin
    ok, reasons = preflight(; ok_args()..., account_status = "X", data_fresh = false, buying_power = 0.0)
    @test ok == false
    @test length(reasons) >= 3                # not short-circuited at the first failure
end

@testset "alert never throws" begin
    d = mktempdir()
    @test alert("test message"; log_path = joinpath(d, "alerts.log"), notify = false) === nothing
    @test occursin("test message", read(joinpath(d, "alerts.log"), String))
end

end # module
