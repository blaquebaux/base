module TestEquityPanel

# Unit tests for the spine's data adapter (src/module_1_data/equity_panel.jl): CSV loading,
# causal windowing, and the panel contract the spine consumes. Uses a small temp CSV — no
# network, no fixture dependency.

using Test, Dates

include("../src/module_1_data/equity_panel.jl")
using .EquityPanel

@testset "CSVPanelProvider + panel_at" begin
    tmp = joinpath(mktempdir(), "px.csv")
    open(tmp, "w") do io
        println(io, "date,AAA,BBB")
        for (k, d) in enumerate(Date(2020,1,1):Day(1):Date(2020,1,10))
            println(io, "$d,$(100 + k),$(200 + 2k)")     # AAA: 101..110, BBB: 202..220
        end
    end
    p = CSVPanelProvider(tmp; lookback = 3)
    @test p.symbols == ["AAA", "BBB"]
    @test length(p.dates) == 10

    # Only dates with a full 3-return lookback are available (need 4 bars: rows 4..10).
    @test available_dates(p) == collect(Date(2020,1,4):Day(1):Date(2020,1,10))

    panel = panel_at(p, Date(2020,1,10))
    @test panel.symbols == ["AAA", "BBB"]
    @test size(panel.returns) == (3, 2)                  # lookback returns × N assets
    @test panel.prices == [110.0, 220.0]                 # closes at asof
    @test panel.asof == Date(2020,1,10)
    # last return row = the bar at asof: AAA 109→110, BBB 218→220
    @test panel.returns[end, 1] ≈ 110/109 - 1
    @test panel.returns[end, 2] ≈ 220/218 - 1

    # As-of a mid date is causal (uses the bar on/before, not future data).
    pm = panel_at(p, Date(2020,1,6))
    @test pm.asof == Date(2020,1,6)
    @test pm.prices == [106.0, 212.0]

    # Insufficient history errors rather than peeking.
    @test_throws ErrorException panel_at(p, Date(2020,1,3))
end

end # module
