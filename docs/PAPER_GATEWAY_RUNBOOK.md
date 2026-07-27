# Paper Gateway Runbook

How to verify the IBKR execution adapter against a **paper** account. This is the runtime
half of gap #4 — the part that can't be checked offline. The adapter's API is already
verified against real Jib (see `design.md` → Execution venues); this confirms it actually
connects, places, and fills.

> **Paper only.** Every step below uses a paper account and a paper port. The smoke test
> refuses to run against a non-paper port. Do not point any of this at a live account.

## 1. Prerequisites
- An Interactive Brokers **paper** account (id looks like `DU1234567`).
- **IB Gateway** (headless, recommended) or **TWS**, installed and logged into the *paper* login.
- Julia 1.9+ (repo tested on 1.12).

## 2. Enable the API in Gateway/TWS
In IB Gateway: **Configure → Settings → API → Settings**:
- ☑ Enable ActiveX and Socket Clients
- **Socket port:** `4002` (IB Gateway paper) — or `7497` if you use TWS paper
- ☑ Allow connections from localhost only (Trusted IPs: `127.0.0.1`)
- ☐ Read-Only API must be **unchecked** (the smoke test places a paper order)
- Apply, and leave Gateway running & logged in.

## 3. Instantiate the Julia environment
**Jib is an unregistered GitHub package** — if `instantiate` doesn't resolve it from the
Manifest, add it by URL first:
```bash
cd "…/blaque_baux_canonical"
julia --project=. -e 'using Pkg; Pkg.instantiate()'
# if Jib is missing:
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/lbilli/Jib.jl")'
```

## 4. Set environment + run the smoke test
```bash
export BB_PAPER_SMOKE_CONFIRM=yes
export IBKR_HOST=127.0.0.1
export IBKR_PORT=4002            # 7497 if TWS paper
export IBKR_ACCOUNT=DU1234567    # your paper account id
julia --project=. scripts/ibkr_paper_smoke.jl SPY 1
```
Run it during **regular US market hours** so the market order fills promptly.

## 5. What success looks like
The log should show, in order:
1. `✓ connected`
2. `✓ positions snapshot` (n may be 0 on a fresh paper account)
3. `submit_governed! returned … status=accepted` with a non-empty `venue_order_id`
4. `✓ fills drained` with one fill for `SPY` (`signal_id=smoke`, etc. — lineage tagged)
5. `✓ reconciliation OK` (or a benign halt if the broker snapshot lags the fill by a moment)
6. `✓ disconnected`

If you see all six, the adapter works end-to-end and #4 is closed.

## 6. Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| `connect! failed` / connection refused | Gateway not running, API not enabled, or wrong port. Re-check step 2. |
| Hangs on connect | Trusted IP not set to `127.0.0.1`, or a stale client id — restart Gateway. |
| Order `status=accepted` but no fill | Market closed — run during RTH, or the symbol wasn't marketable. |
| `Refusing to run … not a known paper port` | `IBKR_PORT` must be `4002` or `7497`. (This is the safety guard.) |
| Reconciliation halts | Expected if the position snapshot lags the just-placed fill; re-run `process_fills!`+`reconcile!` a moment later. |

## 7. After the smoke test passes
The next step is the **runner integration**: wiring `scripts/run_daily_recursive.jl`'s
execution step through `submit_governed!` (via `IBKRVenue`), feeding staleness
(`mark_data_fresh!`) and PnL (`update_pnl!`), and connecting `process_fills!` → the
execution ledger (`record_fill`) and the `audit` sink → `module_8` governance. That work is
gated on this smoke test passing — no point wiring the full runner onto an unverified adapter.
