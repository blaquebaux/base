# BlaqueBaux Gamma-ARMA Framework

![Julia](https://img.shields.io/badge/Julia-1.9+-9558B2?logo=julia&logoColor=white)
![License](https://img.shields.io/badge/License-Proprietary-red)

A production-grade Julia implementation of the Gamma-ARMA framework for regime-switching volatility modeling, systematic trading strategy blending, and real-time execution.

## Architecture

The system is organized into **8 independent modules** that can be developed, tested, and deployed separately:

```
BlaqueBaux/
├── src/
│   ├── BlaqueBaux.jl              # Main module (re-exports all)
│   ├── module_1_data/             # Data ingestion & normalization
│   ├── module_2_smoothing/        # Signal smoothing pipeline
│   ├── module_3_pca/              # PCA compression → 6-dim state
│   ├── module_4_arma/             # ARMA + GARCH estimation
│   ├── module_5_dpm/              # Dirichlet Process Mixture
│   ├── module_6_cascade/          # Cascade interface & sizing
│   ├── module_7_execution/        # IBKR execution & breakers
│   └── module_8_governance/       # PMO metrics & rollback
├── test/                          # Unit tests per module
├── scripts/
│   ├── run_em_weekly.jl           # Weekly EM estimation
│   ├── run_daily_recursive.jl     # Daily recursive update
│   └── backtest_validation.jl     # Walk-forward validation
└── Project.toml
```

## Module Overview

| Module | Purpose | Key Dependencies |
|--------|---------|------------------|
| **1. DataIngestion** | Fetch, normalize, staleness detection | HTTP, JSON3, CSV, TimeZones |
| **2. SignalSmoothing** | LOWESS, SG, adaptive median, bootstrap | Loess, DSP, Statistics |
| **3. PCACompression** | Vol surface PCA + yield curve factors | MultivariateStats, LinearAlgebra |
| **4. ARMAGARCH** | ARMA(p,q) + GARCH(1,1) QMLE | Distributions, Optim, TimeSeries |
| **5. DPM** | Stick-breaking, particle filter, EM | Distributions, SpecialFunctions |
| **6. CascadeInterface** | Strategy blending, position sizing | — |
| **7. ExecutionLayer** | IBKR orders, circuit breakers | Sockets, Logging |
| **8. Governance** | Version registry, rollback, PMO | SQLite, Statistics |

## Installation

```bash
git clone <repository>
cd BlaqueBaux
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Usage

### Daily Recursive Update (Production)
```julia
using BlaqueBaux

# Run after market close (4:30 PM ET)
run_daily_recursive()
```

### Weekly EM Estimation (Research)
```julia
# Run every Friday after close
run_weekly_em()
```

### Backtest Validation
```julia
# Run before deployment
results = run_backtest_validation()
# Returns: Dict("T1" => true, "T2" => true, ...)
```

### Module-Level Usage
```julia
using BlaqueBaux.DataIngestion, BlaqueBaux.ARMAGARCH

# Fetch market state
dt = now(tz"America/New_York")
state = DataIngestion.assemble_market_state(dt)

# Estimate ARMA-GARCH
spec = ARMASpec(1, 1)
arma, garch, ll = estimate_armagarch(returns, spec; use_garch=true)
```

## Testing

```bash
# Run all tests
julia --project=. test/runtests.jl

# Run specific module tests
julia --project=. test/test_module_4.jl  # ARMA+GARCH
```

## Development Phases

| Phase | Module(s) | Week | Deliverable |
|-------|-----------|------|-------------|
| 1A | Module 1, 2 | 2 | Data ingestion + smoothing |
| 1B | Module 3 | 3 | PCA → 6-dim state vector |
| 2A | Module 4 | 5 | ARMA + GARCH estimation |
| 2B | Module 5 (E-step) | 7 | EM initialization |
| 2C | Module 5 (DPM) | 9 | Full DPM with γ |
| 3A | Module 6 | 11 | Cascade + risk_engine replacement |
| 3B | Module 8 | 12 | Version registry + PMO dashboard |
| 3C | Module 7 | 13 | IBKR execution + circuit breakers |

## Key Design Decisions

1. **Modularity**: Each module is self-contained with explicit exports
2. **Type Safety**: Heavy use of Julia structs for configuration and state
3. **Regime-Aware**: Smoothing windows adapt to VIX/VXV regime
4. **Defensive Programming**: Extensive input validation and NaN handling
5. **Production-Ready**: Circuit breakers, position floors, rollback logic

## License

Proprietary - SmallClaw Consultancy

## Contact

For questions or issues, contact the PMO or raise an escalation via `Governance.check_escalation_threshold()`.
