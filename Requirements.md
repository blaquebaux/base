# Blaque Baux — Requirements

**Version:** 0.1 · **Last updated:** 2026-07-06 · **Status:** Phase 1 seed
**Discipline:** Append-only. REQ-IDs are permanent (see `DOCUMENT-CONTROL.md`).

This document states *what* must be true, not *how* it is achieved. Implementation
mechanisms (mutexes, actors, queues, lint rules) live in `design.md`. Requirements are
written so they do not need editing when a mechanism changes.

Each requirement has a **class**:
- **[INVARIANT]** — must never be violated. Changing one requires sign-off (see Document Control).
- **[FEATURE]** — desired behavior; ordinary change discipline.

Current conformance for each REQ is tracked in the traceability matrix in `design.md`,
not here — this document states the target, not today's state.

---

## 1. Invariants

### Data / stratum boundary

**REQ-DATA-001** *[INVARIANT]* — On the execution (hot) path, market and reference
data is obtained only by keyed lookups against the hot store. The execution path
performs no bulk loads, table scans, or aggregations to make a trading decision.

**REQ-DATA-002** *[INVARIANT]* — No module on the order path depends on the analytics
engine (the DuckDB / Julia backtest stack, or any bulk-load data facility built for
research). The dependency graph from the live entrypoint (`run_live.py`) must not
reach research-stratum code.

### Simulation integrity

**REQ-SIM-001** *[INVARIANT]* — No component may consume market data timestamped later
than the simulation clock's current time. A look-ahead access raises an error; it must
never merely warn or silently proceed.

**REQ-SIM-002** *[INVARIANT]* — In backtest, a decision made on a bar fills at the
**next** bar's open. Same-bar fills are prohibited.

### Risk / optimization

**REQ-RISK-001** *[INVARIANT]* — For any single pool, no two QP solves against that
pool's risk budget may be in flight at the same time. Solves against one pool's budget
are ordered.
*(The plan's phrasing "impossible by construction" is a mechanism; the mechanism —
single-coroutine-per-pool or an explicit lock — is specified in `design.md`.)*

**REQ-RISK-002** *[INVARIANT]* — Every candidate the optimizer rejects or zeroes out
carries a named, machine-readable reason, written to the audit trail. No silent drops.

**REQ-RISK-003** *[INVARIANT]* — The per-pool risk budget (APAC / EMEA / US, and each
other pool) is enforced at the Trader gate, before an order is emitted — not by any
downstream component after emission.

### Execution

**REQ-EXEC-001** *[INVARIANT]* — Order submission to IBKR is strictly serial within a
pool. At most one submission for a given pool is outstanding at a time.

### Audit / lineage

**REQ-AUDIT-001** *[INVARIANT]* — Every fill row carries full lineage: signal ID →
regime state → QP solve ID → order ID. A fill with any lineage field missing is a
defect.

**REQ-AUDIT-002** *[INVARIANT]* *(added Phase 1)* — An order missing any lineage field
is **rejected at the Trader gate and never submitted** — not logged-and-sent. This is
the enforcement complement to REQ-AUDIT-001: audit completeness is a precondition of
emission, not a post-hoc annotation.

### Regime

**REQ-REGIME-001** *[INVARIANT]* — Regime transitions (Gamma-ARMA) gate strategy
activation, and every transition is itself written to the audit log. No strategy
activates outside the regime that authorizes it.

---

## 2. Features

*(Seed section — to be expanded. Features describe desired behavior that, if violated,
degrades the system but does not breach a safety guarantee.)*

**REQ-FEAT-001** *[FEATURE]* — The live runner supports the canonical pool set
(equities APAC/EMEA/US, commodities, crypto, DTE overlay) as independently schedulable units.

**REQ-FEAT-002** *[FEATURE]* — The research stratum can reproduce a Phase 1 backtest
end to end from `run_phase1.py` against cached data.

---

## Change log

| Date | REQ(s) | Change | Class |
|---|---|---|---|
| 2026-07-06 | DATA/SIM/RISK/EXEC/AUDIT/REGIME 00x | Initial seed of 10 invariants from integration plan | INVARIANT |
| 2026-07-06 | REQ-AUDIT-002 | Added: lineage completeness as precondition of order emission | INVARIANT |
| 2026-07-06 | REQ-RISK-001 | Reworded to state the guarantee, not the mechanism | INVARIANT |
