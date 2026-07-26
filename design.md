# Blaque Baux — Design & Traceability

**Version:** 0.4 · **Last updated:** 2026-07-26 · **Base:** CherryPick (2026-05-31, Julia)

Maps each requirement to the Julia module that implements it and the **existing** test
that verifies it, with enforcement mechanism and current conformance. The system already
carries 650+ test cases; the spec layer's job here is to *connect requirements to that
suite and expose the gaps*, not to write tests from zero.

## Entrypoints & language boundary (resolves the run_live.py ambiguity)

The **live runner is Julia**: `scripts/run_daily_recursive.jl` includes
`module_7_execution` and calls `send_order(...)` directly. There is **no** Python
orchestration layer over Julia — the earlier `run_live.py` / `run_phase1.py` anchors were
stale references from the retired prototypes and have been corrected.

Python exists only at process boundaries, and only one touches the order path:

| Python component | Relationship | On order path? |
|---|---|---|
| `scripts/cuopt_bridge.py` | HTTP solver microservice; **Julia SOR (`module_12`) calls it** (`POST 127.0.0.1:8765/route`) for GPU venue allocation | **Yes — as a solver dependency**, not a research dependency |
| `scripts/portfolio_server.jl` + `dashboard.py` + `massive_client.py` | Read-only dashboard stack (Dash frontend over a Julia HTTP server) | No |

**Consequence for the REQ-DATA-002 import-graph task:** the check is Julia-internal
(execution modules 7/12 must not `include`/`using` research modules — `module_13` backtest,
analytics), **plus** an explicit allow for the single cross-language seam
(`module_12` → `cuopt_bridge.py` over HTTP), which is a solver, not the research stratum.
The task is correctly scoped as Julia-only imports + one whitelisted HTTP call.

## Execution venues (venue-adapter architecture)

Execution is venue-agnostic. The engine places orders only through the `ExecutionVenue`
interface; every order-path invariant is enforced once in the venue-agnostic controller.
"IBKR now, Alpaca later" is one governed codebase with a thin adapter per broker — **not**
a repo fork (a fork would re-create the divergence the canonical repo exists to prevent,
and force rebuilding the safety-critical layer per broker).

```
src/module_7_execution/
├── module_7_execution.jl   # ExecutionLayer module (includes the below; legacy send_order retained)
├── venue_interface.jl      # abstract ExecutionVenue; canonical VenueOrder / OrderAck; interface stubs
├── ibkr_connection.jl      # Jib.jl session mgmt, reconnect, positions, fills (now WIRED; was dead code)
├── venues/ibkr.jl          # IBKRVenue <: ExecutionVenue  (translates VenueOrder -> Jib)   ← now
├── venues/alpaca.jl        # AlpacaVenue <: ExecutionVenue                                   ← later
└── execution_controller.jl # venue-AGNOSTIC governed path: EXEC-002/003, AUDIT, RISK, GOV (built once)
```

- **VenueOrder** carries the idempotency key (`client_order_id`, REQ-EXEC-002) and
  lineage (`signal_id`/`regime`/`solve_id`, REQ-AUDIT-001) from the start, so controller
  and adapters are shaped for the governed logic before it is wired.
- **Deployment, not fork:** `config` selects `IBKRVenue` (m4mini) or `AlpacaVenue` (other
  fleet machine). Same governed code, different venue/account per `machine_id`.
- **Bug found & fixed during the build:** the pre-existing `ibkr_connection.jl` was dead
  code whose order model didn't match `IBKROrder` (referenced `order.action`, `order.tif`,
  compared an enum to `"LMT"`). Replaced with the order-model-agnostic `reserve_and_place`
  primitive; the canonical translation now lives in `venues/ibkr.jl`.
- **Step 1.5 hardening (review findings):** (1) `execDetails` no longer drops fills —
  the inverted `isready || put!` guard that silently discarded fills when the channel was
  non-empty is replaced with an unconditional `put!` (REQ-AUDIT-001 integrity); (2) market-
  data requests use a separate locked `next_req_id`, so they can no longer race/collide
  with the order-id sequence (REQ-EXEC-001 integrity); (3) the connection is instance-owned
  by `IBKRVenue` (global `_IBKR_CONN` singleton removed), so multiple venues/accounts can
  coexist; (4) fractional-share equity orders are rejected, not silently rounded; (5) no
  export collisions (verified). Open: (#4) all Jib API calls remain unverified until run
  against a paper Gateway.
- **Asset scope:** `venues/ibkr.jl` translates US equities (STK/SMART/USD) to start;
  futures/options/non-US extend the same adapter when those pools go live.
- **Concurrency (I2):** `ExecutionController` is safe for concurrent pool coroutines — a
  `ReentrantLock` guards all shared state and is **never held across I/O** (venue
  submit!/positions, ledger record, audit sink), so the kill switch can't be blocked by an
  in-flight order (preserves GOV-002 bounded time). Submission is reserve→submit→finalize:
  budget reserved under the lock, network submit lock-free, then confirm or roll back.
- **Verified by execution:** the controller logic (all gates, idempotency, reserve/rollback,
  per-pool halt/loss/staleness, reconcile, I1 audit robustness) passes a **30/30 mock-venue
  smoke test** — the first runtime verification in this build. The IBKR *adapter* (Jib) and
  the runner integration remain unverified until a paper Gateway (#4); the formal in-repo
  test suite is step 6.

## Enforcement tiers
**static** (build/CI rule) · **runtime** (assert/guard raises) · **test** (suite assertion) · **manual**

## Conformance states
`holds` · `partial` · **`VIOLATED`** · `unknown` · `unimplemented`
(Conformance is grounded in `CHERRY_PICK_NOTES.md` "Known Remaining Limitations" + direct code reads.)

## Traceability matrix

| REQ-ID | Implementing module(s) | Verifying test(s) | Enforcement | Conformance (2026-07-26) |
|---|---|---|---|---|
| REQ-DATA-001 | `module_1_data` (keyed access), `module_7_execution`; live entry `run_daily_recursive.jl` | `test_module_1.jl`, `test_stratum_i.jl` | static + runtime | unknown — must audit that the execution path (`module_7`) uses keyed state, not bulk `module_1` loads. |
| REQ-DATA-002 | `module_7_execution`, `module_12_sor`; live entry `run_daily_recursive.jl` | `test_stratum_i/ii.jl` | static (import-graph) | unknown — verify exec modules 7/12 do not `include`/`using` research modules (`module_13` backtest). Note the allowed `module_12 → cuopt_bridge.py` HTTP solver seam (see Entrypoints above). |
| REQ-SIM-001 | *(no module is the sole source of "now" — chokepoint absent)* | *(none — see below)* | runtime (sim-clock guard) | unknown — the required **runtime clock chokepoint** was not located in `backtest.jl`, the CV module, or `test_backtest_integrity.jl`. Purged K-Fold is a *different* mechanism (moved to REQ-SIM-003). A system with clean CV can still read a future bar mid-backtest. Audit → probably unimplemented. |
| REQ-SIM-002 | `module_13_portfolio/backtest.jl`; per-venue semantics in `module_6_cascade`, `module_9_0dte` | `test_backtest_integrity.jl` | test | unknown — confirm next-bar-open (not same-bar) **and** define per-pool/venue bar semantics first (0DTE = 1-min ORB @ 09:30–10:00 ET; commodities = 23-hr session; crypto = discrete windows). Test must not universalize one venue. |
| REQ-SIM-003 | `module_11_cv` (purged K-Fold/CPCV) | `test_backtest_integrity.jl`, `scripts/backtest_validation.jl` | test | holds — purged K-Fold/CPCV removes cross-fold label leakage (López de Prado); MAE stored to governance computed on clean folds. *(This is the requirement the purged-CV mechanism was actually satisfying — previously credited to REQ-SIM-001 by mistake.)* |
| REQ-RISK-001 | `module_13_portfolio` (PortfolioOpt), `module_6_cascade` (parallel pools) | `test_module_6.jl`, `test_stress.jl` | design + test | unknown — parallel-pool implementation present; verify no concurrent solves against one pool's budget. |
| REQ-RISK-002 | `module_13_portfolio` (`costaware`, `robust`), `module_10_feedback` | *(none — module 13 untested)* | test + runtime | unknown — reject/zero-with-named-reason not confirmed; **module 13 has no unit test.** |
| REQ-RISK-003 | `execution_controller.jl` (`submit_governed!` budget gate, `set_pool_budget!`), `module_6_cascade` (sizing) | *(none — step 6)* | runtime (gate) | partial — **step 4:** per-pool daily gross-notional budget enforced at the controller gate *before* emission (rejects on breach; rejects if a budgeted pool's order has no price to size against). Model is turnover-based (daily gross notional); a net-exposure model can replace it. Test pending. |
| REQ-EXEC-001 | `venues/ibkr.jl` (`submit!`), `ibkr_connection.jl` (`reserve_and_place`), `execution_controller.jl` | *(test pending — step 6)* | runtime (lock) + test | partial — **step 1 done:** venue interface + real IBKR adapter built; submission serialized + order-id allocation atomic under one lock (`reserve_and_place`). Legacy simulated `send_order` retained. Serial-*per-pool* (vs per-connection) + test still open. |
| REQ-AUDIT-001 | `module_10_feedback/execution_ledger.jl` (`FillRecord` + schema/migration), `execution_controller.jl` (`process_fills!` supplies lineage) | *(none — module 10 untested, step 6)* | runtime (write-path assert) | partial — **step 3:** the VIOLATION is fixed. `FillRecord` now has `signal_id/regime/solve_id/order_id`; the write-path constructor **rejects empty lineage**, so a lineage-less fill is structurally unrecordable. Remaining: wire `process_fills!` output → `record_fill` in the daily runner (integration) + test. |
| REQ-AUDIT-002 | `execution_controller.jl` (`submit_governed!` gate) | *(none — step 6)* | runtime (reject on incomplete lineage) | partial — **step 3:** gate implemented — an order missing `signal_id/regime/solve_id` is rejected (`:rejected`) at the controller, never sent. Test pending. |
| REQ-REGIME-001 | `module_4_arma`, `module_5_dpm`, `module_6_cascade`; logging via `module_8_governance` | `test_module_4/5/6.jl` | runtime | holds (impl) — regime machinery is the system core and is tested. Confirm every transition is written to the governance audit log. |
| REQ-GOV-001 | `module_8_governance` (SQLite version registry, JLD2 serialize/rollback) | `test_module_8.jl` | runtime | holds — version registry + serialize/deserialize + rollback implemented and tested. |
| REQ-DATA-003 *(live-capital)* | `execution_controller.jl` (`set_pool_staleness!`, `mark_data_fresh!`, gate), `module_1_data` (detection) | *(none — step 6)* | runtime (block on stale) | partial — **step 5:** gate blocks emission for a pool whose feed is older than its threshold (transient — auto-recovers when fresh data is marked; if never marked, treated as stale). The engine calls `mark_data_fresh!` from module_1; that wiring is integration. Test pending. |
| REQ-RISK-004 *(live-capital)* | `execution_controller.jl` (`update_pnl!`, `halt_pool!`, `resume_pool!`, `set_pool_loss_limit!`) | *(none — step 6)* | runtime (loss halt) | partial — **step 4:** per-pool daily loss limit implemented — `update_pnl!` halts a pool on breach; the pool stays halted (gate rejects its orders) until an explicit, logged `resume_pool!` (a new day via `reset_daily!` does NOT auto-lift). PnL is engine-supplied (controller can't compute cost basis). Test pending. |
| REQ-EXEC-002 *(live-capital)* | `execution_controller.jl` (`submit_governed!`, `rehydrate!`), `venues/ibkr.jl` (`orderRef`) | *(none — step 6)* | runtime (idempotency key) | partial — **step 2:** in-process dedup on `client_order_id` (replay returns prior ack, no re-submit); key stamped as IBKR `orderRef` so the broker carries it. Cross-restart idempotency needs `rehydrate!` fed from the persisted ledger (step 3). |
| REQ-EXEC-003 *(live-capital)* | `execution_controller.jl` (`reconcile!`, `process_fills!`, `apply_fill!`), `venues/ibkr.jl` (`positions`, `drain_fills`) | *(none — step 6)* | runtime (reconcile + halt) | partial — **step 2 + 3 (F1 fixed):** `expected` is now driven from actual FILLS (`process_fills!`/`apply_fill!`), not submitted orders, so `reconcile!` no longer false-halts on working/partial orders — it is now operational. **Step 4:** halt is now per-pool (a diverging symbol halts its own pool via `symbol_pool`; an unattributable symbol triggers a fail-safe controller-wide halt). Test pending. |
| REQ-GOV-002 *(live-capital)* | `execution_controller.jl` (`halt!`/`resume!`/`halt_pool!`/`resume_pool!`, `audit` sink), `module_8_governance` | *(none — step 6)* | runtime (bounded-time halt) | partial — **step 5:** kill switch enforced (checked synchronously in `submit_governed!`; bounded to ≤1 in-flight order via the venue lock). All halt/resume events go to an `audit` sink; the runner wires it to the module_8 governance log (that wiring is integration). Test pending. |

## Test coverage map (existing suite → strata)

- **Module unit tests:** `test_module_1..8.jl` — modules **1–8 covered; 9–13 have no dedicated unit test.**
- **Strata:** `test_stratum_i.jl`, `test_stratum_ii.jl` (structural + computational strata).
- **Integrity/risk:** `test_backtest_integrity.jl`, `test_stress.jl`, `test_stress_scenarios.jl`, `test_integration.jl`, `test_geometric_consistency.jl`.

## Coverage gap (the real Phase-2 backlog)

The invariants most at risk are the ones landing in **untested modules 9–13**:
REQ-AUDIT-001 (mod 10), REQ-RISK-001/002 (mod 13), execution/SOR (mod 12), 0DTE (mod 9).
These are the newest modules (Deepseek-v2 additions and extensions) and carry no unit
tests. Coverage here is prioritized over the already-tested regime/data modules.

**Live-capital invariants (REQ-DATA-003, REQ-RISK-004, REQ-EXEC-002/003, REQ-GOV-002)**
are mostly `unimplemented` or `partial`. Two must be designed *into* the coming `Jib.jl`
execution work rather than retrofitted: **REQ-EXEC-002 (idempotency)** — the reconnect
loop is where duplicate orders are born, so idempotency keys have to exist before the
real broker path goes live — and **REQ-EXEC-003 (reconciliation)**. These are the reason
the `send_order` replacement is not a drop-in.

## Known limitations carried from CHERRY_PICK_NOTES.md (authoritative gap list)

1. `module_5` weighted M-step updates μ/σ² only, not full ARMA coefficients (approx at init).
2. `module_5` regime likelihood uses mean+vol_scale, not full ARMA-GARCH conditional (cost).
3. `module_7` `send_order` **simulated** — replace with `Jib.jl`/TWS (REQ-EXEC-001 live gap).
4. `module_8` serialization now JLD2-backed (resolved in Deepseek-v2).
5. `module_1` feeds wired to real endpoints (resolved in Deepseek-v2).

## Design appendices
`docs/appendices/`: `BlaqueBaux_GammaARMA_Framework.docx`, `BlaqueBaux_GammaARMA_v2.docx`,
`BlaqueBaux_StatisticalArchitecture.docx`, `BlaqueBaux_PreDist_Review_Appendix.docx`.
