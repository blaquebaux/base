# Blaque Baux — Tasks

**Version:** 0.3 · **Last updated:** 2026-07-06 · **Base:** CherryPick (Julia)

Backlog from the traceability matrix (`design.md`), ordered by invariant severity ×
conformance risk. The system already has 650+ tests; the work is closing conformance
gaps and covering the untested newest modules — not writing a suite from scratch.

## P0 — confirmed violation

- [ ] **REQ-AUDIT-001** — Add decision lineage to `FillRecord`
      (`src/module_10_feedback/execution_ledger.jl`). It currently has execution-quality
      fields only (impact, ADV, σ, materiality). Add `signal_id`, `regime`, `solve_id`,
      `order_id` so every fill carries signal → regime → solve → order provenance.

## P1 — must shape the coming `Jib.jl` execution work (not chase it)

The real-broker replacement of the simulated `send_order` cannot be a drop-in. Design
these invariants *into* it:

- [ ] **REQ-EXEC-002 (idempotency)** — Give order submission an idempotency key so a retry
      after connection loss cannot double-submit. The reconnect loop in
      `ibkr_connection.jl` is where duplicates are born; the `ReentrantLock` does nothing
      about it. **Highest-risk gap once live.**
- [ ] **REQ-EXEC-003 (reconciliation)** — Reconcile internal position state against
      broker-reported state on a defined cadence; unexplained divergence halts the pool.
- [ ] **REQ-EXEC-001** — Replace simulated `send_order` with `Jib.jl`/TWS, preserving the
      `ReentrantLock` serialization. (CHERRY_PICK_NOTES limitation #3.) Do after EXEC-002/003 design.
- [ ] **REQ-AUDIT-002** — Gate emission on complete lineage: reject any order missing a
      lineage field at the `module_7` gate, never log-and-send. Depends on P0.
- [ ] **REQ-DATA-002** — Import-graph check: exec modules 7/12 must not `include`/`using`
      research modules (`module_13` backtest). Whitelist the `module_12 → cuopt_bridge.py`
      HTTP solver seam. (Julia-internal scope confirmed — see design.md Entrypoints.)
- [ ] **REQ-REGIME-001** — Confirm every regime transition is written to the
      `module_8_governance` audit log (not just applied).

## P1b — remaining live-capital invariants

- [ ] **REQ-RISK-004 (loss halt)** — Per-pool daily loss limit; on breach, halt new
      emission until an explicit, logged human re-enable. (Circuit breaker in `module_7`
      exists; the loss-limit + re-enable does not.)
- [ ] **REQ-DATA-003 (staleness halt)** — Execution path halts (not warns) on data older
      than a per-venue threshold. `module_1` has staleness *detection*; wire it to a halt.
- [ ] **REQ-GOV-002 (kill switch)** — Manual halt of all new emission within a bounded
      time, halt event audit-logged.

## P2 — cover the untested modules 9–13 (the coverage cliff)

- [ ] **module_10_feedback** — unit tests for `ExecutionLedger`/`FillRecord`
      (verifies REQ-AUDIT-001/002 once lineage lands).
- [ ] **module_13_portfolio** — unit tests for the optimizers; assert every rejected/zeroed
      candidate emits a named reason (REQ-RISK-002) and per-pool budget serialization (REQ-RISK-001).
- [ ] **module_12_sor** — unit tests for the smart order router (+ cuOpt bridge contract).
- [ ] **module_9_0dte** — unit tests for the 0DTE overlay.
- [ ] **module_11_cv** — unit test (currently exercised only via `backtest_validation.jl`).

## P3 — audit the "unknown" conformance rows

- [ ] **REQ-SIM-001 (clock chokepoint)** — Audit for a runtime sim-clock guard that raises
      on future-dated access. Initial sweep found none — **likely unimplemented as a
      chokepoint.** If so, this is a build task, not just an audit. (Purged K-Fold does
      NOT satisfy this — that is REQ-SIM-003.)
- [ ] **REQ-SIM-002 (bar semantics)** — Define per-pool/venue bar semantics FIRST (0DTE
      1-min ORB 09:30–10:00 ET; commodities 23-hr; crypto discrete windows), then test
      next-bar-open fill. Do not universalize one venue.
- [ ] **REQ-DATA-001** — audit execution path uses keyed state, not bulk `module_1` loads.
- [ ] **REQ-RISK-003** — confirm per-pool budget enforced at the gate before emission.

## P4 — hygiene & self-maintenance

- [ ] Fill `design.md` test column as module 9–13 tests land; flip conformance cells.
- [ ] **Reconcile `DOCUMENT-CONTROL.md` against the ChordSense DOCUMENT-CONTROL** (our own,
      battle-tested) — better target than the WatsonX workshop template.
- [ ] Decide whether Stratum III has an implementation/test (only I & II present).
- [ ] **Wire the SmallClaw weekly spec-maintenance work order** (`scripts/spec_audit.sh`):
      re-derive the matrix test column from the actual suite, flag conformance cells older
      than N weeks, flag orphan modules and orphan REQs, append dated findings to
      `HONEST-ASSESSMENT.md`. Owner for the conformance column — do this while the matrix
      is 19 rows, not 40.

## Done (Phase 1 + review corrections)

- [x] Identify CherryPick (2026-05-31 Julia) as the system of record; retire the April
      Python prototypes (preserved in git history + `Downloads/`).
- [x] Re-base canonical repo on CherryPick; establish the spec stack.
- [x] **Fix REQ-SIM-001 mapping** (was conflated with purged-CV / rated "holds (likely)"):
      downgrade to `unknown`, split out **REQ-SIM-003** (leakage-free CV) as its own REQ.
- [x] **Resolve entrypoint ambiguity**: live runner is Julia (`run_daily_recursive.jl`);
      Python is boundary glue; one allowed HTTP solver seam. design.md documents it.
- [x] **Append five live-capital invariants** (REQ-DATA-003, REQ-RISK-004, REQ-EXEC-002/003, REQ-GOV-002).
- [x] **De-mechanize REQ-DATA-002** (removed named engine; fixed anchor).
- [x] Purge "holds (likely)" — conformance vocabulary is now closed (5 states only).
