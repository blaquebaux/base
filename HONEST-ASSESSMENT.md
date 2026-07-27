# Blaque Baux — Honest Assessment

**Version:** 0.1 · **Last updated:** 2026-07-06 · **Owner:** C. Warrens

The conformance column in `design.md` tracks **spec-vs-code** truth. This file tracks the
**wider claims** — what is live vs. paper, what is measured vs. asserted — the things a
capital allocator's diligence asks that a traceability matrix does not. It is maintained
by the weekly SmallClaw spec-audit job (`scripts/spec_audit.sh`), which appends dated
findings; anything above the machine-appended section is human-owned narrative.

Discipline: every claim here is tagged **[verified]** (checked against code/tests this
date), **[asserted]** (documented but not independently verified), or **[unknown]**.

## Live vs. paper

- **Order execution is PAPER, not live.** [verified] `module_7` `send_order` is a
  simulation (CHERRY_PICK_NOTES limitation #3). The real broker path (`Jib.jl`/TWS) is
  referenced but not wired. No real capital has been routed by this codebase.
- **The live-capital invariants now have enforcement logic (controller-verified), but the
  live path is not proven.** [verified 2026-07-26] EXEC-001/002/003, RISK-003/004,
  DATA-003, GOV-002, AUDIT-001/002 are all implemented in the governed controller and pass a
  committed 34/34 test suite (`test/test_execution_controller.jl`), including a 4-thread
  concurrency stress test. What is NOT yet proven: the IBKR adapter's Jib calls (#4) and the
  runner integration that feeds PnL/staleness/fills and wires the audit + ledger. **The
  headline risk is now integration + adapter verification, not missing controls.**
- **Data feeds are partially real.** [asserted, per CHERRY_PICK_NOTES] Cboe/FRED/Deribit/
  TGA endpoints wired (Deepseek-v2); but OIS-SOFR is a 5bps placeholder and GSW zero-coupon
  yields require a manual Fed download (FRED DGS = par yields, not zero). Treat any curve-
  dependent result as approximate until these are sourced.

## Measured vs. asserted performance

- **No backtest performance numbers are verified in this repo as of this date.** [unknown]
  There is a walk-forward harness (`backtest_validation.jl`, purged K-Fold/CPCV — good
  methodology, REQ-SIM-003 holds), but this assessment does not yet record actual vs.
  target Sharpe / MAE / hit-rate. **Do not cite performance figures externally until a
  dated run is recorded here.** ← open item, owner: C. Warrens.
- **Execution controller logic is runtime-verified** [verified 2026-07-26] — the
  venue-agnostic governed controller (all order-path gates, idempotency incl. the uncertain
  path, budget reserve/rollback, per-pool loss/staleness halts, per-pool reconciliation,
  concurrency lock, audit-sink robustness) passes a committed 34/34 suite
  (`test/test_execution_controller.jl`) including a 4-thread concurrency stress test. This is
  logic-level verification only: the IBKR adapter (Jib TWS calls) and end-to-end
  integration remain [unknown] until run against a paper Gateway.
- **CV methodology is sound** [verified] — purged K-Fold prevents the fold-leakage that
  inflates most naive backtests. This is a credibility asset; it is separately true from
  the runtime look-ahead question (REQ-SIM-001), which is **not** protected — a backtest
  run could still read a future bar mid-loop (no sim-clock chokepoint found).

## Spec-vs-code summary (mirrors design.md, 2026-07-26)

- **0 VIOLATED.** REQ-AUDIT-001 fixed (FillRecord carries + requires lineage).
- **holds:** REQ-GOV-001 (version registry), REQ-SIM-003 (CV), REQ-REGIME-001 (impl).
- **partial (enforced in the controller, logic verified by the 30/30 smoke test; formal
  test + adapter/integration pending):** AUDIT-001/002, EXEC-001/002/003, RISK-003/004,
  DATA-003, GOV-002.
- **unimplemented / unknown:** SIM-001 (runtime clock chokepoint), SIM-002 (per-venue bar
  semantics), DATA-001/002 (import-boundary lint), RISK-001/002 (module 13 concurrency /
  reject-reasons).
- **Test coverage:** modules 1–8 tested (~650 cases) + the governed execution controller
  (34/34, `test_execution_controller.jl`). Still untested: the module 9–13 *internals*
  (module 10 ledger SQLite, 11 CV, 12 SOR, 13 portfolio/risk) — the controller test uses a
  mock venue and does not exercise them.

## What this means for VC / allocator conversations

- **Honest framing:** a mature, well-tested *research and modeling* system with a
  documented, disciplined methodology; a *simulated* execution layer; and a written,
  prioritized path to live-safe execution. That is a stronger and more credible position
  than an unqualified "production trading system" claim, and it is the framing the
  traceability matrix lets you defend line by line.
- **Do not claim** live trading, verified live P&L, or specific performance numbers until
  the corresponding rows here move to [verified].

---

## Machine-appended findings (SmallClaw spec-audit)

<!-- scripts/spec_audit.sh appends dated blocks below this line. Do not edit by hand. -->

### spec-audit — 2026-07-06

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ⚠️ STALE: design.md matrix last updated 2026-07-06 (20d ago) — exceeds 2w; re-verify conformance cells.

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl test_module_7.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl test_module_7.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 15
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl test_module_7.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)

### spec-audit — 2026-07-26

- invariants defined: 18 · in matrix: 18 · modules: 13 · tests: 16
- ✓ every invariant is in the matrix
- ✓ every module is claimed or acknowledged
- ✓ all cited tests exist
- ℹ️ test files not yet cited by a REQ:test_module_2.jl test_module_3.jl test_module_7.jl 
- ℹ️ features not in matrix (informational):REQ-FEAT-001 REQ-FEAT-002 
- ✓ matrix fresh (0d)
