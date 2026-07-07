# Blaque Baux — Design & Traceability

**Version:** 0.1 · **Last updated:** 2026-07-06

This document maps requirements to the code that implements them and the tests that
verify them. It also records, per requirement, how the guarantee is *enforced* and its
*current conformance* against the consolidated codebase.

## Architecture: three strata

```
                 ┌──────────────────────────────────────────────┐
  EXECUTION      │  run_live.py                                  │
  (hot path)     │    └─ orchestration/ (coordinator, pool_mgr,  │
                 │        circuit_breaker, event_bus,            │
                 │        optimizer_service)                     │
                 │    └─ ibkr/ (connection, order_manager,       │
                 │        borrow_feed)                            │
                 └───────────────┬──────────────────────────────┘
                                 │  REQ-DATA-001/002 boundary
                                 │  (execution must NOT reach research)
                 ┌───────────────┴──────────────────────────────┐
  RESEARCH       │  run_phase1.py                                │
  (cold path)    │    └─ data/ (fetcher)                         │
                 │    └─ signal/ (cascade, factors)              │
                 │    └─ optimizer/ (qp_solver)                  │
                 │    └─ backtest/ (engine, metrics)             │
                 └───────────────┬──────────────────────────────┘
                                 │  migration target
                 ┌───────────────┴──────────────────────────────┐
  TARGET ARCH    │  polyglot/                                    │
                 │    optimizer_jl/ (qp_solver.jl, six_sigma)    │
                 │    signal_engine_rs/ (Rust)                   │
                 │    rule_engine_hy/ (strategy_gate.hy)         │
                 │    integration/ (bridges)                     │
                 └──────────────────────────────────────────────┘
```

## Enforcement tiers

Each requirement is enforced by one of:
- **static** — a build/CI rule (e.g. an import-boundary lint) makes a violation fail to build.
- **runtime** — an assertion/guard raises at run time on violation.
- **test** — a unit/integration test proves the property.
- **manual** — reviewed by a human until automated.

## Conformance states

`holds` · `at-risk` · **`VIOLATED`** · `partial` · `unknown` · `unimplemented`

## Traceability matrix

| REQ-ID | Implementing module(s) | Verifying test(s) | Enforcement | Conformance (2026-07-06) |
|---|---|---|---|---|
| REQ-DATA-001 | `orchestration/coordinator.py`, `orchestration/pool_manager.py`, `data/fetcher.py` | *(none yet)* | static (import + call-shape lint) + runtime | **VIOLATED** — order path calls `data.fetcher.load_all` (`coordinator.py:178`, `pool_manager.py:464`), a bulk parquet loader documented as "the single call used by the backtest engine". Not a keyed hot-store lookup. |
| REQ-DATA-002 | `run_live.py`, `ibkr/`, `orchestration/` | *(none yet)* | static (import-boundary lint) | at-risk — order path does not import `backtest`, but *does* import research-stratum `data.fetcher` (see DATA-001). Boundary needs a lint before it drifts further post-consolidation. |
| REQ-SIM-001 | `backtest/engine.py` | *(none yet)* | runtime (raise on look-ahead) | unknown — sim-clock guard not yet audited. |
| REQ-SIM-002 | `backtest/engine.py` | *(none yet)* | test | unknown — engine references "next bar" (`engine.py:167`) but fill timing not yet verified. |
| REQ-RISK-001 | `orchestration/pool_manager.py`, `orchestration/optimizer_service.py`, `optimizer/qp_solver.py` | *(none yet)* | design (one coroutine per pool) + test | unknown — per-pool coroutine model suggests serialization; `optimizer_service.py` not yet audited for shared-solve interleaving. |
| REQ-RISK-002 | `optimizer/qp_solver.py` | *(none yet)* | test + runtime | unknown — reject-reason logging not yet confirmed in solver. |
| REQ-RISK-003 | `orchestration/pool_manager.py` | *(none yet)* | runtime (gate check) | partial — pool taxonomy exists (`EQUITIES_APAC/EMEA/US`, commodities, crypto, dte_overlay); budget-at-gate enforcement not confirmed. |
| REQ-EXEC-001 | `ibkr/order_manager.py` | *(none yet)* | test | holds (pending test) — `_submit_orders` iterates orders serially per pool (`order_manager.py:146+`); pools are independent asyncio coroutines. Needs a test to lock in. |
| REQ-AUDIT-001 | *(execution path — TBD)* | *(none yet)* | runtime | unimplemented — no lineage-carrying fill record found in sweep. |
| REQ-AUDIT-002 | *(Trader gate — TBD)* | *(none yet)* | runtime (reject on incomplete lineage) | unimplemented. |
| REQ-REGIME-001 | `polyglot/rule_engine_hy/strategy_gate.hy` (target); execution wiring TBD | *(none yet)* | runtime | unimplemented in execution path — regime gate exists only in target-arch stratum, not wired into `run_live.py`. |

**The empty "Verifying test(s)" column is the Phase 2 backlog** (see `tasks.md`).
Sequencing rule: audit/close the invariants whose conformance is `VIOLATED` or `unknown`
before the ones that already `hold`.

## Design appendices (existing framework documents)

These are referenced, not rewritten. They live in the user's document store:

- **Gamma-ARMA framework** — `BlaqueBaux_GammaARMA_Framework.docx`, `BlaqueBaux_GammaARMA_v2.docx`
  (governs REQ-REGIME-001)
- **Three-strata statistical architecture** — `BlaqueBaux_StatisticalArchitecture.docx`
  (the execution/research/target strata this repo is organized around)
- **Pre-distribution review appendix** — `BlaqueBaux_PreDist_Review_Appendix.docx`
- **Fleet architecture runbook** — `BlaqueBaux_Fleet_Architecture_Runbook.md`
  (machine assignment; cf. `pool_manager.py` `machine_id`)
- **PortfolioOpt.jl module docs** — target-arch optimizer (governs migration of `optimizer/qp_solver.py` → `polyglot/optimizer_jl/`)

## Known mechanism notes (the "how" kept out of Requirements.md)

- **REQ-RISK-001 mechanism:** each pool runs as a single asyncio coroutine
  (`pool_manager.py`), so solves within a pool are naturally ordered; a shared
  `optimizer_service` must not break this — to be verified.
- **REQ-DATA-001/002 mechanism (proposed):** an import-boundary lint that fails CI if
  anything reachable from `run_live.py` imports `data/`, `signal/`, `optimizer/`, or
  `backtest/`; plus a call-shape check that the hot path uses keyed getters, not `load_all`.
