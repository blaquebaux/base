"""
blaque_baux/run_phase1.py
──────────────────────────
Phase 1 entry point: signal validation backtest.

Usage:
    python run_phase1.py                    # full backtest (2 years)
    python run_phase1.py --quick            # 60-day sample (fast validation)
    python run_phase1.py --refresh          # force re-fetch data from Polygon
    python run_phase1.py --frontier         # include efficient frontier analysis
    python run_phase1.py --ticker AAPL      # single-ticker signal analysis

Output:
    results/phase1_results.json     ← feeds back into Monte Carlo simulator
    results/factor_accuracy.png     ← THE chart (is accuracy > 58%?)
    results/equity_curve.png        ← portfolio performance
    results/signal_analysis.png     ← cascade signal vs accuracy breakdown
    results/window_log.parquet      ← per-window detail for deep analysis

The single output that matters most:
    "realized_factor_accuracy" in phase1_results.json

If that number is >= 0.58: proceed to Phase 2 (paper trading).
If that number is >= 0.63: strong signal, accelerate to Phase 2.
If that number is <  0.58: investigate signal weights before Phase 2.
"""

import argparse
import logging
import os
import sys
from datetime import datetime, timedelta

import pandas as pd

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


def parse_args():
    p = argparse.ArgumentParser(description="Blaque Baux — Phase 1 Signal Validation")
    p.add_argument("--quick",    action="store_true",
                   help="Run on 60-day sample instead of full 2-year backtest")
    p.add_argument("--refresh",  action="store_true",
                   help="Force re-fetch data from Polygon.io (ignore cache)")
    p.add_argument("--frontier", action="store_true",
                   help="Run efficient frontier analysis on a sample window")
    p.add_argument("--universe", type=str, default=None,
                   help="Comma-separated list of tickers to override default universe")
    p.add_argument("--start",    type=str, default=None,
                   help="Override backtest start date (YYYY-MM-DD)")
    p.add_argument("--end",      type=str, default=None,
                   help="Override backtest end date (YYYY-MM-DD)")
    return p.parse_args()


def main():
    args = parse_args()

    # ── Override dates if specified ───────────────────────────────────────────
    if args.start or args.end or args.quick:
        import config
        if args.quick:
            config.BACKTEST_START = (
                datetime.now() - timedelta(days=60)
            ).strftime("%Y-%m-%d")
            config.BACKTEST_END = datetime.now().strftime("%Y-%m-%d")
            logger.info("Quick mode: 60-day backtest")
        if args.start: config.BACKTEST_START = args.start
        if args.end:   config.BACKTEST_END   = args.end

    if args.universe:
        import config
        config.EQUITY_UNIVERSE = [t.strip().upper() for t in args.universe.split(",")]
        logger.info(f"Custom universe: {config.EQUITY_UNIVERSE}")

    # ── Validate API key ──────────────────────────────────────────────────────
    from config import POLYGON_API_KEY
    if not POLYGON_API_KEY:
        print("\n" + "="*60)
        print("  POLYGON_API_KEY not set.")
        print("  1. Create a .env file in the blaque_baux/ directory")
        print("  2. Add: POLYGON_API_KEY=your_key_here")
        print("  3. Get a key at https://polygon.io")
        print("  Free tier works for testing; paid ($29/mo) for full 2yr backtest")
        print("="*60 + "\n")
        sys.exit(1)

    # ── Data load ─────────────────────────────────────────────────────────────
    logger.info("Step 1/4: Loading data")
    from data.fetcher import load_all
    close_prices, equity_returns, signal_returns = load_all(
        force_refresh=args.refresh
    )

    if close_prices.empty:
        logger.error("No data loaded — check API key and network connection")
        sys.exit(1)

    logger.info(
        f"Data loaded: {len(close_prices)} bars × "
        f"{len(close_prices.columns)} tickers"
    )

    # ── Efficient frontier sample (optional) ─────────────────────────────────
    if args.frontier:
        logger.info("Running efficient frontier analysis on latest window...")
        _run_frontier_sample(close_prices, equity_returns, signal_returns)

    # ── Backtest ──────────────────────────────────────────────────────────────
    logger.info("Step 2/4: Initializing backtest engine")
    from backtest.engine import BacktestEngine
    engine = BacktestEngine(close_prices, equity_returns, signal_returns)

    logger.info("Step 3/4: Running walk-forward backtest")
    results, window_log = engine.run(verbose=True)

    # ── Save window log ───────────────────────────────────────────────────────
    engine.save_window_log(window_log)

    # ── Output ────────────────────────────────────────────────────────────────
    logger.info("Step 4/4: Generating output")
    from backtest.metrics import produce_phase1_output
    produce_phase1_output(results, window_log)

    # ── Phase 2 gate ──────────────────────────────────────────────────────────
    from config import ACCURACY_TARGET, ACCURACY_STRONG
    acc = results.realized_factor_accuracy

    print("\n" + "─"*60)
    if acc >= ACCURACY_STRONG:
        print(f"  ✓ STRONG SIGNAL ({acc:.1%}) — "
              f"Proceed to Phase 2 (paper trading) immediately")
        print(f"  Update simulator with: factor_accuracy = {acc:.2f}")
    elif acc >= ACCURACY_TARGET:
        print(f"  ✓ SIGNAL VALIDATED ({acc:.1%}) — "
              f"Proceed to Phase 2 (paper trading)")
        print(f"  Update simulator with: factor_accuracy = {acc:.2f}")
    else:
        print(f"  ✗ SIGNAL NEEDS WORK ({acc:.1%} < {ACCURACY_TARGET:.0%} target)")
        print(f"  Review signal weights in config.py before Phase 2")
        _print_signal_tuning_suggestions(results)
    print("─"*60 + "\n")

    return results


def _run_frontier_sample(close_prices, equity_returns, signal_returns):
    """Run efficient frontier on the most recent 5-day window."""
    from config import N_LONGS, N_SHORTS, signal_cfg
    from signal.cascade import compute_cascade_signal
    from signal.factors import compute_factor_scores, select_long_short
    from optimizer.qp_solver import compute_efficient_frontier

    logger.info("Computing efficient frontier...")

    cascade = compute_cascade_signal(signal_returns)
    scores  = compute_factor_scores(equity_returns, signal_returns, cascade)

    # Use most recent window
    t = len(equity_returns) - 2
    scores_t = scores.iloc[t]
    history  = equity_returns.iloc[max(0, t-480):t]

    longs, shorts = select_long_short(scores_t, N_LONGS, N_SHORTS)

    frontier = compute_efficient_frontier(
        factor_scores    = scores_t,
        returns_history  = history,
        long_tickers     = longs,
        short_tickers    = shorts,
    )

    print("\nEfficient Frontier (latest window):")
    print(frontier.to_string(index=False, float_format=lambda x: f"{x:.4f}"))
    print()

    # Save to results
    os.makedirs("./results", exist_ok=True)
    frontier.to_csv("./results/efficient_frontier.csv", index=False)
    logger.info("Efficient frontier saved: ./results/efficient_frontier.csv")


def _print_signal_tuning_suggestions(results):
    """Print actionable suggestions when accuracy is below target."""
    print("\n  Signal tuning suggestions:")
    print("  ─────────────────────────────────────────────────")
    print("  1. Increase momentum_lookback in config.py")
    print("     (try 6 or 8 bars instead of 4)")
    print("  2. Increase w_futures_momentum weight (currently "
          f"{results.signal_params.get('w_futures_momentum', '?')})")
    print("     (try 0.55–0.65, reduce w_rel_strength proportionally)")
    print("  3. Check that Polygon.io data is returning clean OHLCV")
    print("     (run: python run_phase1.py --quick to verify data quality)")
    print("  4. Review the signal_analysis.png chart:")
    print("     If 'Strong bull' cascade doesn't show higher accuracy,")
    print("     the futures signal needs investigation.")
    print()


if __name__ == "__main__":
    main()
