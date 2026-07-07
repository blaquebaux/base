# Blaque Baux — Canonical Repository

Version-controlled root for the Blaque Baux Gamma-ARMA trading system. Based on the
**CherryPick** build (2026-05-31) — the current production-grade Julia implementation,
itself a scored cherry-pick across seven implementations (Kimi base + Deepseek-v2
integration; see `CHERRY_PICK_NOTES.md`).

> Earlier Python trees (`blaque_baux-v1/-v2/_polyglot`, ~April 2026) were prototypes and
> are **superseded**. They remain in `Downloads/` and in this repo's git history (first
> commit) for reference only.

## System layout (Julia, modules 1–13)

| Module | Purpose | Key invariants |
|---|---|---|
| `module_1_data` | Ingestion, normalization, staleness (Cboe/FRED/Deribit/TGA) | REQ-DATA-001/002 |
| `module_2_smoothing` | LOWESS / SG / adaptive median | — |
| `module_3_pca` | Vol-surface + yield-curve PCA → 6-dim state | — |
| `module_4_arma` | ARMA(p,q) + GARCH(1,1) QMLE | REQ-REGIME-001 |
| `module_5_dpm` | Dirichlet Process Mixture (particle filter, EM) | REQ-REGIME-001 |
| `module_6_cascade` | Cascade interface, regional sizing (APAC/EMEA/US) | REQ-REGIME-001, REQ-RISK-003 |
| `module_7_execution` | IBKR execution, 4-state circuit breaker (`ReentrantLock`) | REQ-EXEC-001 |
| `module_8_governance` | Version registry, serialization, rollback | REQ-GOV-001 |
| `module_9_0dte` | 0DTE overlay | — |
| `module_10_feedback` | Execution ledger (`FillRecord`), cascade feedback | REQ-AUDIT-001/002 |
| `module_11_cv` | Purged K-Fold / CPCV (López de Prado) | REQ-SIM-001 |
| `module_12_sor` | Smart order router (+ cuOpt GPU bridge) | REQ-EXEC-001 |
| `module_13_portfolio` | PortfolioOpt (BL, mean-var, risk-based, robust, tail-risk, cost-aware) | REQ-RISK-001/002 |

Strata implementations: `StructuralStatistics.jl`, `ComputationalStatistics.jl`,
`GeometricCoordinationLayer.jl` (tested by `test/test_stratum_i.jl`, `test_stratum_ii.jl`).

Orchestration: `scripts/run_daily_recursive.jl`, `run_em_weekly.jl`,
`backtest_validation.jl`; Python glue `massive_client.py` (data/dashboard),
`cuopt_bridge.py` (GPU SOR).

## The spec stack

- **`Requirements.md`** — invariants first, each with a permanent `REQ-ID`. Append-only.
- **`design.md`** — traceability matrix: REQ → module → **existing test** → enforcement → conformance.
- **`tasks.md`** — backlog: close conformance gaps, cover the untested modules 9–13.
- **`TESTPLAN.md`** — verification, mapped onto the existing 650+-case suite.
- **`DOCUMENT-CONTROL.md`** — versioning + invariant-change sign-off.
- **`docs/appendices/`** — Gamma-ARMA framework, Statistical Architecture, Pre-Dist Review (`.docx`).

## Run

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl
```
