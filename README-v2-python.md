# BLAQUE BAUX
### Phase 1 — Signal Validation Backtest
*SmallClaw Consultancy*

---

> *"A black box — collects information, inner workings unknown/complex,  
> focuses only on its inputs and outputs. More signal, less noise."*

---

## What this is

Phase 1 of a market-neutral global systematic trading system.
The sole objective: **measure realized factor accuracy** of the circular
futures cascade signal across the US equity universe on 2 years of
15-minute OHLCV data.

The output of Phase 1 is a single number that determines whether the
strategy proceeds to live paper trading. Everything else is secondary.

```
Realized factor accuracy >= 63% → Strong signal. Proceed immediately.
Realized factor accuracy >= 58% → Signal validated. Proceed to Phase 2.
Realized factor accuracy <  58% → Investigate before Phase 2.
```

---

## Quick start

```bash
# 1. Clone / copy this directory to your machine
cd blaque_baux

# 2. Install dependencies
pip install -r requirements.txt

# 3. Set your Polygon.io API key
cp .env.example .env
# Edit .env and add your POLYGON_API_KEY

# 4. Run a quick 60-day test first (validates setup, ~5 min)
python run_phase1.py --quick

# 5. Run the full 2-year backtest
python run_phase1.py

# 6. Optional: include efficient frontier analysis
python run_phase1.py --frontier
```

---

## Output files

| File | Description |
|------|-------------|
| `results/phase1_results.json` | Key numbers — feeds back into Monte Carlo simulator |
| `results/factor_accuracy.png` | **THE chart** — rolling accuracy vs 58% gate |
| `results/equity_curve.png`    | Portfolio performance, drawdown, return distribution |
| `results/signal_analysis.png` | Accuracy breakdown by cascade signal strength |
| `results/window_log.parquet`  | Per-window detail for deep analysis |
| `results/efficient_frontier.csv` | Multi-confidence level portfolio weights (--frontier) |

---

## Architecture

```
Signal layer (circular cascade):
  US close → APAC signal → APAC close → EMEA signal
                                       → EMEA close → US signal (2 hops)

Factor model (per 15-min window):
  w1 × futures_momentum + w2 × relative_strength + w3 × inter_market
  → composite score per stock → top N = longs, bottom N = shorts

Optimizer (CVXPY QP):
  minimize  w'Σw  (portfolio variance)
  subject to:
    Σ(long weights)  = 0.50
    Σ(short weights) = -0.50
    per-position limits [1%, 8%]
    target return constraint
    turnover penalty

Backtest (walk-forward):
  train_window = 480 bars (5 trading days)
  step = 1 bar (every 15 minutes)
  measure: did top quartile outperform bottom quartile?
```

---

## Key parameters (config.py)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BAR_MINUTES` | 15 | Window size in minutes |
| `N_LONGS` | 25 | Long book size |
| `N_SHORTS` | 25 | Short book size |
| `signal_cfg.momentum_lookback` | 4 bars | Futures momentum look-back |
| `signal_cfg.w_futures_momentum` | 0.45 | Factor weight: futures |
| `signal_cfg.w_rel_strength` | 0.30 | Factor weight: relative strength |
| `signal_cfg.w_inter_market` | 0.25 | Factor weight: cross-asset |
| `optimizer_cfg.ewma_lambda` | 0.94 | Covariance decay (RiskMetrics) |
| `optimizer_cfg.execution_drag` | 0.08% | Per-leg execution cost |

---

## Signal tuning

If Phase 1 accuracy is below 58%, try these adjustments in `config.py`:

1. **Increase `momentum_lookback`** — try 6 or 8 bars (90–120 min)
2. **Increase `w_futures_momentum`** to 0.55–0.65
3. **Check the signal_analysis.png** — the "Strong bull" cascade
   quartile should show materially higher accuracy than "Weak bear"
4. **Verify data quality** — run `--quick` to check Polygon.io
   is returning clean OHLCV without gaps

---

## Phase 2 transition

When Phase 1 passes:
1. Update the Monte Carlo simulator with `realized_factor_accuracy`
   from `results/phase1_results.json`
2. Deploy US pool to IBKR paper trading account
3. Validate realized vs modeled accuracy over 4–6 weeks live
4. Measure slippage at target position sizes
5. Add EMEA pool once US is stable

---

## Build roadmap

| Phase | Name | Status |
|-------|------|--------|
| **1** | Signal validation backtest | ← **you are here** |
| 2 | US paper trading | pending Phase 1 |
| 3 | US live ($10k) | pending Phase 2 |
| 4 | Global scale (EMEA + APAC + crypto) | pending Phase 3 |
| 5 | Full overlay (0DTE + branching) | pending Phase 4 |

---

*SmallClaw Consultancy — Blaque Baux v0.1.0*
