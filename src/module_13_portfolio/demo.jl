# =============================================================================
# examples/demo.jl — end-to-end walkthrough on synthetic data
#
# Run from the package root:
#   julia --project=. examples/demo.jl
# (After the first run, instantiate deps once: `julia --project=. -e
#  'using Pkg; Pkg.instantiate()'`.)
# =============================================================================

using Random, LinearAlgebra, Statistics
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
using PortfolioOpt

Random.seed!(42)

# --- build a synthetic universe of N assets over T days ----------------------
const N = 8
const T = 1000

# a plausible factor structure: one market factor + idiosyncratic noise
beta   = 0.6 .+ 0.8 .* rand(N)                       # market betas
mkt    = 0.0003 .+ 0.01 .* randn(T)                  # market factor returns
idio_σ = 0.004 .+ 0.01 .* rand(N)                    # idiosyncratic vols
drift  = 0.0001 .+ 0.0004 .* rand(N)                 # small per-asset drift

R = zeros(T, N)
for j in 1:N
    R[:, j] = drift[j] .+ beta[j] .* mkt .+ idio_σ[j] .* randn(T)
end

println("Universe: $N assets, $T daily observations\n")

# --- moment estimation -------------------------------------------------------
μ = mean_returns(R)                                  # daily mean returns
Σ_sample = sample_cov(R)
Σ_lw, δ  = shrinkage_cov(R)                           # Ledoit–Wolf constant-corr
Σ_ewma   = ewma_cov(R; halflife = 60)

println("Ledoit–Wolf shrinkage intensity δ = ", round(δ; digits = 3))
println("Sample-cov condition number       = ", round(cond(Matrix(Σ_sample)); digits = 1))
println("Shrunk-cov condition number       = ", round(cond(Matrix(Σ_lw)); digits = 1), "\n")

# use the shrunk covariance everywhere downstream
Σ = Σ_lw

# --- the optimizer zoo -------------------------------------------------------
ports = Dict(
    "Equal weight"        => fill(1 / N, N),
    "Min variance"        => min_variance(Σ),
    "Max Sharpe"          => max_sharpe(μ, Σ; rf = 0.0),
    "Max diversification" => max_diversification(Σ),
    "Risk parity (ERC)"   => risk_parity(Σ),
    "HRP"                 => hrp_weights(Σ),
    "Min CVaR (95%)"      => min_cvar(R; α = 0.95),
    "Min CDaR (95%)"      => min_cdar(R; α = 0.95),
)

println("Portfolio weights")
println("-"^72)
for name in ["Equal weight", "Min variance", "Max Sharpe", "Max diversification",
             "Risk parity (ERC)", "HRP", "Min CVaR (95%)", "Min CDaR (95%)"]
    w = ports[name]
    println(rpad(name, 22), join(lpad(string(round(wi; digits = 3)), 7) for wi in w))
end
println()

# confirm risk parity really equalizes risk contributions
rc = risk_contributions(ports["Risk parity (ERC)"], Σ)
println("Risk-parity risk shares: ", round.(rc ./ sum(rc); digits = 3), "\n")

# --- efficient frontier ------------------------------------------------------
ef = efficient_frontier(μ, Σ; n = 6)
println("Efficient frontier (annualized):")
for k in eachindex(ef.returns)
    println("  target ret ", rpad(round(ef.returns[k] * 252; digits = 3), 7),
            "  vol ", round(ef.risks[k] * sqrt(252); digits = 3))
end
println()

# --- Black–Litterman ---------------------------------------------------------
w_mkt = fill(1 / N, N)                                # stand-in for cap weights
Π = implied_equilibrium_returns(Σ, w_mkt; δ = 2.5)
# View 1: asset 1 outperforms asset 2 by 5% annualized (~0.0002/day)
p1, q1 = make_view(N, [1, 2], 0.05 / 252; weights = [1.0, -1.0])
# View 2: asset 5 returns 8% annualized
p2, q2 = make_view(N, [5], 0.08 / 252)
P = permutedims(hcat(p1, p2))                        # 2 x N
Q = [q1, q2]
μ_bl, Σ_bl = black_litterman(Σ, Π, P, Q; τ = 0.05)
w_bl = mean_variance(μ_bl, Σ; risk_aversion = 2.5)
println("Black–Litterman weights: ", round.(w_bl; digits = 3), "\n")

# --- walk-forward backtest ---------------------------------------------------
# strategy closures take a trailing window and return weights
strat_rp  = win -> risk_parity(shrinkage_cov(win)[1])
strat_hrp = win -> hrp_weights(shrinkage_cov(win)[1])
strat_mv  = win -> min_variance(shrinkage_cov(win)[1])

println("Backtest (lookback 252d, monthly rebalance, 5bps cost)")
println("-"^72)
for (label, strat) in [("1/N", equal_weight), ("Min-var", strat_mv),
                       ("Risk parity", strat_rp), ("HRP", strat_hrp)]
    bt = backtest(R, strat; lookback = 252, rebalance = 21, cost_bps = 5.0)
    s  = summary_stats(bt.returns; ppy = 252)
    println(rpad(label, 13),
            " ann_ret ", rpad(round(s.ann_return; digits = 3), 7),
            " vol ",     rpad(round(s.ann_vol; digits = 3), 6),
            " sharpe ",  rpad(round(s.sharpe; digits = 2), 6),
            " maxDD ",   rpad(round(s.max_dd; digits = 3), 7),
            " CVaR ",    round(s.cvar; digits = 4))
end
println()

# --- benchmark-relative analytics --------------------------------------------
# use the equal-weight portfolio as a stand-in benchmark
bench = vec(mean(R, dims = 2))
bt_rp = backtest(R, strat_rp; lookback = 252, rebalance = 21, cost_bps = 5.0)
b     = bench[bt_rp.dates]                            # align benchmark to OOS span
cm    = capm_alpha_beta(bt_rp.returns, b)
println("Risk-parity vs equal-weight benchmark:")
println("  alpha (ann) ", round(cm.alpha; digits = 4),
        "   beta ", round(cm.beta; digits = 3),
        "   R² ", round(cm.r2; digits = 3))
println("  tracking error ", round(tracking_error(bt_rp.returns, b); digits = 4),
        "   IR ", round(information_ratio(bt_rp.returns, b); digits = 3),
        "   Omega ", round(omega_ratio(bt_rp.returns .- b); digits = 3))

# segment (sector) attribution, single period
wp = [0.4, 0.35, 0.25]; wb = [0.34, 0.33, 0.33]       # port vs benchmark sector wts
rp = [0.02, 0.01, -0.005]; rb = [0.015, 0.012, 0.0]   # sector returns
attr = brinson_attribution(wp, wb, rp, rb)
println("  Brinson: allocation ", round(attr.total_allocation; digits = 4),
        " selection ", round(attr.total_selection; digits = 4),
        " interaction ", round(attr.total_interaction; digits = 4),
        " = active ", round(attr.active_return; digits = 4), "\n")

# --- cost-aware rebalance ----------------------------------------------------
w0 = fill(1 / N, N)                                   # currently equal-weight
w_free = mean_variance(μ, Σ; risk_aversion = 2.5)
w_tc   = mean_variance_tc(μ, Σ, w0; risk_aversion = 2.5,
                          linear_cost = 0.0010, max_turnover = 0.40)
println("Cost-aware rebalance from equal weight (10bps cost, 40% turnover cap):")
println("  cost-free turnover ", round(turnover(w_free, w0); digits = 3),
        "   cost-aware turnover ", round(turnover(w_tc, w0); digits = 3))
println("  realized cost: free ",
        round(transaction_cost(w_free, w0; linear_cost = 0.0010); digits = 5),
        "  vs aware ",
        round(transaction_cost(w_tc, w0; linear_cost = 0.0010); digits = 5), "\n")

# wiring cost-awareness into the backtest via a 2-arg (stateful) strategy
strat_tc = (win, w0) -> begin
    μw, Σw = mean_returns(win), shrinkage_cov(win)[1]
    mean_variance_tc(μw, Σw, w0; risk_aversion = 3.0, linear_cost = 0.0010,
                     max_turnover = 0.30)
end
bt_tc = backtest(R, strat_tc; lookback = 252, rebalance = 21, cost_bps = 10.0)
println("Cost-aware backtest: sharpe ",
        round(sharpe(bt_tc.returns; ppy = 252); digits = 2),
        "   mean turnover/rebal ", round(mean(bt_tc.turnover); digits = 3), "\n")

# --- resampled (Michaud) frontier, Gaussian vs fat-tailed DGP ----------------
# small settings keep this quick; raise n_resample for production use
ef_curve = efficient_frontier(μ, Σ; n = 6)
rf_gauss = resampled_frontier(R; n_resample = 20, n_points = 6, sampler = gaussian_dgp())
rf_block = resampled_frontier(R; n_resample = 20, n_points = 6,
                              sampler = block_bootstrap(block = 21))
rf_tcop  = resampled_frontier(R; n_resample = 20, n_points = 6,
                              sampler = t_copula_dgp(ν = 4.0))

println("Frontier comparison (annualized vol at each rank):")
println("  classic            ", round.(ef_curve.risks .* sqrt(252); digits = 3))
println("  resampled Gaussian ", round.(rf_gauss.risks .* sqrt(252); digits = 3))
println("  resampled block    ", round.(rf_block.risks .* sqrt(252); digits = 3))
println("  resampled t-copula ", round.(rf_tcop.risks  .* sqrt(252); digits = 3))
println("\nHistorical CVaR (95%) of the averaged weights at each rank:")
println("  resampled Gaussian ", round.(rf_gauss.cvars; digits = 4))
println("  resampled t-copula ", round.(rf_tcop.cvars;  digits = 4))
println("(swap in student_t_dgp / stationary_bootstrap / iid_bootstrap as needed;",
        " on this Gaussian-simulated\n data the DGPs nearly agree — the gap widens on real fat-tailed series)")
