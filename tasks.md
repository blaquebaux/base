# Blaque Baux — Tasks

**Version:** 0.3 · **Last updated:** 2026-07-26 · **Base:** CherryPick (Julia)

Backlog from the traceability matrix (`design.md`), ordered by invariant severity ×
conformance risk. The system already has 650+ tests; the work is closing conformance
gaps and covering the untested newest modules — not writing a suite from scratch.

## P0 — confirmed violation

- [ ] **REQ-AUDIT-001** — Add decision lineage to `FillRecord`
      (`src/module_10_feedback/execution_ledger.jl`). It currently has execution-quality
      fields only (impact, ADV, σ, materiality). Add `signal_id`, `regime`, `solve_id`,
      `order_id` so every fill carries signal → regime → solve → order provenance.

## P1 — execution build (venue-adapter, IBKR first, paper-only)

Venue-adapter architecture adopted (over cloning): one governed controller, thin adapter
per broker, venue chosen by deployment config. Sequenced so invariants that shape the
connection code come first.

- [x] **Step 1 — venue interface + IBKR adapter skeleton.** `ExecutionVenue` interface
      (`venue_interface.jl`), `IBKRVenue` over Jib.jl (`venues/ibkr.jl`), connection/reconnect
      wired (`ibkr_connection.jl`, was dead code), venue-agnostic controller skeleton
      (`execution_controller.jl`) with the kill switch (REQ-GOV-002) enforced and every
      other invariant marked as an explicit governance gap. Fixed the order-model bug in
      the old Jib code. Parses clean under Julia 1.12.
- [x] **Step 1.5 — hardening (review findings).** Fixed: dropped-fills guard (AUDIT-001
      integrity), market-data/order-id race via separate locked `next_req_id` (EXEC-001
      integrity), venue-owned connection (removed global singleton), reject fractional
      equity shares. Verified no export collisions. Open: Jib API unverified until a paper
      Gateway run (#4).
- [x] **Step 2 — REQ-EXEC-002 (idempotency) + REQ-EXEC-003 (reconciliation).** Controller
      dedups on `client_order_id` (replay returns prior ack, never re-submits); key stamped
      as IBKR `orderRef`; `rehydrate!` hook for cross-restart. `reconcile!` compares expected
      vs broker positions and halts on divergence. Both `partial` (see design.md): cross-
      restart idempotency + authoritative expected-positions land with the ledger (step 3);
      per-pool halt with step 4.
- [x] **Step 2.5 — review findings F2/F3/F4/F5.** `OrderAck` now carries `status`
      (`:accepted`/`:rejected`/`:uncertain`); `:uncertain` (placeOrder threw — may be live)
      locks the `client_order_id`, closing the within-session ack-loss double-submit (F2).
      Connection/reconnect and `positions()` no longer hold the lock across network I/O or
      sleeps (F3). `recon_tolerance` defaults to a small epsilon (F4). `orderRef`/`n_avail`
      commented as assumptions (F5). F1 deferred to step 3 (below): `expected` is now empty
      and `reconcile!` is marked not-operational until fills drive it.
- [x] **Step 3 — REQ-AUDIT-001 (P0) + REQ-AUDIT-002 + F1.** `FillRecord` now carries
      `signal_id/regime/solve_id/order_id`; write-path constructor rejects empty lineage
      (P0 VIOLATION fixed, enforced structurally); schema + migration for existing DBs.
      `submit_governed!` rejects orders with incomplete lineage (AUDIT-002 gate). `expected`
      is now fill-driven via `process_fills!`/`apply_fill!` (F1 fixed) → `reconcile!` operational.
      Remaining: wire `process_fills!` → `record_fill` in the daily runner (integration); tests (step 6).
      DONE: removed orphan duplicate files (src/execution_ledger.jl, cascade_feedback.jl,
      module_10_feedback.jl, module_9_0dte.jl) — dead copies of the module_*/ dir versions.
- [ ] **Step 4 — REQ-RISK-003 (budget gate) + REQ-RISK-004 (daily loss halt).** Per-pool
      budget check before emission; loss-limit breach halts the pool until logged human re-enable.
- [ ] **Step 5 — REQ-GOV-002 finish.** Bounded-time halt guarantee + write halt events to
      the `module_8_governance` audit log.
- [x] **Step 6 — controller tests.** `test/test_execution_controller.jl` (Jib-free, mock
      venue), **34/34 incl. a 4-thread concurrency stress test** (no budget over-commit,
      cap held, reservation/lineage consistent, no deadlock — verifies I2). Wired into
      `runtests.jl`; the 9 controller REQ rows in design.md now cite it. Verifies the
      *controller logic* for EXEC-001/002/003, AUDIT-001/002, RISK-003/004, DATA-003,
      GOV-002. NOT covered (needs a paper Gateway, #4): the IBKR adapter's Jib calls and the
      runner integration (PnL/staleness/fills/audit/ledger wiring).
- [ ] **REQ-DATA-002** — Import-graph check: exec modules 7/12 must not `include`/`using`
      research modules (`module_13` backtest). Whitelist the `module_12 → cuopt_bridge.py`
      HTTP solver seam. (Julia-internal scope confirmed — see design.md Entrypoints.)
- [ ] **REQ-REGIME-001** — Confirm every regime transition is written to the
      `module_8_governance` audit log (not just applied).

*Alpaca is a later `venues/alpaca.jl` adapter selected by deployment config on a second
fleet machine — not a repo clone. The governed controller above is built once.*

- [x] **Step 4 — REQ-RISK-003 (budget gate) + REQ-RISK-004 (loss halt) + per-pool halt.**
      `submit_governed!` enforces a per-pool daily gross-notional budget before emission
      (`set_pool_budget!`; `VenueOrder.ref_price` added so market orders can be sized).
      `update_pnl!` halts a pool on daily-loss-limit breach until explicit `resume_pool!`
      (`reset_daily!` clears counters but does not lift halts). `reconcile!` halt upgraded
      from controller-wide to per-pool via `symbol_pool`. Gate order: idempotency → global
      halt → lineage → per-pool halt → budget → submit. Tests = step 6.

## P1b — remaining live-capital invariants

- [x] **Step 5 — REQ-GOV-002 finish + REQ-DATA-003.** GOV-002: bounded-time documented
      (flag checked synchronously; ≤1 in-flight order via the venue lock); all
      halt/resume events (global + per-pool) go to an `audit` sink (`set_audit_sink!`),
      which the runner wires to the module_8 governance log. DATA-003: `submit_governed!`
      blocks emission for a pool whose feed exceeds `set_pool_staleness!` (transient gate,
      auto-recovers on `mark_data_fresh!`; never-marked = stale). Both `partial` (enforced;
      module_1/module_8 wiring is integration; tests = step 6).
- [x] **Step 5.5 — review findings I1/I2.** I1: audit sink is best-effort (`_audit`
      try/catch) so a failing sink can't block a halt. I2: `ExecutionController` is now
      concurrency-safe — a `ReentrantLock` guards all state, never held across I/O;
      submission is reserve→submit→finalize so the kill switch stays responsive. **Verified
      by a 30/30 mock-venue smoke test** (scratchpad `smoke_controller.jl`) — first runtime
      verification; formalize into `test/` as step 6.

## Phase 3 — integration + paper Gateway (live path)

- [x] **Jib adapter API verified offline (#4 mostly closed).** Loaded ExecutionLayer against
      real Jib (v0.31); found + fixed 6 bugs (wrapper type, reqIds arity, error arity,
      cancelOrder OrderCancel, reqMktData arg, connectionClosed invalid callback). Module now
      loads and Jib.Wrapper constructs.
- [x] **Paper smoke test + runbook.** `scripts/ibkr_paper_smoke.jl` (paper-guarded; drives
      connect → submit_governed! → process_fills! → reconcile!) and `docs/PAPER_GATEWAY_RUNBOOK.md`.
- [ ] **USER: run the paper smoke test** against a live IB Gateway paper session (only you can —
      needs Gateway + paper login). Confirms runtime connect/place/fill. Closes #4.
- [x] **Runner integration DRAFTED.** `scripts/live_execution.jl` (glue: `build_live_controller`,
      `make_recorder` → ledger with lineage + execId-based fill_id, `execute_rebalance!`,
      `feed_staleness!`, governance audit JSONL sink). `run_daily_recursive.jl` step 7 now routes
      through the governed path (gated behind `BB_LIVE_EXEC=yes`; emergency → `halt!`). Verified by
      `test/test_live_integration.jl` (11/11, mock venue + REAL SQLite ledger). Threaded IBKR
      `execId` through the fill pipeline so ledger `fill_id` is unique (AUDIT-001).
- [ ] **USER: run paper smoke, then flip `BB_LIVE_EXEC=yes`** to exercise the runner live.
- [ ] **STRATEGY SEAM: implement `compute_targets`** (regime/sizing → per-symbol share targets).
      Currently a placeholder returning `{}` (no-op). This is the missing strategy mapping.
- [ ] **Wire PnL feed** (`update_pnl!`) — the runner doesn't compute per-pool PnL yet (needs marks/cost basis).
- [ ] **Connection-drop detection** — wire via Jib's actual mechanism (reader Task end / conn
      state); Jib has no `connectionClosed` callback.

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
