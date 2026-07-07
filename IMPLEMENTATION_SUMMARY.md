# BlaqueBaux Gamma-ARMA Framework - Complete Implementation

## Project Statistics

| Metric | Value |
|--------|-------|
| **Total Files** | 35 |
| **Source Code** | 8 modules (110 KB) |
| **Test Code** | 10 files (114 KB) |
| **Scripts** | 3 orchestration scripts (18 KB) |
| **Total Size** | ~242 KB |
| **Test Cases** | ~650+ |
| **Test Sets** | ~280+ |

## File Inventory

### Source Modules (src/)
| File | Size | Description |
|------|------|-------------|
| `BlaqueBaux.jl` | 2.3 KB | Main module re-exporting all |
| `module_1_data/module_1_data.jl` | 15.5 KB | Data ingestion & normalization |
| `module_2_smoothing/module_2_smoothing.jl` | 15.9 KB | Signal smoothing pipeline |
| `module_3_pca/module_3_pca.jl` | 10.1 KB | PCA compression |
| `module_4_arma/module_4_arma.jl` | 13.9 KB | ARMA + GARCH estimation |
| `module_5_dpm/module_5_dpm.jl` | 18.5 KB | Dirichlet Process Mixture |
| `module_6_cascade/module_6_cascade.jl` | 10.5 KB | Cascade interface |
| `module_7_execution/module_7_execution.jl` | 10.6 KB | Execution layer |
| `module_8_governance/module_8_governance.jl` | 13.0 KB | Governance |

### Test Suite (test/)
| File | Size | Test Cases | Test Sets |
|------|------|------------|-----------|
| `test_module_1.jl` | 12.0 KB | ~93 | 33 |
| `test_module_2.jl` | 12.8 KB | ~62 | 40 |
| `test_module_3.jl` | 12.7 KB | ~51 | 25 |
| `test_module_4.jl` | 15.4 KB | ~97 | 46 |
| `test_module_5.jl` | 14.6 KB | ~83 | 36 |
| `test_module_6.jl` | 13.9 KB | ~97 | 37 |
| `test_module_7.jl` | 13.4 KB | ~87 | 33 |
| `test_module_8.jl` | 16.8 KB | ~81 | 35 |
| `runtests.jl` | 1.8 KB | — | — |
| `TEST_COVERAGE.md` | 8.9 KB | — | — |

### Scripts (scripts/)
| File | Size | Purpose |
|------|------|---------|
| `run_em_weekly.jl` | 5.4 KB | Weekly EM estimation |
| `run_daily_recursive.jl` | 6.4 KB | Daily recursive update |
| `backtest_validation.jl` | 6.4 KB | Walk-forward validation |

### Configuration
| File | Size |
|------|------|
| `Project.toml` | 1.5 KB |
| `README.md` | 4.3 KB |
| `.gitignore` | 184 B |

## Key Features Implemented

### Module 1: Data Ingestion
- ✅ 9 data feed types (VIX, VXV, VVIX, VIX1D, IV Rank, GSW, OIS/SOFR, TGA)
- ✅ Staleness detection with configurable thresholds
- ✅ VIX1D fallback for pre-2022 data
- ✅ Normalization: log-zscore VIX, clip IV rank, normalize VIX/VXV ratio
- ✅ MarketState assembly with derived metrics

### Module 2: Signal Smoothing
- ✅ LOWESS with robust iterations (3-5)
- ✅ Savitzky-Golay with boundary handling
- ✅ Adaptive rolling median (calm: 60d, stress: 10d, transition: 30d)
- ✅ Stationary block bootstrap (B=5000, geometric block lengths)
- ✅ Gibbs artifact detection (>5σ threshold)
- ✅ Combined 4-stage pipeline

### Module 3: PCA Compression
- ✅ Volatility surface PCA (3 components)
- ✅ Litterman-Scheinkman yield curve factors
- ✅ 6-dimensional state vector assembly
- ✅ VIX1D availability handling

### Module 4: ARMA + GARCH
- ✅ ARMA(p,q) for p,q ∈ {0,1,2}
- ✅ Joint QMLE via Optim.jl
- ✅ GARCH(1,1) with jump coefficient
- ✅ Rolling realized volatility (10-day)
- ✅ Tail index from vol scale (clipped [1.5, 4.0])
- ✅ t-distribution DoF from tail index

### Module 5: DPM
- ✅ Stick-breaking representation (truncation: 20-50)
- ✅ Particle filter E-step (1000-5000 particles)
- ✅ M-step weighted parameter update
- ✅ Escobar-West concentration update
- ✅ Full EM with convergence detection
- ✅ Recursive Bayesian update (ρ=0.99)
- ✅ Crisis regime detection (3 of 4 criteria)

### Module 6: Cascade Interface
- ✅ Regime probability blending (Fixed/Growth/Floating)
- ✅ Strategy weights: trend, mean-reversion, momentum, defensive
- ✅ Position sizing with parallel pools ($10K each)
- ✅ Global risk-off adjustment
- ✅ GammaARMAOutput for risk engine

### Module 7: Execution Layer
- ✅ IBKR order structure (LIMIT/MARKET)
- ✅ 4-state circuit breaker (NORMAL, WATCH, LIQUIDATION, COOLDOWN)
- ✅ Emergency liquidation triggers (VVIX>120, VIX>40, bootstrap 3x)
- ✅ 30-minute cooldown post-liquidation
- ✅ $500 position floor
- ✅ Latency metrics

### Module 8: Governance
- ✅ SQLite version registry
- ✅ Automatic rollback (MAE degradation >20%)
- ✅ Walk-forward validation gates (T1-T4)
- ✅ PMO metrics (classification accuracy, bootstrap coverage, MSE)
- ✅ Human escalation (3 consecutive failures)

## Usage

```bash
# Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run tests
julia --project=. test/runtests.jl

# Daily operation
julia --project=. scripts/run_daily_recursive.jl

# Weekly research
julia --project=. scripts/run_em_weekly.jl

# Pre-deployment validation
julia --project=. scripts/backtest_validation.jl
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    DATA INGESTION (Module 1)                 │
│  VIX • VXV • VVIX • VIX1D • IV Rank • GSW • OIS/SOFR • TGA  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                  SIGNAL SMOOTHING (Module 2)                 │
│  LOWESS → SG Filter → Adaptive Median → Block Bootstrap     │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                  PCA COMPRESSION (Module 3)                │
│  Vol Surface PCA (3 PCs) + Yield Curve Factors (3) = 6D    │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                  ARMA + GARCH (Module 4)                   │
│  Joint QMLE: ARMA(p,q) + GARCH(1,1) per regime             │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              DIRICHLET PROCESS MIXTURE (Module 5)            │
│  Stick-Breaking • Particle Filter • EM • Escobar-West       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                  CASCADE INTERFACE (Module 6)              │
│  Regime Blending • Position Sizing • Risk-Off Adjustment   │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                  EXECUTION LAYER (Module 7)                │
│  IBKR Orders • Circuit Breakers • Emergency Liquidation     │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    GOVERNANCE (Module 8)                     │
│  Version Registry • Rollback • PMO • Escalation             │
└─────────────────────────────────────────────────────────────┘
```

## License
Proprietary - SmallClaw Consultancy
