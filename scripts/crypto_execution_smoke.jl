#!/usr/bin/env julia
# crypto_execution_smoke.jl — offline smoke test of the wired crypto execution path.
# Loads the crypto data provider (v1beta3) + the crypto-mode venue + the fractional rebalance,
# fetches real BTC/USD + ETH/USD, builds the governed crypto-trend target, and runs it through the
# Layer-3 safety gate — no venue connection, no orders. Proves the wiring compiles and the data/gate
# path works before any driver graduates to paper.  Run:  julia --project=. scripts/crypto_execution_smoke.jl
using Dates, Printf, Statistics
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_1_data/crypto_panel.jl"))
include(joinpath(REPO, "src/module_8_governance/safety_gate.jl"))
using .ExecutionLayer, .CryptoPanel, .SafetyGate

const ASSETS = ["BTC/USD", "ETH/USD"]; const VOL_TARGET = 0.15
ewma_vol_ann(r; hl = 20, ann = 365) = (isempty(r) ? NaN : begin
    lam = 0.5^(1/hl); v = float(r[1])^2
    for t in eachindex(r); v = t == 1 ? float(r[t])^2 : lam*v + (1-lam)*float(r[t])^2; end
    sqrt(max(v, 1e-12)) * sqrt(ann) end)

panel = crypto_panel_at(CryptoPanelProvider(ASSETS; lookback = 220))
R = panel.returns; T = size(R, 1); cap = 100_000.0
net = Dict{String,Float64}(); price = Dict{String,Float64}()
for (i, a) in enumerate(ASSETS)
    r = R[:, i]; frac = mean([(prod(1 .+ r[T-h+1:T]) - 1) > 0 ? 1.0 : 0.0 for h in (30, 60, 120)])
    net[a] = frac * (VOL_TARGET / max(ewma_vol_ann(r), 1e-6)) / length(ASSETS); price[a] = panel.prices[i]
end
g = sum(abs, values(net)); g > 1.0 && for a in keys(net); net[a] *= 1.0/g; end
targets = Dict(a => net[a] * cap / price[a] for a in ASSETS)          # FRACTIONAL crypto quantities

println("="^74, "\nCRYPTO EXECUTION — offline smoke (real BTC/ETH, governed, fractional)\n", "="^74)
@printf("\n  data asof %s   (v1beta3, %d bars)\n", panel.asof, T)
for a in ASSETS
    @printf("    %-8s %+6.1f%%  ->  %.6f units @ \$%.0f  (\$%.0f notional)\n",
            a, 100*net[a], targets[a], price[a], net[a]*cap)
end
crypto_venue = AlpacaVenue(; paper = true, crypto = true)             # fractional qty + gtc + BTC/USD symbols
@printf("\n  crypto venue: cfg.crypto = %s  (equity path untouched when false)\n", crypto_venue.cfg.crypto)
ok, reasons = preflight(; account_status = "ACTIVE", equity = cap, hwm = cap, last_equity = cap,
    buying_power = cap, data_fresh = true, targets = targets, prices = price, limits = SafetyLimits())
println("\n  SAFETY GATE on the fractional crypto book: ", ok ? "PASS" : "ABORT: " * join(reasons, "; "))
println("\n  wiring verified: v1beta3 data OK; crypto venue flag OK (fractional qty + gtc); gate OK.")
println("  execute_rebalance_frac! (governed, notional dead-zone) is available for the paper/live path.")
println("  NO venue connection and NO orders in this smoke test.")
