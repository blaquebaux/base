# Blaque Baux — Polyglot Architecture

Multi-language infrastructure for the Blaque Baux trading system.
Each language handles the workload it's best suited for, connected
via zero-copy FFI or message-passing IPC.

## Language assignments

| Language | Modules replaced | Latency tier | Integration |
|----------|-----------------|--------------|-------------|
| **Rust** | `signal_engine.py` (Kalman, NIG, Welford, James-Stein, combiner), `RealTimePortfolioOptimizer` | <5μs per bar | PyO3 (in-process FFI) |
| **Julia** | `qp_solver.py` (CVXPY→JuMP), `risk_engine.py` Six Sigma Oracle, `monte_carlo_engine.py`, AIC distribution fitting, TAR/Kelly computation, Cornish-Fisher VaR | <50ms per solve | juliacall (FFI) |
| **Python** | `app.py`, `optimizer_service.py`, `llm_integration.py`, `templates.py`, `config.py`, `enhancements.py` (BL, stress tests), `CompressedADVI` | orchestration | native |
| **Hy** | `distribution_regime.py` TAR-driven strategy gate, L-curve barbell with directional inversion, lane selector, circuit breaker rules | rule eval | in-process (compiles to Python AST) |
| **Go** *(phase 3)* | `connection.py`, `borrow_feed.py`, bar aggregation, heartbeat | data ingestion | Redis Streams / gRPC |

## What stays in Python and why

- **Orchestration** (`optimizer_service.py`, `app.py`): async dispatch, pool management, Streamlit UI. Python is the right glue language — no latency pressure.
- **LLM integration** (`llm_integration.py`): API calls to Claude. Network-bound, not compute-bound.
- **CompressedADVI** (`signal_engine.py` Layer 3): runs once per session (~15ms), not per bar. Pure numpy is fast enough. Moving it to Rust would add complexity for negligible gain.
- **Enhancements** (`enhancements.py`): Bayesian alpha update, Black-Litterman, stress tests. These run at session boundaries, not in the hot loop.
- **Config** (`config.py`): dataclasses and constants. No compute.

## Directory structure

```
blaque_baux_polyglot/
├── signal_engine_rs/        # Rust crate (PyO3)
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs           # KalmanFilter3State, NigBayesianUpdater,
│                            # WelfordStreamer, JamesSteinShrinkage,
│                            # HybridEngine, FastMvoSolver
│
├── optimizer_jl/            # Julia package
│   ├── Project.toml
│   ├── qp_solver.jl         # JuMP QP optimizer (replaces CVXPY)
│   └── six_sigma_oracle.jl  # 1M MC oracle, GBM, jump-diffusion, AIC fitting,
│                            # TAR/Kelly computation, Cornish-Fisher VaR
│
├── rule_engine_hy/          # Hy (Lisp) DSL
│   └── strategy_gate.hy     # TAR-driven strategy gate, L-curve barbell with
│                            # directional inversion, hedge basket composition
│
├── integration/             # Python bridge layer
│   ├── signal_engine_bridge.py   # Rust ↔ Python (drop-in for HybridSignalEngine)
│   └── optimizer_bridge.py       # Julia ↔ Python (drop-in for qp_solver)
│                                 # includes fit_distribution + TAR/Kelly bridge
│
└── Makefile                 # Build, test, benchmark
```

## Integration pattern

Both bridges follow the same design: **identical interface, transparent fallback.**

```python
# In optimizer_service.py, change ONE import line:

# Before (pure Python):
from signal_engine import HybridSignalEngine

# After (Rust hot path, Python fallback):
from integration.signal_engine_bridge import HybridSignalBridge as HybridSignalEngine

# The rest of optimizer_service.py doesn't change.
# If Rust isn't compiled, it falls back to Python with a warning log.
```

Same for the optimizer:

```python
# Before:
from optimizer.qp_solver import optimize_portfolio

# After:
from integration.optimizer_bridge import optimize_portfolio
```

## Build

```bash
# Prerequisites
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  # Rust
pip install maturin juliacall                                      # Python bridges
# Julia: download from https://julialang.org/downloads/

# Build everything
make all

# Test both bridges
make test

# Benchmark signal engine latency (1000 bars × 50 assets)
make bench
```

## Expected performance

### Signal engine (50 assets, per-bar)

| Metric | Python (current) | Rust (target) | Speedup |
|--------|----------------:|-------------:|--------:|
| Mean   | ~800 μs         | ~15 μs       | 53×     |
| P95    | ~1,200 μs       | ~25 μs       | 48×     |
| Budget | 500,000 μs      | 500,000 μs   | —       |
| Headroom | 625×          | 33,000×      | —       |

The Python version already meets the 0.5ms budget. Rust provides
headroom for scaling to 200+ assets without budgetary concern.

### QP optimizer (50 assets, per-window)

| Metric | CVXPY (current) | JuMP (target) | Speedup |
|--------|----------------:|--------------:|--------:|
| Solve  | ~15 ms          | ~5 ms         | 3×      |
| Model build | ~3 ms     | ~0.5 ms       | 6×      |

JuMP's advantage is smaller per-solve but compounds across the
efficient frontier loop (6× solves) and the lane variant matrix.

### Six Sigma Oracle (1M simulations)

| Metric | Python (current) | Julia (target) | Speedup |
|--------|----------------:|--------------:|--------:|
| 1M sims | ~45 min        | ~30 sec       | 90×     |
| Candidates | 10K         | 10K           | —       |

This is the biggest win. Julia JIT-compiles the inner loop including
Cholesky decomposition, correlated sampling, and portfolio return
calculation. Makes 1M sims feasible as an intra-day job rather
than overnight batch.

## Data flow

```
Market data (Go, phase 3)
    │
    ▼  Redis Streams (bar events)
┌─────────────────────────────────────┐
│  Python orchestrator                │
│  optimizer_service.py               │
│                                     │
│  ┌─── Rust (PyO3, in-process) ───┐  │
│  │  signal_engine_rs             │  │
│  │  Kalman → NIG → Welford →     │  │
│  │  James-Stein → combine        │  │
│  │  Returns: alpha, unc, mask    │  │
│  └───────────────────────────────┘  │
│         │                           │
│         ▼ alpha + risk_params       │
│  ┌─── Julia (juliacall, FFI) ────┐  │
│  │  QPSolver.optimize_portfolio  │  │
│  │  AIC fit → TAR/Kelly compute  │  │
│  │  Returns: weights, meta, TAR  │  │
│  └───────────────────────────────┘  │
│         │                           │
│         ▼ weights + TAR + Kelly     │
│  ┌─── Hy (in-process, Python AST)┐  │
│  │  strategy_gate.hy             │  │
│  │  TAR > 2.0 → bet with tail   │  │
│  │  TAR < 0.5 → INVERT book     │  │
│  │  Returns: StrategyGate dict   │  │
│  └───────────────────────────────┘  │
│         │                           │
│         ▼ final_weights             │
│  ┌─── Rust (gRPC, phase 3) ─────┐  │
│  │  order_manager (execution)    │  │
│  │  IBKR FIX routing             │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

## Phase plan

1. **Now**: Rust signal engine + Julia optimizer + TAR/Kelly (this scaffold)
2. **Now**: Hy/Lisp TAR-driven strategy gate DSL (included in this scaffold)
3. **Phase 3**: Go market data ingestion service + Rust execution engine
4. **Phase 4**: Rust real-time risk (Cornish-Fisher VaR, TAR from risk_intelligence1.py)
