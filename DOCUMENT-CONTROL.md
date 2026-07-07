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

## Versioning

- Each controlled doc carries a version and last-updated date in its header.
- Changes are recorded append-only in that doc's change log (or here for cross-cutting changes).
- REQ-IDs are permanent. A retired requirement is marked `SUPERSEDED by REQ-XXX`, never deleted.

## Change log

| Date | Doc(s) | Change | Class | Approver |
|---|---|---|---|---|
| 2026-07-06 | all | Initial spec stack established on consolidated canonical repo | — | (pending) |
