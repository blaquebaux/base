# Document Control

Governs the spec-stack documents in this repository. Structure adapted from the
reference doc set (nycsav/IBM-WatsonX-AI-Agent-Workshop), with additions specific
to a live-capital trading system.

## Controlled documents

| Doc | Purpose | Change discipline |
|---|---|---|
| `Requirements.md` | Invariants + features, each with a REQ-ID | **Append-only.** REQ-IDs are never reused or renumbered. |
| `design.md` | Architecture + traceability matrix | Editable; matrix rows track live status. |
| `tasks.md` | Work backlog | Editable. |
| `TESTPLAN.md` | Verification approach per REQ | Editable. |
| `DOCUMENT-CONTROL.md` | This file | Editable via change log below. |

## Requirement classes and change bar

Requirements are split into two classes, and they are **not** changed with the same
ceremony:

- **Invariant** (`must never be violated`) — changing, weakening, or removing an
  invariant REQ requires an explicit, dated sign-off entry in the change log below,
  naming the approver and the rationale. Invariants govern capital safety; they do
  not change silently as a side effect of a code change.
- **Feature** (`should`) — may be revised with an ordinary change-log line.

## Approver & sign-off (solo-founder shop)

Self-sign-off is permitted — but an invariant change is not casual, so it carries two
mechanical frictions that do not block an override, only slow a careless one:

1. **Cool-down.** An invariant weakening or removal may not be signed the same day it is
   proposed. The change-log row records both the *proposed* date and the *signed* date;
   they must differ.
2. **Cadence countersign.** One of the Cadence reviewer models must produce a written
   objection-or-concur memo on the proposed change; the memo is linked in the change-log
   row. A concur is not required — a recorded objection that the approver overrides is a
   valid, audited outcome. The point is that no invariant changes without a second read.

**Approver of record:** Carter Warrens (solo founder). Adding, *strengthening*, or
*newly implementing* an invariant needs only an ordinary signed row (no cool-down) —
the frictions apply to weakening safety, not increasing it.

## Versioning

- Each controlled doc carries a version and last-updated date in its header.
- Changes are recorded append-only in that doc's change log (or here for cross-cutting changes).
- REQ-IDs are permanent. A retired requirement is marked `SUPERSEDED by REQ-XXX`, never deleted.

## Change log

| Date (proposed → signed) | Doc(s) | Change | Class | Approver | Cadence memo |
|---|---|---|---|---|---|
| 2026-07-06 → 2026-07-06 | all | Initial spec stack established on consolidated canonical repo | — | C. Warrens | n/a (initial) |
| 2026-07-06 → 2026-07-06 | Requirements, design | Added 7 REQs (SIM-003, DATA-003, RISK-004, EXEC-002/003, GOV-002); de-mechanized DATA-002; fixed SIM-001 mapping | INVARIANT (additions + one clarification) | C. Warrens | additions/clarification — no cool-down required |
