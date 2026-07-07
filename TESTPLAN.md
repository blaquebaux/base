# Blaque Baux — Test Plan

**Version:** 0.1 · **Last updated:** 2026-07-06

Defines how each requirement is verified. A requirement is not "done" until its row in
the `design.md` matrix has a test here and the test passes.

## Verification approach by enforcement tier

| Tier | Verified by | Example |
|---|---|---|
| **static** | CI lint that fails the build on violation | REQ-DATA-002 import-boundary check |
| **runtime** | assertion/guard raises; a test triggers it | REQ-SIM-001 look-ahead raises |
| **test** | unit/integration assertion | REQ-SIM-002 next-bar fill |
| **manual** | documented human review until automated | (interim only) |

## Per-requirement verification

| REQ-ID | Enforcement | How verified | Test location (planned) |
|---|---|---|---|
| REQ-DATA-001 | static + runtime | Lint: no `load_all`/scan/aggregate reachable from execution path. Runtime: hot-store accessor rejects non-keyed queries. | `tests/static/test_hot_path_data_access.py` |
| REQ-DATA-002 | static | Import-boundary lint over the `run_live.py` dependency graph. | `tests/static/test_stratum_boundary.py` |
| REQ-SIM-001 | runtime | Feed data timestamped > sim-clock now; assert it **raises**, not warns. | `tests/sim/test_lookahead_guard.py` |
| REQ-SIM-002 | test | Decision on bar N fills at open of bar N+1; assert never same-bar. | `tests/sim/test_next_bar_fill.py` |
| REQ-RISK-001 | test | Attempt concurrent solves against one pool's budget; assert serialization. | `tests/risk/test_solve_serialization.py` |
| REQ-RISK-002 | test | Force a reject/zero; assert a named reason is written to the audit trail. | `tests/risk/test_reject_reasons.py` |
| REQ-RISK-003 | runtime | Submit a candidate exceeding a pool budget; assert rejection at the gate. | `tests/risk/test_pool_budget_gate.py` |
| REQ-EXEC-001 | test | Drive two rebalances for one pool; assert at most one outstanding submission. | `tests/exec/test_serial_submission.py` |
| REQ-AUDIT-001 | runtime | Every fill row asserted to carry signal/regime/solve/order IDs. | `tests/audit/test_fill_lineage.py` |
| REQ-AUDIT-002 | runtime | Submit an order with a missing lineage field; assert it is rejected, not sent. | `tests/audit/test_lineage_gate.py` |
| REQ-REGIME-001 | runtime | Force a regime transition; assert strategy activation gates and the transition is logged. | `tests/regime/test_regime_gate.py` |

## Priority

Run/author in the `tasks.md` order: P0 (REQ-DATA-001) first — it is the one confirmed
violation. Then the boundary lints and audit/regime implementation, then the "unknown"
audits.

## Regression baseline

`REQ-FEAT-002` — `run_phase1.py` must reproduce a Phase 1 backtest from cached data.
This is the smoke test that consolidation did not break the research stratum.
