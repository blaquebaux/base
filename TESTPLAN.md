# Blaque Baux — Test Plan

**Version:** 0.2 · **Last updated:** 2026-07-06 · **Base:** CherryPick (Julia)

The system ships with ~650 test cases / ~280 test sets (`julia --project=. test/runtests.jl`).
This plan maps requirements onto that existing suite and names the gaps to fill.

## Enforcement → verification

| Tier | Verified by | Example |
|---|---|---|
| static | CI rule fails build on violation | REQ-DATA-002 import-graph check |
| runtime | assert/guard raises; a test triggers it | REQ-SIM-001 look-ahead raises |
| test | suite assertion | REQ-SIM-002 next-bar fill |

## Per-requirement verification (existing test → gap)

| REQ-ID | Existing coverage | Gap to close |
|---|---|---|
| REQ-DATA-001 | `test_module_1.jl`, `test_stratum_i.jl` | Assert execution path uses keyed state, not bulk load. |
| REQ-DATA-002 | `test_stratum_i/ii.jl` (partial) | Add import-graph test: exec modules ↛ backtest/analytics. |
| REQ-SIM-001 | `test_backtest_integrity.jl` (purged K-Fold) | Assert look-ahead access **raises**, not warns. |
| REQ-SIM-002 | `test_backtest_integrity.jl` | Assert fill at next-bar open, never same-bar. |
| REQ-RISK-001 | `test_module_6.jl`, `test_stress.jl` | Add `module_13` test: no concurrent solves per pool budget. |
| REQ-RISK-002 | — (module 13 untested) | New `test_module_13.jl`: every reject/zero emits a named reason. |
| REQ-RISK-003 | `test_module_6.jl` | Assert budget enforced at gate before emission. |
| REQ-EXEC-001 | `test_module_7.jl` | Add serial-submission test on the real (non-simulated) path. |
| REQ-AUDIT-001 | — (module 10 untested) | New `test_module_10.jl`: every `FillRecord` carries signal/regime/solve/order IDs. |
| REQ-AUDIT-002 | — | New: order with missing lineage is rejected, not sent. |
| REQ-REGIME-001 | `test_module_4/5/6.jl` | Assert every transition is written to the governance audit log. |
| REQ-GOV-001 | `test_module_8.jl` | Covered — version registry + rollback tested. |

## Priority

Follow `tasks.md`: **P0** add `FillRecord` lineage (REQ-AUDIT-001) and its `test_module_10`,
then the untested modules 9–13, then audit the `unknown` rows. The already-tested regime,
governance, and data modules (1–8) are the last priority — they hold.

## Regression baseline

`julia --project=. test/runtests.jl` must stay green through every change — it is the
proof that spec work did not regress the 650-case suite. `backtest_validation.jl` is the
pre-deployment gate (purged K-Fold MAE on clean folds).
