module BlaqueBaux

"""
BlaqueBaux Gamma-ARMA Framework

A modular Julia implementation of the Gamma-ARMA framework for
regime-switching volatility modeling and systematic trading.

## Modules
- `DataIngestion`: Market data fetching and normalization
- `SignalSmoothing`: LOWESS, Savitzky-Golay, adaptive median, bootstrap
- `PCACompression`: Volatility surface PCA + yield curve factor extraction
- `ARMAGARCH`: ARMA(p,q) + GARCH(1,1) joint QMLE estimation
- `DPM`: Dirichlet Process Mixture with Gamma hyperprior
- `CascadeInterface`: Strategy blending and position sizing
- `ExecutionLayer`: IBKR order routing and circuit breakers
- `Governance`: Version registry, rollback, PMO metrics
- `ZeroDTE`: 0DTE options overlay — Greeks screening, Theta Load sizing, ORB+IV quadrant matrix
- `FeedbackLayer`: Circular cascade gap fix — ExecutionLedger, exogenous return partitioning, impact residualization
- `CVLayer`: Purged K-Fold + CPCV cross-validation (López de Prado, AFML Ch. 7)
- `SORLayer`: GPU-backed Smart Order Router — cuOpt venue allocation, routing cache
- `PortfolioOptModule`: Portfolio optimization — Markowitz, Risk-Parity, HRP, CVaR, Black-Litterman, Robust/Resampled frontier, Cost-aware, Walk-forward backtest

## Usage
```julia
using BlaqueBaux

# Daily recursive update
run_daily_recursive()

# Weekly EM estimation
run_weekly_em()

# Backtest validation
run_backtest_validation()
```
"""

# Re-export all submodules
include("module_1_data/module_1_data.jl")
include("module_2_smoothing/module_2_smoothing.jl")
include("module_3_pca/module_3_pca.jl")
include("module_4_arma/module_4_arma.jl")
include("module_5_dpm/module_5_dpm.jl")
include("module_6_cascade/module_6_cascade.jl")
include("module_7_execution/module_7_execution.jl")
include("module_8_governance/module_8_governance.jl")
include("module_9_0dte/module_9_0dte.jl")
include("module_10_feedback/module_10_feedback.jl")
include("module_11_cv/module_11_cv.jl")
include("module_12_sor/module_12_sor.jl")
include("module_13_portfolio/module_13_portfolio.jl")

using .DataIngestion
using .SignalSmoothing
using .PCACompression
using .ARMAGARCH
using .DPM
using .CascadeInterface
using .ExecutionLayer
using .Governance
using .ZeroDTE
using .FeedbackLayer
using .CVLayer
using .SORLayer
using .PortfolioOptModule

# Export all public APIs
export DataIngestion, SignalSmoothing, PCACompression, ARMAGARCH, DPM
export CascadeInterface, ExecutionLayer, Governance, ZeroDTE, FeedbackLayer
export CVLayer, SORLayer, PortfolioOptModule

# Convenience functions for orchestration
export run_weekly_em, run_daily_recursive, run_backtest_validation

"""
    run_weekly_em()

Execute weekly EM estimation pipeline. See `scripts/run_em_weekly.jl`.
"""
function run_weekly_em()
    include("../scripts/run_em_weekly.jl")
end

"""
    run_daily_recursive()

Execute daily recursive update. See `scripts/run_daily_recursive.jl`.
"""
function run_daily_recursive()
    include("../scripts/run_daily_recursive.jl")
end

"""
    run_backtest_validation()

Execute walk-forward validation. See `scripts/backtest_validation.jl`.
"""
function run_backtest_validation()
    include("../scripts/backtest_validation.jl")
end

end  # module BlaqueBaux
