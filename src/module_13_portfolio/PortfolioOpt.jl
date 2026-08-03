# =============================================================================
# PortfolioOpt.jl — a compact, dependency-light portfolio construction toolkit
#
# Layout (one file per domain, mirroring the workflow):
#   moments.jl        return transforms + mean/covariance estimation
#   meanvariance.jl   Markowitz family (min-var, max-Sharpe, frontier)
#   riskbased.jl      max-diversification, risk parity, HRP
#   tailrisk.jl       mean-CVaR and mean-CDaR linear programs
#   blacklitterman.jl equilibrium returns + posterior view blending
#   metrics.jl        Sharpe/Sortino/drawdown/VaR/CVaR diagnostics
#   backtest.jl       walk-forward rebalanced backtester
#
# Convention: return matrices are T x N (time x assets); weights sum to 1.
# Convex programs use JuMP + Clarabel by default; every solver call accepts an
# `optimizer` keyword so you can swap in HiGHS, COSMO, Ipopt, etc.
# =============================================================================

module PortfolioOpt

using LinearAlgebra
using Statistics
using StatsBase: skewness, kurtosis, corkendall
using Distributions: Normal, quantile, MvNormal, Dirichlet, MvTDist, TDist, Chisq, cdf
using JuMP
using Clarabel
using Clustering: hclust

# ---- moments ----------------------------------------------------------------
include("moments.jl")
export simple_returns, log_returns, mean_returns,
       sample_cov, ewma_cov, shrinkage_cov, cov2cor, nearest_psd

# ---- mean-variance ----------------------------------------------------------
include("meanvariance.jl")
export min_variance, max_sharpe, mean_variance, efficient_frontier

# ---- risk-based -------------------------------------------------------------
include("riskbased.jl")
export max_diversification, risk_contributions, risk_parity,
       hrp_weights, inverse_variance

# ---- tail risk --------------------------------------------------------------
include("tailrisk.jl")
export min_cvar, min_cdar

# ---- Black–Litterman --------------------------------------------------------
include("blacklitterman.jl")
export implied_equilibrium_returns, black_litterman, make_view

# ---- metrics ----------------------------------------------------------------
include("metrics.jl")
export ann_return, ann_vol, sharpe, sortino, drawdown_series, max_drawdown,
       calmar, value_at_risk, expected_shortfall, summary_stats

# ---- benchmark-relative analytics -------------------------------------------
include("benchmark.jl")
export capm_alpha_beta, tracking_error, information_ratio, treynor_ratio,
       omega_ratio, brinson_attribution

# ---- cost-aware optimization ------------------------------------------------
include("costaware.jl")
export turnover, transaction_cost, mean_variance_tc

# ---- robust / resampling ----------------------------------------------------
include("robust.jl")
export random_portfolios, resampled_frontier,
       gaussian_dgp, iid_bootstrap, block_bootstrap, stationary_bootstrap,
       student_t_dgp, t_copula_dgp

# ---- backtest ---------------------------------------------------------------
include("backtest.jl")
export backtest, equal_weight

# ---- spine (validated Path-B strategy) --------------------------------------
include("spine.jl")
export tsmom_signal, tsmom_signal_multi, tsmom_weights, voltarget_exposure, spine_weights, spine_strategy,
       SpineState, spine_step!, spine_targets, regime_multiplier,
       SplitSpineState, split_spine_step!, split_indices

end # module
