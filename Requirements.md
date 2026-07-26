# Blaque Baux — Requirements

**Version:** 0.3 · **Last updated:** 2026-07-26 · **Status:** Phase 1 seed · **Base:** CherryPick (Julia)
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

**REQ-DATA-002** *[INVARIANT]* — No module on the order path depends on the
research / analytics stratum. The dependency graph reachable from the live execution
entrypoint must not reach research-stratum code.
*(De-mechanized: the specific engine — DuckDB, Parquet, the Julia backtest stack — is a
mechanism named in `design.md`, not here. The one permitted cross-language seam on the
order path, the SOR → cuOpt solver, is a solver dependency, not a research dependency;
see `design.md`.)*

**REQ-DATA-003** *[INVARIANT]* *(added Phase 1)* — The execution path must not act on
market data older than a per-venue staleness threshold. A stale feed halts emission for
the affected pool; it does not warn and proceed. (A frozen feed still serving the last
tick during a 23-hour commodities or discrete crypto window is a realistic failure mode.)

### Simulation integrity

**REQ-SIM-001** *[INVARIANT]* — During a backtest run, no component may consume market
data timestamped later than the simulation clock's current time. This is a **runtime
chokepoint**: any data access checked against the sim clock; a future-dated request
raises, never warns. (Distinct from CV leakage — see REQ-SIM-003.)

**REQ-SIM-002** *[INVARIANT]* — In backtest, a decision made on a bar fills at the
**next** bar's open. Same-bar fills are prohibited. "Next bar" is defined per pool/venue
(equities session, 23-hour commodities, discrete crypto windows, 0DTE ORB) — the
per-venue bar semantics must be specified before this requirement's test is written, so
the test does not encode one venue's assumption as universal.

**REQ-SIM-003** *[INVARIANT]* *(added Phase 1)* — Model validation uses leakage-free
cross-validation: no label or observation may leak across CV folds (purged K-Fold / CPCV
per López de Prado). A performance estimate computed on leaked folds is invalid and must
not be recorded to governance. (This protects research methodology at fold-construction
time — a different mechanism from REQ-SIM-001's runtime clock.)

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

**REQ-RISK-004** *[INVARIANT]* *(added Phase 1 — live-capital)* — Each pool has a daily
loss limit. On breach, new order emission for that pool halts until an explicit, logged
human re-enable. Nothing else in this set stops a correctly-serialized, fully-lineaged,
regime-authorized system from losing money continuously all day; this does.

### Execution

*Execution is venue-agnostic: the engine talks to a broker only through the
`ExecutionVenue` interface, and all order-path invariants below are enforced in the
venue-agnostic `ExecutionController` (built once). IBKR is the first adapter; Alpaca is a
later adapter, selected by deployment config — not a code fork. See `design.md`.*

**REQ-EXEC-001** *[INVARIANT]* — Order submission to the execution venue is strictly
serial within a pool. At most one submission for a given pool is outstanding at a time.

**REQ-EXEC-002** *[INVARIANT]* *(added Phase 1 — live-capital)* — Order submission is
idempotent across reconnects. A retry after connection loss must not double-submit. The
reconnect loop is exactly where duplicate orders are born; per-pool serialization does
not address it. This must shape the real-TWS (`Jib.jl`) implementation, not chase it.

**REQ-EXEC-003** *[INVARIANT]* *(added Phase 1 — live-capital)* — Internal position
state reconciles against broker-reported state on a defined cadence. Unexplained
divergence halts emission for the affected pool. Ledger-vs-broker drift is the classic
silent failure of small live systems.

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

### Governance

**REQ-GOV-001** *[INVARIANT]* — Every model version placed into service is recorded in
the version registry and is rollback-able to a prior serialized state. No model runs in
production without a registry entry.

**REQ-GOV-002** *[INVARIANT]* *(added Phase 1 — live-capital)* — A manual kill switch
stops all new order emission within a bounded time, and the halt event is itself
audit-logged. Cheap to specify now; miserable to retrofit under stress.

---

## 2. Features

*(Seed section — to be expanded. Features describe desired behavior that, if violated,
degrades the system but does not breach a safety guarantee.)*

**REQ-FEAT-001** *[FEATURE]* — The live runner supports the canonical pool set
(equities APAC/EMEA/US, commodities, crypto, DTE overlay) as independently schedulable units.

**REQ-FEAT-002** *[FEATURE]* — The research stratum can reproduce a walk-forward backtest
end to end (`scripts/backtest_validation.jl`) against cached data.

---

## Change log

| Date | REQ(s) | Change | Class |
|---|---|---|---|
| 2026-07-06 | DATA/SIM/RISK/EXEC/AUDIT/REGIME 00x | Initial seed of 10 invariants from integration plan | INVARIANT |
| 2026-07-06 | REQ-AUDIT-002 | Added: lineage completeness as precondition of order emission | INVARIANT |
| 2026-07-06 | REQ-RISK-001 | Reworded to state the guarantee, not the mechanism | INVARIANT |
| 2026-07-06 | REQ-GOV-001 | Added: model version registry + rollback (maps to module_8_governance) | INVARIANT |
| 2026-07-06 | all | Re-based on CherryPick (Julia). Module mappings/conformance now in design.md | — |
| 2026-07-06 | REQ-DATA-002 | De-mechanized: removed named engine (DuckDB); anchor fixed to the Julia live entrypoint | INVARIANT |
| 2026-07-06 | REQ-SIM-001 | Clarified as a runtime clock chokepoint (distinct from CV leakage) | INVARIANT |
| 2026-07-06 | REQ-SIM-002 | Added per-pool/venue bar-semantics precondition before test | INVARIANT |
| 2026-07-06 | REQ-SIM-003 | Added: leakage-free CV (purged K-Fold/CPCV) — was protecting the system with no REQ | INVARIANT |
| 2026-07-06 | REQ-DATA-003, REQ-RISK-004, REQ-EXEC-002/003, REQ-GOV-002 | Added five live-capital invariants (staleness halt, loss halt, idempotent submission, reconciliation, kill switch) | INVARIANT |
| 2026-07-06 | REQ-FEAT-002 | Fixed stale `run_phase1.py` anchor → `backtest_validation.jl` | FEATURE |
| 2026-07-26 | REQ-EXEC-001 | De-mechanized IBKR → "execution venue"; execution is now venue-agnostic (adapter pattern) | INVARIANT |
