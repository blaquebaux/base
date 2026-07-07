# Blaque Baux — Tasks

**Version:** 0.1 · **Last updated:** 2026-07-06

Backlog derived from the traceability matrix (`design.md`). Every open task closes a
`VIOLATED`, `unknown`, `partial`, or `unimplemented` conformance cell, or fills an empty
test column. Ordered by invariant severity × conformance risk.

## P0 — confirmed violations (fix the guarantee, then prove it)

- [ ] **REQ-DATA-001** — Remove `data.fetcher.load_all` from the execution path.
      `orchestration/coordinator.py:178` and `pool_manager.py:464` must obtain data via
      keyed hot-store lookups, not the backtest bulk loader. Then add the import-boundary
      + call-shape lint. *(Enforcement: static + runtime.)*

## P1 — enforcement the invariant boundary depends on

- [ ] **REQ-DATA-002** — Add CI import-boundary lint: nothing reachable from `run_live.py`
      may import `data/`, `signal/`, `optimizer/`, or `backtest/`. This is the guardrail
      that makes co-locating the strata in one repo safe.
- [ ] **REQ-AUDIT-001 / REQ-AUDIT-002** — Implement the fill lineage record
      (signal ID → regime → QP solve ID → order ID) and the Trader-gate rejection of any
      order with incomplete lineage. Currently unimplemented.
- [ ] **REQ-REGIME-001** — Wire `polyglot/rule_engine_hy/strategy_gate.hy` (or its Python
      equivalent) into `run_live.py` so regime transitions actually gate activation, and
      log every transition. Currently only present in the target-arch stratum.

## P2 — audit unknowns (turn "unknown" into holds/violated with a test)

- [ ] **REQ-SIM-001** — Audit `backtest/engine.py` for a sim-clock look-ahead guard;
      add a test that a later-than-now data access raises (not warns).
- [ ] **REQ-SIM-002** — Verify fills execute at next-bar open; add a regression test.
- [ ] **REQ-RISK-001** — Audit `orchestration/optimizer_service.py` for shared-solve
      interleaving across pools; test that concurrent solves against one pool's budget
      cannot occur.
- [ ] **REQ-RISK-002** — Confirm/instrument named reject reasons in `optimizer/qp_solver.py`;
      test that every zeroed/rejected candidate emits a reason.
- [ ] **REQ-RISK-003** — Confirm the per-pool budget is checked at the Trader gate before
      emission; add a gate test.
- [ ] **REQ-EXEC-001** — Add the test that proves at most one outstanding submission per
      pool (design already holds — `order_manager._submit_orders` is serial).

## P3 — spec hygiene

- [ ] Fill the "Verifying test(s)" column in `design.md` as each test above lands.
- [ ] Expand the Features section of `Requirements.md` beyond the two seed items.
- [ ] Obtain the reference `DOCUMENT-CONTROL.md` from nycsav/IBM-WatsonX-AI-Agent-Workshop
      and reconcile any conventions not yet reflected here.

## Done (Phase 1)

- [x] Consolidate v1 (execution) + v2 (research) + polyglot (target) into one
      version-controlled canonical repo.
- [x] Establish the spec stack: Requirements, design + traceability matrix,
      tasks, TESTPLAN, DOCUMENT-CONTROL.
- [x] Seed 10 invariants + REQ-AUDIT-002; run a first conformance sweep.
