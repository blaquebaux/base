# Blaque Baux — Canonical Architecture (draft)

**Status:** draft for decision · **Date:** 2026-07-26 · **Owner:** C. Warrens

## Decisions locked (2026-07-26)
- **Language path: A now** (Python fleet + Julia governed execution via a bridge), drift
  toward **B/C as a "day-3" item**.
- **Market data: IBKR** (historical + live bars over the Gateway) — not Massive, not Polygon.
  The recovered `data/fetcher.py` is repurposed to source from IBKR instead of Polygon.
- **Scope: equity-first.** Multi-asset (crypto + other pools) is a **"day-2" item**.

## Verification (deep-read, 2026-07-26)
`risk_engine.py`, `pool_manager.py`, `signal_engine.py`, and `risk_intelligence.py` were read
**in full**; the rest structure-scanned. Verdict: the Bayesian alpha engine and the risk stack
are **real, mathematically sound, well-engineered** (correct Kalman/NIG/James-Stein/ADVI/
Cornish-Fisher/GEV/Welford; latency-aware; fallbacks) — the best-of-breed calls hold. Caveats:
- **LLM-synthesized** (source tags like `deepseek_*`) — coherent but not battle-tested; each
  file needs a review pass before porting/trusting.
- **Concrete bug to fix on recovery:** in `HybridSignalEngine.update_bar`, the inverse-variance
  combine uses `alpha_shrunk` for *both* the Kalman and shrinkage precision terms — the raw
  Kalman alpha never enters the blend. Likely a copy-paste artifact; confirm intent.
- **Risk-layer overlap:** `risk_engine.py` (L1–L4 lanes) and `risk_intelligence.py`
  (Cornish-Fisher VaR + adaptive-vol cadence + GEV fitting) both compute VaR/sVaR/RNIV.
  Consolidate into one risk stack (C-F VaR + the L1–L4 lanes + the regime cadence).
- **Edge still unvalidated** — the machinery is sound; whether the composite alpha *predicts*
  returns is unproven (Phase 1 was that step).

## What this is
A cross-branch review of every Blaque Baux / Crypto Quant iteration in
`Downloads/Blaque Baux and Crypto Quant/`, to define **one canonical platform** as the
best-of-breed composition — rather than treating any single tree (including the Julia
CherryPick build we've been extending) as canonical by default.

## The central finding
The trees are **not competing versions of one system.** They are **snapshots of building
one coherent multi-pool platform**, and each tree holds the *best implementation of a
different layer*. The blueprint is explicit in `blaque_baux-v1/orchestration/pool_manager.py`
— its per-window loop names every layer and how they connect. There are also **two
products** sharing this infrastructure: **Blaque Baux** (equity long/short) and **Crypto
Quant** (crypto), plus shared files at the folder root (`risk_intelligence.py`).

## The designed per-window pipeline (from pool_manager.py)
```
 coordinator → N× pool_manager (asyncio, one per pool) ── event_bus (SmallClaw WAL, fleet)
                    │  per pool, per bar:
                    ├─ data (fetcher/Polygon)                → returns + signal panel
                    ├─ cascade signal (cascade.py)           → cascade_strength ∈ [-1,+1]
                    ├─ adaptive vol regime (risk_intelligence)→ bar cadence + signal params
                    ├─ HybridSignalEngine (signal_engine.py) → per-ticker alpha + active_mask
                    │     (Kalman → NIG Bayes → James-Stein → ADVI; Rust hot path)
                    ├─ risk_engine (risk_engine.py)          → RiskParams (VaR/sVaR/RNIV/6σ,
                    │     dynamic L/S ratio, position_scalar, six_sigma_halt)
                    ├─ circuit_breaker (circuit_breaker.py)  → gate + position scalar + 0DTE
                    ├─ qp_solver (qp_solver.py)              → long/short book weights
                    │     (turnover penalty, borrow-cost-adjusted shorts, EWMA cov)
                    ├─ borrow_feed (borrow_feed.py)          → live HTB rates
                    └─ execution                             → orders
 background: Six Sigma Oracle (run_overnight_oracle → 1M Monte Carlo → weight prior)
```

## Best-of-breed by layer

| Layer | Best implementation | Source | Language | Notes |
|---|---|---|---|---|
| Multi-pool runtime | `coordinator` + `pool_manager` | **v1** | Python (asyncio) | Only fleet runtime; CherryPick has a single daily runner |
| Fleet coordination | `event_bus` (SmallClaw WAL) | **v1** | Python + TS | Cross-machine (m4mini/m2studio/m3studio) |
| Adaptive regime cadence | `risk_intelligence.AdaptiveVolatilityDetector` | **root** | Python | Drives bar cadence + signal params |
| **Statistical regime** | Gamma-ARMA + DPM (modules 4/5/6) | **CherryPick** | Julia | More rigorous than the vol-regime detector |
| **Alpha (per-ticker)** | `HybridSignalEngine` (Kalman/NIG/JS/ADVI) | **base + Rust** | Python/Rust | Supersedes `factors.py`; the core IP |
| Cascade signal | `cascade.py` | **v2** | Python | Feeds alpha + risk L/S ratio |
| **Risk engine** | `risk_engine.py` (4-lane VaR/sVaR/RNIV/6σ oracle) | **base** | Python | Institutional; **maps onto our governed gates** |
| Book optimizer | `qp_solver.py` (L/S, turnover, borrow) | **v2/base** | Python (CVXPY) | Specific book constraints module_13 lacks |
| Generic optimizers | `PortfolioOpt` (mean-var, BL, HRP, CVaR) | **CherryPick** | Julia | For non-L/S constructions |
| **Governed execution** | `ExecutionController` (venue adapter) | **CherryPick + our work** | Julia | Tested (346/346); supersedes `order_manager.py` |
| Borrow/HTB feed | `borrow_feed.py` | **v1** | Python (IBKR) | Required for a short book |
| Validation | purged K-Fold / CPCV (module_11) | **CherryPick** | Julia | López de Prado; supersedes v2 backtest |
| Data panel | `fetcher.py` (Polygon) | **v2** | Python | Or IBKR bars over the Gateway |
| Performance hot path | Rust signal engine, Julia optimizer/oracle | **polyglot** | Rust/Julia | Later performance pass |

## The two big implementations, honestly
1. **The Python/polyglot fleet platform** (v1 runtime + base signal/risk + v2 alpha/data +
   polyglot perf) — a *complete, integrated multi-pool trading platform*: Bayesian signals,
   institutional risk, fleet coordination, 0DTE. But: Python (research-grade), its execution
   layer is the simpler `order_manager`, and **its edge was never validated** (Phase 1 was
   that step).
2. **CherryPick (Julia)** — the *rigorous engine* for the layers it covers (Gamma-ARMA
   regime, three-strata stats, `PortfolioOpt`, purged CV) **plus the best execution layer**
   (the governed, tested, venue-abstracted `ExecutionController` we built). But: single daily
   runner (no fleet), no Bayesian alpha, no risk engine, no borrow feed, no equity data panel.

They are complementary at the layer level. Neither is "the canonical" alone.

## The one hard decision: language & integration architecture
The platform's runtime/signal/risk/optimizer are **Python**; the best regime/validation and
the best execution are **Julia**; the hot-path ports are **Rust/Julia/Hy**. Three ways to
form the canonical:

- **A. Python-orchestrated, Julia-execution (bridge).** Keep the v1 asyncio fleet as the
  spine; keep our governed Julia `ExecutionController` as the execution layer; bridge them
  (the same seam pattern as `cuopt_bridge.py`). CherryPick's Julia rigor (regime, CV) is
  called as libraries. **Fastest to a running canonical; polyglot but with clean seams.**
- **B. Consolidate to Julia.** Port the fleet runtime, signal engine, and risk engine to
  Julia so it's one language end-to-end. **Cleanest long-term; large effort** (the signal
  engine + risk engine are ~2,000 lines of numerically dense Python).
- **C. Deliberate polyglot** (what the polyglot tree reached for): Python orchestration,
  Rust hot-path signal, Julia optimization + execution, coordinated via the event bus.
  **Best performance ceiling; most operationally complex.**

**Recommendation: A now, drift toward B.** Recover the fleet + signal + risk layers as they
are (Python), bridge them to the governed Julia execution we already trust, get the whole
platform *running and validated end-to-end on paper*, then port hot layers to Julia over time
where it pays. This front-loads a working canonical and defers the big rewrite until the edge
is proven.

## What must be recovered vs. what's superseded
**Recover (unique, not in CherryPick):** the fleet runtime (v1), the Bayesian signal engine
(base+Rust), the risk engine (base), the cascade + qp_solver + data panel (v2), the borrow
feed (v1), the SmallClaw coordination bus (v1), `risk_intelligence` (root).
**Superseded (CherryPick/our work is better):** `order_manager.py` → our governed
`ExecutionController`; v2 `backtest` → module_11 purged CV; `factors.py` → `HybridSignalEngine`
(keep `factors.py` as a fallback/baseline); v2/base `qp_solver` overlaps but has unique L/S
constraints worth keeping.

## Honest caveats
- **Read depth:** `risk_engine.py` and `pool_manager.py` read in full; `signal_engine.py`,
  `circuit_breaker.py`, `event_bus.py`, `optimizer_service.py`, `risk_intelligence.py`, and
  the Rust engine were **structure-scanned, not line-by-line**. The best-of-breed calls are
  high-confidence at the interface level; implementation quality of the Bayesian engine and
  the coordination bus needs a deep-read before porting.
- **Unvalidated edge:** the strategy's alpha was never validated (Phase 1 = `measure_window_accuracy`).
  A running canonical is not a *profitable* one until that validation runs on real data.
- **Two products:** decide whether the canonical is Blaque-Baux-equity-first (crypto as a
  later pool) or unified multi-asset from day one. The pool structure already anticipates both.
- **Risk-engine ↔ governed-controller mapping is the key integration win:** `risk_engine`'s
  `six_sigma_halt` → `halt!`, `position_scalar` → order sizing, VaR/sVaR loss constraints →
  per-pool budget/loss limits (REQ-RISK-003/004), loss budget → `update_pnl!`. This is exactly
  the PnL/risk feed the governed controller was built to receive but isn't yet wired.

## Path-A sequence (equity-first, IBKR data, Python↔Julia bridge)
Target: one US-equity pool, end-to-end, paper — Python fleet+alpha+risk → bridge → the
governed Julia `ExecutionController`. Each step is dry-run/paper until step 6.

1. **IBKR data adapter.** Repurpose `data/fetcher.py` to pull 15-min bars from IBKR
   (`reqHistoricalData`/`reqMktData`) instead of Polygon → `close_prices/returns/signal_returns`.
   Reuses the Gateway you're already standing up.
2. **Bridge the governed execution.** Expose the Julia `ExecutionController` to Python (a thin
   RPC/subprocess seam, like `cuopt_bridge.py`) so the Python fleet submits governed orders.
3. **Risk-engine → controller gates.** Wire `risk_engine`/`risk_intelligence` outputs onto the
   governed gates: `six_sigma_halt`→`halt!`, `position_scalar`→sizing, VaR/sVaR loss→
   `set_pool_budget!`/`set_pool_loss_limit!`, loss/PnL→`update_pnl!`. This closes `compute_targets`'
   risk half *and* the PnL feed at once.
4. **Alpha→weights path.** Recover `HybridSignalEngine` (fix the combine bug) + `cascade` +
   `qp_solver` (+ `borrow_feed` for shorts) → per-symbol targets → `compute_targets`.
5. **Validate the edge** on IBKR history via CherryPick's purged CV (module_11) — the Phase-1
   accuracy test that was never run. **No live capital before this passes.**
6. **Paper-live the US pool** (`BB_LIVE_EXEC=yes`) through the full stack; confirm a governed
   daily cycle.
7. **Consolidate the risk stack** (merge `risk_engine` + `risk_intelligence`); layer in CherryPick
   Gamma-ARMA regime to upgrade the vol-regime inputs.

**Day-2:** add pools (EMEA/APAC/commodities) via the v1 fleet runtime; add crypto (the Crypto
Quant signal/risk lineage). **Day-3:** port hot layers to Julia (path B) / Rust (path C).
