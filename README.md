# Blaque Baux — Canonical Repository

This is the consolidated, version-controlled root for the Blaque Baux algorithmic
trading system. It was assembled from three previously divergent, uncommitted trees
(`blaque_baux-v1`, `blaque_baux-v2`, `blaque_baux_polyglot`) that turned out to be
**complementary strata of one system**, not competing versions.

## The three strata

| Stratum | Directories | Role | Source tree |
|---|---|---|---|
| **Execution (hot path)** | `ibkr/`, `orchestration/`, `run_live.py` | Live order submission, per-pool coordination, circuit breakers | ex-`v1` |
| **Research (cold path)** | `data/`, `signal/`, `optimizer/`, `backtest/`, `run_phase1.py` | Signal generation, QP optimization, backtesting, analytics | ex-`v2` |
| **Target architecture** | `polyglot/` | Julia optimizer, Rust signal engine, Hy rule gate + integration bridges — the migration destination | ex-`polyglot` |

The boundary between the Execution and Research strata is not incidental — it is the
subject of the system's hardest safety invariants (see `Requirements.md`, REQ-DATA-001
and REQ-DATA-002). The two strata were never previously in the same repository;
consolidating them here is the first time a cross-stratum import is even *possible*,
which is exactly why the spec layer and its enforcement rules now matter.

## The spec stack

This repo carries a requirements/traceability layer on top of the existing design docs:

- **`Requirements.md`** — invariants first (the things that must never be violated,
  each with a `REQ-ID`), features second. Append-only.
- **`design.md`** — architecture + the **traceability matrix** (REQ → module → test →
  conformance → enforcement). References the existing framework documents as appendices.
- **`tasks.md`** — the Phase 2 backlog, derived from empty test cells and open conformance gaps.
- **`TESTPLAN.md`** — how each REQ is verified.
- **`DOCUMENT-CONTROL.md`** — versioning, change-log, and sign-off rules.

## Component READMEs

- `README-v2-python.md` — original research-stratum README
- `polyglot/README-polyglot.md` — original target-architecture README

## Status

Phase 1 (spec skeleton + consolidation) — in place. See `tasks.md` for open work.
