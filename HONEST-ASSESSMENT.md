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
- **The live-capital invariants that make live trading safe are mostly unbuilt.**
  [verified] REQ-EXEC-002 (idempotency), REQ-EXEC-003 (reconciliation), REQ-GOV-002 (kill
  switch) are `unimplemented`; REQ-RISK-004 (loss halt) and REQ-DATA-003 (staleness halt)
  are `unknown`/`partial`. **Going live before these exist is the headline risk.**
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
- **CV methodology is sound** [verified] — purged K-Fold prevents the fold-leakage that
  inflates most naive backtests. This is a credibility asset; it is separately true from
  the runtime look-ahead question (REQ-SIM-001), which is **not** protected — a backtest
  run could still read a future bar mid-loop (no sim-clock chokepoint found).

## Spec-vs-code summary (mirrors design.md, 2026-07-06)

- **1 VIOLATED:** REQ-AUDIT-001 — `FillRecord` has no decision lineage (P0 fix pending).
- **~6 unimplemented/unknown live-capital invariants** (see above).
- **holds:** REQ-GOV-001 (version registry), REQ-SIM-003 (CV), REQ-REGIME-001 (impl).
- **Test coverage cliff:** modules 1–8 tested (~650 cases); modules 9–13 (incl. the
  execution ledger and portfolio/risk optimizers) have no dedicated unit tests.

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
