# Blaque Baux — Tasks

**Version:** 0.2 · **Last updated:** 2026-07-06 · **Base:** CherryPick (Julia)

Backlog from the traceability matrix (`design.md`), ordered by invariant severity ×
conformance risk. The system already has 650+ tests; the work is closing conformance
gaps and covering the untested newest modules — not writing a suite from scratch.

## P0 — confirmed violation

- [ ] **REQ-AUDIT-001** — Add decision lineage to `FillRecord`
      (`src/module_10_feedback/execution_ledger.jl`). It currently has execution-quality
      fields only (impact, ADV, σ, materiality). Add `signal_id`, `regime`, `solve_id`,
      `order_id` so every fill carries signal → regime → solve → order provenance.

## P1 — live-path & enforcement gaps

- [ ] **REQ-AUDIT-002** — Gate order emission on complete lineage: reject any order
      missing a lineage field at the execution gate (`module_7`), never log-and-send.
      Depends on P0.
- [ ] **REQ-EXEC-001** — Replace simulated `send_order` (`module_7_execution`) with the
      real IBKR TWS path (`Jib.jl`), preserving the existing `ReentrantLock` serialization.
      (CHERRY_PICK_NOTES limitation #3.)
- [ ] **REQ-DATA-002** — Add an import-graph check that the execution path
      (`module_7`, `module_12`) does not import `module_13` backtest / heavy analytics.
- [ ] **REQ-REGIME-001** — Confirm every regime transition is written to the
      `module_8_governance` audit log (not just applied).

## P2 — cover the untested modules 9–13 (the coverage cliff)

- [ ] **module_10_feedback** — unit tests for `ExecutionLedger`/`FillRecord`
      (verifies REQ-AUDIT-001/002 once lineage lands).
- [ ] **module_13_portfolio** — unit tests for the optimizers; assert every rejected/zeroed
      candidate emits a named reason (REQ-RISK-002) and per-pool budget serialization (REQ-RISK-001).
- [ ] **module_12_sor** — unit tests for the smart order router (+ cuOpt bridge contract).
- [ ] **module_9_0dte** — unit tests for the 0DTE overlay.
- [ ] **module_11_cv** — unit test (currently exercised only via `backtest_validation.jl`).

## P3 — audit the "unknown" conformance rows

- [ ] **REQ-DATA-001** — audit execution path uses keyed state, not bulk `module_1` loads.
- [ ] **REQ-SIM-001** — confirm the look-ahead guard **raises** (not warns).
- [ ] **REQ-SIM-002** — confirm next-bar-open fills in `module_13/backtest.jl`.
- [ ] **REQ-RISK-003** — confirm per-pool budget enforced at the gate before emission.

## P4 — hygiene

- [ ] Fill `design.md` test column as module 9–13 tests land; flip conformance cells.
- [ ] Obtain reference `DOCUMENT-CONTROL.md` (nycsav/IBM-WatsonX-AI-Agent-Workshop) and reconcile.
- [ ] Decide whether Stratum III has an implementation/test (only I & II present).

## Done (Phase 1)

- [x] Identify CherryPick (2026-05-31 Julia) as the system of record; retire the April
      Python prototypes (preserved in git history + `Downloads/`).
- [x] Re-base canonical repo on CherryPick; establish the spec stack.
- [x] Seed 12 invariants (10 + REQ-AUDIT-002 + REQ-GOV-001); trace to modules and the
      existing test suite; record grounded conformance.
