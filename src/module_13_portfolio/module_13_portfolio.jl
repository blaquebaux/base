module PortfolioOptModule

"""
BlaqueBaux Module 13 — Portfolio Optimization
Wraps PortfolioOpt.jl (Markowitz, Risk-Parity, HRP, CVaR, Black-Litterman,
Robust/Resampled frontier, Cost-aware, Benchmark analytics, Walk-forward backtest).
"""

include("PortfolioOpt.jl")
using .PortfolioOpt

export PortfolioOpt

# Re-export everything from PortfolioOpt for convenience
export simple_returns, log_returns, mean_returns,
       sample_cov, ewma_cov, shrinkage_cov, cov2cor, nearest_psd,
       min_variance, max_sharpe, mean_variance, efficient_frontier,
       max_diversification, risk_contributions, risk_parity,
       hrp_weights, inverse_variance,
       min_cvar, min_cdar,
       implied_equilibrium_returns, black_litterman, make_view,
       ann_return, ann_vol, sharpe, sortino, drawdown_series, max_drawdown,
       calmar, value_at_risk, expected_shortfall, summary_stats,
       capm_alpha_beta, tracking_error, information_ratio, treynor_ratio,
       omega_ratio, brinson_attribution,
       turnover, transaction_cost, mean_variance_tc,
       random_portfolios, resampled_frontier,
       gaussian_dgp, iid_bootstrap, block_bootstrap, stationary_bootstrap,
       student_t_dgp, t_copula_dgp,
       backtest, equal_weight,
       tsmom_signal, tsmom_signal_multi, tsmom_weights, voltarget_exposure, spine_weights, spine_strategy,
       SpineState, spine_step!, spine_targets, regime_multiplier,
       SplitSpineState, split_spine_step!, split_indices

end # module PortfolioOptModule
