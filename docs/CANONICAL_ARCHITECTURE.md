# Blaque Baux — Canonical Architecture (draft)

**Status:** draft for decision · **Date:** 2026-07-26 · **Owner:** C. Warrens

## Decisions locked (2026-07-26)
- **Language path: A now** (Python fleet + Julia governed execution via a bridge), drift
  toward **B/C as a "day-3" item**.
- **Market data: IBKR** (historical + live bars over the Gateway) — not Massive, not Polygon.
  The recovered `data/fetcher.py` is repurposed to source from IBKR instead of Polygon.
- **Scope: equity-first.** Multi-asset (crypto + other pools) is a **"day-2" item**.

## Decisions locked (2026-07-27) — edge validation + strategy fork

**Edge validation result: NO EDGE.** The recovered alpha was tested out-of-sample on
60d × 15-min yfinance data (1,547 bars × 60 S&P equities):
- `factors.py` 3-factor model: **50.94%** accuracy (p=0.48), IC **−0.004**.
- Bayesian `signal_engine.py`: **50.74%** accuracy (p=0.59), IC **+0.001**.
Both indistinguishable from a coin flip. The machinery is sound; it does not *predict*
returns at this sample/horizon.

**Construction can't rescue it.** OOS test of portfolio construction *without* predictive
alpha (same panel): a market-neutral (net-zero) book returns **~0** regardless of construction
(equal-weight / min-variance / Six-Sigma Oracle) — no alpha to deploy, no premium to harvest.
The only positive return observed — long equal-weight, **+15.9%** — is **beta (equity risk
premium)**, not alpha and not clever construction.

**Corrected role of the Monte Carlo / Six-Sigma engines** — risk *tools*, not edge tools:
- `monte_carlo_engine.py` (crypto-quant) = forward risk simulator (VaR/CVaR/ES from assumed
  drift/vol). Right tool to **size a premium by its tail**, wrong tool to find return.
- `SixSigmaOracle` = weight optimizer on historical *means* (noise) → Markowitz overfitting
  trap if used for return. Correct use = **survival-sizing**: "at exposure X, what's the
  six-sigma loss?" → cap gross so it stays under the loss budget (`six_sigma_halt → halt!`).

**FORK DECISION: Path B is the spine; Path A is funded research on top.**
- **Path A (alpha)** — hunt a *predictive* signal. Uncertain existence (low-base-rate search
  with real unknown-unknowns), high ceiling, fast decay, capacity-limited. Kept as ongoing R&D;
  any alpha found plugs into the *same* risk engine for sizing. The market-neutral L/S "Path-A
  sequence" below is now the **research track**, not the spine.
- **Path B (premia) = SPINE** — harvest documented *risk premia* (equity; factor tilts
  value/quality/low-vol/momentum; later carry + vol-risk-premium; diversification). Return
  source is known and persistent; the **risk stack is the differentiator** (4-lane VaR/CVaR
  sizing, Six-Sigma survival-sizing, regime risk-timing, governed halt/flatten). Modest ceiling,
  slow decay, large capacity — you win on **risk management**, not prediction.
- Path B delivers a live, honest, positive-expected-return platform now; Path A is upside that
  plugs in if/when it hits. Neither bets the platform on finding alpha.

**Path-B equity-first build (the spine):**
1. Long-biased US equity book; `factors.py` repurposed as cross-sectional *exposures* (not forecasts).
2. Risk-budget sizing via `risk_engine` VaR/CVaR → `position_scalar`.
3. Regime overlay (`risk_intelligence` AdaptiveVol / Gamma-ARMA) → cut gross in high-vol regimes (risk-timing).
4. Governed Julia `ExecutionController` (built, 346/346) → drawdown halt/flatten = survival layer.
5. **Validate over a FULL CYCLE** (multi-year, incl. real drawdowns): does the risk-timed book
   beat buy-and-hold on Sharpe + max-drawdown net of costs? Well-posed and answerable.
   **No capital before this passes.**
6. Day-2: carry + vol premia (multi-asset via v1 fleet), risk-parity combine.

**Honest downsides of Path B:** lower Sharpe than a real alpha (~0.3–0.6 single premium, ~1
diversified); it *eats the tail* (vol/carry left tails — the risk engine mitigates, not
eliminates); increasingly commoditized (factor ETFs exist) so the edge is the risk overlay +
combination + execution; correlations converge in crises.

**Path-B validation: PASSED (2026-07-27).** Full-cycle test — 9 SPDR sector ETFs, 27.3y
(1999–2026, incl. dot-com / GFC / 2011 / 2018-Q4 / COVID / 2022), **net of 2 bps/side**:
- buy&hold EW: CAGR **+9.2%**, Sharpe 0.58, **maxDD −53%** (GFC −53%, COVID −37%).
- vol-targeted EW (12% target, 60d realized vol, causal/lagged, cap 1.0, de-risk only):
  CAGR **+7.2%**, Sharpe **0.67**, Sortino **0.91**, **maxDD −28%** (GFC −25%, COVID −18%),
  Calmar 0.26.
Risk-timing **halved max drawdown and every crisis drawdown** and lifted Sharpe +15% /
Sortino +25% / Calmar +44%, for ~2% CAGR given up sitting in cash (understated — cash earned
0%; a real T-bill rate closes much of the gap). **BUILD DECISION: keep the vol-target overlay;
DROP the risk-parity *sector* tilt** — it added nothing (0.67 vs 0.67, −27% vs −28% maxDD) at
~2× the turnover (339% vs 184%/yr). **Known limit:** vol-targeting is a lagged *crash-cutter*,
weaker on slow bleeds (2022 −17%→−11%) — pair it with the `risk_intelligence` Gamma-ARMA regime
signal, not vol alone. The path from single-premium Sharpe ~0.67 toward ~1 is **adding
uncorrelated premia** (bonds/carry/vol) + risk-parity *across asset classes* (day-2).

**Path-B SYNTHESIS validated (2026-07-27) — THE SPINE.** Diversified inverse-vol base +
**TREND (12m TSMOM) sleeve** + vol-target overlay, 5 assets (SPY/IEF/TLT/GLD/DBC), 19.4y
(2007–2026, incl. GFC/COVID/2022), net of costs+financing:
- **SPINE (base+trend 50/50): Sharpe 0.86, Sortino 1.17, Calmar 0.48, maxDD −11%** — no crisis
  worse than −7.2% (GFC −7.2%, COVID −5.7%, 2022 −6.3%). vs SPY: Sharpe 0.62, maxDD −55%.
- **2022 patch confirmed:** the trend sleeve made **+4.4%** (short bonds / long energy) while
  SPY −18% / 60-40 −16%, cutting the spine's 2022 loss to **−2.8%**. Bonds alone can't do this;
  trend is the sleeve that survives the positive-stock/bond-correlation regime.
Honest: Sharpe **0.86 (not 1.0)**; CAGR **+5.4%** (a 6.3%-vol book — lever *modestly* to ~11% vol
for ~9% CAGR at similar Sharpe; safe here *because* trend caps the tail, unlike the naive
bond-leverage that failed the (b) test); trend is a hedge/diversifier, not a return engine (long
flat stretches 2011–2019). **BUILD TARGET (the spine): diversified inverse-vol RP base + TSMOM
trend sleeve + vol-target overlay + regime cut → governed execution.**

## Implementation status — Path-B spine BUILT (2026-07-27)
The spine above is now **implemented, tested, and running end-to-end on cached data through the
governed execution path.** Only the live IBKR data/venue swap remains (blocked on account approval).

| Step | Deliverable | Status |
|---|---|---|
| strategy (d-1/d-3) | `src/module_13_portfolio/spine.jl` — `tsmom_signal`/`tsmom_weights`, `voltarget_exposure`, stateful `SpineState`/`spine_step!`/`spine_targets`, `regime_multiplier`; composes existing `ewma_cov`/`risk_parity`/`inverse_variance` | ✅ `test/test_spine.jl` **40/40** |
| parity (d-2) | stateful port reproduces the study: Sharpe ~0.94–0.99, maxDD −9.9…−10.8%, 2022 −2.8…−3.2%, trend +4.2% in 2022 | ✅ verified |
| regime (d-5) | `regime_multiplier` (:none/:dd/:vol/:trend/:both); `:dd` default in production (Sharpe 0.94→0.97, cuts crises at ~0 cost) | ✅ |
| data (d-4) | `src/module_1_data/equity_panel.jl` (`EquityPanel`: swappable `PanelProvider`, `CSVPanelProvider`, `panel_at`) + fixture `scripts/data/sector_panel.csv` | ✅ `test/test_equity_panel.jl` **12/12** |
| wiring | `scripts/run_daily_recursive.jl` `compute_targets` → spine → governed `execute_rebalance!`; Serialization state persistence; `spine_regime=:dd` | ✅ loads clean |
| end-to-end | `scripts/spine_end_to_end.jl`: CSV → spine → governed orders → SimVenue fills → SQLite ledger w/ lineage → reconcile | ✅ 12 rebalances, **59 fills w/ AUDIT-001 lineage** |
| integration test | `test/test_spine_pipeline.jl` — the full pipeline as a registered test (asserts reconcile + lineage every run) | ✅ **11/11** |
| IBKR adapter (write-ahead) | `src/module_1_data/ibkr_panel.jl` — `IBKRPanelProvider` (Jib `reqHistoricalData`, verified offline) | ⏸ kept as a second venue (IBKR **rejected** the account) |
| **Plan-B data (Alpaca)** | `src/module_1_data/alpaca_panel.jl` — `AlpacaPanelProvider` (REST v2 daily bars, total-return, paginated) | ✅ compiles; **runnable with paper keys** |
| **Plan-B venue (Alpaca)** | `src/module_7_execution/venues/alpaca.jl` — `AlpacaVenue` (POST /v2/orders, positions, drain fills; client_order_id idempotency) | ✅ **12/12**; 346/346 controller regression green |
| **Alpaca paper runner** | `scripts/spine_alpaca_paper.jl` — export paper keys → spine on Alpaca paper end-to-end | ✅ compiles; awaits free paper keys |

**Design facts baked in (verified, not assumed):**
- Per-sleeve vol-target uses each sleeve's **realized P&L vol** (RiskMetrics span-60), *not* ex-ante
  asset-Σ vol — the latter throttles the trend hedge exactly when it works (the 2022 lesson). The
  **stateful two-sleeve** construction is load-bearing; the stateless `spine_weights` under-hedges
  and is annotated as an approximation.
- `SpineState` default `regime=:none` reproduces the validated baseline exactly; production defaults `:dd`.
- Every order-path invariant fired in the end-to-end run (REQ-RISK-003 daily budget → `reset_daily!`
  per day; AUDIT-001 lineage on every fill; reconciliation clean).
- Fixed a pre-existing parse bug in `run_daily_recursive.jl` (malformed multi-line `@info`) — the
  draft runner had never parsed/loaded before.

**Broker pivot — IBKR REJECTED → Alpaca primary (2026-07-27).** IBKR rejected the account
(funded; no explanation). Pivoted to **Alpaca** (US resident) — the venue-abstraction's payoff:
`PanelProvider` + `ExecutionVenue` made it a swap, not a rewrite. Alpaca **paper needs no
account approval**, so this is *runnable now*, further than IBKR ever allowed. The IBKR adapters
are kept as a ready second venue if the account is ever re-applied.

**To run on Alpaca paper (the only remaining step is free paper keys, no approval):**
`export ALPACA_KEY_ID=… ALPACA_SECRET_KEY=…` then `julia --project=. scripts/spine_alpaca_paper.jl`.
That drives the full path — Alpaca data → spine (regime :dd) → governed orders → Alpaca paper
fills → ledger w/ lineage → reconcile. Everything between data and venue is proven by
`test/test_spine_pipeline.jl`. **Live money** later = `AlpacaConfig(paper=false)` after standard
US-KYC approval (lighter than IBKR; Tradier is the US backup) AND governed invariants green.
The market-neutral L/S "Path-A sequence" below is the **research track**, not the spine.

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
