# Blaque Baux — Design & Traceability

**Version:** 0.3 · **Last updated:** 2026-07-06 · **Base:** CherryPick (2026-05-31, Julia)

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

## Enforcement tiers
**static** (build/CI rule) · **runtime** (assert/guard raises) · **test** (suite assertion) · **manual**

## Conformance states
`holds` · `partial` · **`VIOLATED`** · `unknown` · `unimplemented`
(Conformance is grounded in `CHERRY_PICK_NOTES.md` "Known Remaining Limitations" + direct code reads.)

## Traceability matrix

| REQ-ID | Implementing module(s) | Verifying test(s) | Enforcement | Conformance (2026-07-06) |
|---|---|---|---|---|
| REQ-DATA-001 | `module_1_data` (keyed access), `module_7_execution`; live entry `run_daily_recursive.jl` | `test_module_1.jl`, `test_stratum_i.jl` | static + runtime | unknown — must audit that the execution path (`module_7`) uses keyed state, not bulk `module_1` loads. |
| REQ-DATA-002 | `module_7_execution`, `module_12_sor`; live entry `run_daily_recursive.jl` | `test_stratum_i/ii.jl` | static (import-graph) | unknown — verify exec modules 7/12 do not `include`/`using` research modules (`module_13` backtest). Note the allowed `module_12 → cuopt_bridge.py` HTTP solver seam (see Entrypoints above). |
| REQ-SIM-001 | *(no module is the sole source of "now" — chokepoint absent)* | *(none — see below)* | runtime (sim-clock guard) | unknown — the required **runtime clock chokepoint** was not located in `backtest.jl`, the CV module, or `test_backtest_integrity.jl`. Purged K-Fold is a *different* mechanism (moved to REQ-SIM-003). A system with clean CV can still read a future bar mid-backtest. Audit → probably unimplemented. |
| REQ-SIM-002 | `module_13_portfolio/backtest.jl`; per-venue semantics in `module_6_cascade`, `module_9_0dte` | `test_backtest_integrity.jl` | test | unknown — confirm next-bar-open (not same-bar) **and** define per-pool/venue bar semantics first (0DTE = 1-min ORB @ 09:30–10:00 ET; commodities = 23-hr session; crypto = discrete windows). Test must not universalize one venue. |
| REQ-SIM-003 | `module_11_cv` (purged K-Fold/CPCV) | `test_backtest_integrity.jl`, `scripts/backtest_validation.jl` | test | holds — purged K-Fold/CPCV removes cross-fold label leakage (López de Prado); MAE stored to governance computed on clean folds. *(This is the requirement the purged-CV mechanism was actually satisfying — previously credited to REQ-SIM-001 by mistake.)* |
| REQ-RISK-001 | `module_13_portfolio` (PortfolioOpt), `module_6_cascade` (parallel pools) | `test_module_6.jl`, `test_stress.jl` | design + test | unknown — parallel-pool implementation present; verify no concurrent solves against one pool's budget. |
| REQ-RISK-002 | `module_13_portfolio` (`costaware`, `robust`), `module_10_feedback` | *(none — module 13 untested)* | test + runtime | unknown — reject/zero-with-named-reason not confirmed; **module 13 has no unit test.** |
| REQ-RISK-003 | `module_6_cascade` (APAC/EMEA/US sizing), `module_7_execution` | `test_module_6.jl` | runtime (gate) | partial — regional cascade sizing exists; per-pool budget enforced *at the gate before emission* not yet confirmed. |
| REQ-EXEC-001 | `module_7_execution/ibkr_connection.jl`, `module_12_sor` | `test_module_7.jl` | runtime (`ReentrantLock`) + test | partial — thread-safe serial submission mechanism present (`ReentrantLock`, reconnect loop). BUT `send_order` is **simulated** (notes limitation #3); live TWS path (`Jib.jl`) not wired. Serialization holds; live execution unproven. |
| REQ-AUDIT-001 | `module_10_feedback/execution_ledger.jl` (`FillRecord`, `ExecutionLedger`) | *(none — module 10 untested)* | runtime | **VIOLATED** — `FillRecord` carries execution-quality fields (impact, ADV, σ, materiality) but **no decision lineage**: missing `signal_id`, `regime`, `solve_id`, `order_id`. Ledger records *how well* a fill executed, not *what caused it*. |
| REQ-AUDIT-002 | `module_10_feedback`, `module_7_execution` (gate) | *(none)* | runtime (reject on incomplete lineage) | unimplemented — no pre-emission lineage gate. Blocked on REQ-AUDIT-001 (fields must exist first). |
| REQ-REGIME-001 | `module_4_arma`, `module_5_dpm`, `module_6_cascade`; logging via `module_8_governance` | `test_module_4/5/6.jl` | runtime | holds (impl) — regime machinery is the system core and is tested. Confirm every transition is written to the governance audit log. |
| REQ-GOV-001 | `module_8_governance` (SQLite version registry, JLD2 serialize/rollback) | `test_module_8.jl` | runtime | holds — version registry + serialize/deserialize + rollback implemented and tested. |
| REQ-DATA-003 *(live-capital)* | `module_1_data` (staleness detection) | *(none)* | runtime (halt on stale) | partial — module 1 has staleness detection, but whether the **execution path halts** (not warns) on a per-venue threshold is unconfirmed. |
| REQ-RISK-004 *(live-capital)* | `module_7_execution` (4-state circuit breaker), `module_8_governance` | `test_module_7.jl` (breaker) | runtime (loss halt) | unknown — a circuit breaker exists; a **per-pool daily loss limit + logged human re-enable** is not confirmed as implemented. |
| REQ-EXEC-002 *(live-capital)* | `module_7_execution/ibkr_connection.jl` (reconnect loop) | *(none)* | runtime (idempotency key) | **unimplemented / high-risk** — the reconnect loop exists; nothing makes submission idempotent. This is the most dangerous gap the moment `Jib.jl` replaces the simulated `send_order`. Must shape that work, not chase it. |
| REQ-EXEC-003 *(live-capital)* | `module_7_execution`, `module_10_feedback` (ledger) | *(none)* | runtime (reconcile + halt) | unimplemented — no position reconciliation against broker-reported state. |
| REQ-GOV-002 *(live-capital)* | `module_7_execution` / `module_8_governance` | *(none)* | runtime (bounded-time halt) | unimplemented — no manual kill switch with audit-logged halt. |

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
