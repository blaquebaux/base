"""
blaque_baux/backtest/metrics.py
────────────────────────────────
Performance metrics, charts, and Phase 1 results output.

Produces:
  1. phase1_results.json    — the key numbers, machine-readable
  2. factor_accuracy.png    — rolling accuracy over time (THE chart)
  3. equity_curve.png       — portfolio equity curve vs benchmark
  4. accuracy_distribution.png — histogram of per-window accuracy
  5. terminal summary        — clean print to console

The factor_accuracy.png is the most important artifact of Phase 1.
If that line is consistently above 58%, Blaque Baux proceeds to Phase 2.
"""

import json
import logging
import os
from typing import List

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import seaborn as sns

from config import (
    OUTPUT_DIR,
    RESULTS_JSON,
    ACCURACY_PLOT,
    EQUITY_CURVE_PLOT,
    ACCURACY_TARGET,
    ACCURACY_STRONG,
)
from backtest.engine import BacktestResults, WindowResult

logger = logging.getLogger(__name__)

# Clean matplotlib style
plt.rcParams.update({
    "font.family":      "monospace",
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "axes.grid":        True,
    "grid.alpha":       0.3,
    "grid.linestyle":   "--",
    "figure.facecolor": "white",
    "axes.facecolor":   "white",
})

COLORS = {
    "primary":   "#185FA5",
    "success":   "#1D9E75",
    "warning":   "#BA7517",
    "danger":    "#A32D2D",
    "neutral":   "#888780",
    "purple":    "#534AB7",
}


# ── MAIN OUTPUT FUNCTION ──────────────────────────────────────────────────────

def produce_phase1_output(
    results: BacktestResults,
    window_log: List[WindowResult],
) -> str:
    """
    Produce all Phase 1 output artifacts.
    Returns path to the results JSON.
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 1. JSON results (machine-readable, feeds back into simulator)
    save_results_json(results)

    # 2. Charts
    plot_factor_accuracy(results, window_log)
    plot_equity_curve(results, window_log)
    plot_signal_analysis(window_log)

    # 3. Console summary
    print_summary(results)

    return RESULTS_JSON


def save_results_json(results: BacktestResults):
    """
    Save key results as JSON.
    This file feeds directly back into the Monte Carlo simulator:
        realized_factor_accuracy → replace the 60% assumption
        alpha_per_window         → replace the 1.0% assumption
    """
    from dataclasses import asdict

    # Core numbers for simulator calibration
    output = {
        "blaque_baux_phase1": {
            "verdict": results.phase1_verdict,
            "date_range": {
                "start": results.start_date,
                "end":   results.end_date,
            },
        },
        "simulator_inputs": {
            "realized_factor_accuracy": round(results.realized_factor_accuracy, 4),
            "win_rate":                 round(results.win_rate, 4),
            "avg_alpha_per_window":     round(results.avg_spread, 4),
            "avg_win":                  round(results.avg_win, 6),
            "avg_loss":                 round(abs(results.avg_loss), 6),
        },
        "performance": {
            "total_return":       round(results.total_return, 4),
            "annualized_return":  round(results.annualized_return, 4),
            "sharpe_ratio":       round(results.sharpe_ratio, 3),
            "max_drawdown":       round(results.max_drawdown, 4),
            "profit_factor":      round(results.profit_factor, 3),
        },
        "distribution": {
            "p10_return":         round(results.p10_return, 6),
            "p90_return":         round(results.p90_return, 6),
            "avg_factor_spread":  round(results.avg_spread, 6),
        },
        "reliability": {
            "n_windows":          results.n_windows,
            "n_valid_windows":    results.n_valid_windows,
            "qp_failure_rate":    round(results.qp_failure_rate, 4),
        },
        "signal_config": results.signal_params,
        "phase2_gate": {
            "accuracy_target":    ACCURACY_TARGET,
            "accuracy_strong":    ACCURACY_STRONG,
            "realized_accuracy":  round(results.realized_factor_accuracy, 4),
            "gate_passed":        results.realized_factor_accuracy >= ACCURACY_TARGET,
            "strong_signal":      results.realized_factor_accuracy >= ACCURACY_STRONG,
        },
    }

    with open(RESULTS_JSON, "w") as f:
        json.dump(output, f, indent=2)
    logger.info(f"Results saved: {RESULTS_JSON}")


def plot_factor_accuracy(
    results: BacktestResults,
    window_log: List[WindowResult],
):
    """
    THE Phase 1 chart: rolling factor accuracy over time.
    A line consistently above 58% = green light for Phase 2.
    """
    fig, axes = plt.subplots(2, 1, figsize=(14, 8))
    fig.suptitle(
        "BLAQUE BAUX — Phase 1: Realized Factor Accuracy",
        fontsize=14, fontweight="bold", y=0.98
    )

    # Raw data
    timestamps = [w.timestamp for w in window_log]
    hits = [1.0 if w.factor_accuracy_hit else 0.0 for w in window_log]
    spreads = [w.factor_spread for w in window_log]

    ts = pd.Series(hits, index=pd.DatetimeIndex(timestamps))
    sp = pd.Series(spreads, index=pd.DatetimeIndex(timestamps))

    # ── Top: Rolling accuracy ─────────────────────────────────────────────────
    ax1 = axes[0]
    roll_20  = ts.rolling(20).mean()
    roll_100 = ts.rolling(100).mean()

    ax1.axhline(ACCURACY_TARGET,  color=COLORS["warning"], lw=1.5, ls="--",
                label=f"Phase 2 gate ({ACCURACY_TARGET:.0%})", alpha=0.8)
    ax1.axhline(ACCURACY_STRONG,  color=COLORS["success"], lw=1.5, ls="--",
                label=f"Strong signal ({ACCURACY_STRONG:.0%})", alpha=0.8)
    ax1.axhline(0.5, color=COLORS["neutral"], lw=1, ls=":", alpha=0.5, label="Random (50%)")

    ax1.fill_between(roll_20.index, ACCURACY_TARGET, roll_20,
                     where=roll_20 >= ACCURACY_TARGET,
                     alpha=0.15, color=COLORS["success"])
    ax1.fill_between(roll_20.index, roll_20, ACCURACY_TARGET,
                     where=roll_20 < ACCURACY_TARGET,
                     alpha=0.15, color=COLORS["danger"])

    ax1.plot(roll_20.index,  roll_20,  color=COLORS["primary"],  lw=1.5,
             label="20-window rolling accuracy", alpha=0.9)
    ax1.plot(roll_100.index, roll_100, color=COLORS["purple"],   lw=2.5,
             label="100-window rolling accuracy")

    ax1.axhline(results.realized_factor_accuracy, color="black", lw=1.5,
                ls="-", alpha=0.4, label=f"Full period: {results.realized_factor_accuracy:.1%}")

    ax1.set_ylabel("Factor Accuracy", fontsize=11)
    ax1.set_ylim(0.40, 0.85)
    ax1.legend(loc="upper right", fontsize=9)
    ax1.set_title(
        f"Rolling Factor Accuracy  |  Overall: {results.realized_factor_accuracy:.1%}  "
        f"|  Verdict: {results.phase1_verdict.split('—')[0].strip()}",
        fontsize=10
    )

    # ── Bottom: Factor spread (top quartile minus bottom quartile) ────────────
    ax2 = axes[1]
    roll_spread = sp.rolling(50).mean()
    ax2.axhline(0, color=COLORS["neutral"], lw=1, ls="-", alpha=0.5)
    ax2.fill_between(roll_spread.index, 0, roll_spread,
                     where=roll_spread >= 0, alpha=0.3, color=COLORS["success"])
    ax2.fill_between(roll_spread.index, roll_spread, 0,
                     where=roll_spread < 0,  alpha=0.3, color=COLORS["danger"])
    ax2.plot(roll_spread.index, roll_spread, color=COLORS["primary"], lw=1.5)
    ax2.set_ylabel("Top/Bottom Quartile Spread", fontsize=11)
    ax2.set_xlabel("Date", fontsize=11)
    ax2.set_title("50-Window Rolling Return Spread (Top Quartile − Bottom Quartile)", fontsize=10)

    plt.tight_layout()
    plt.savefig(ACCURACY_PLOT, dpi=150, bbox_inches="tight")
    plt.close()
    logger.info(f"Accuracy chart saved: {ACCURACY_PLOT}")


def plot_equity_curve(
    results: BacktestResults,
    window_log: List[WindowResult],
):
    """Portfolio equity curve vs buy-and-hold SPY benchmark."""
    fig, axes = plt.subplots(2, 2, figsize=(14, 8))
    fig.suptitle(
        "BLAQUE BAUX — Phase 1: Portfolio Performance",
        fontsize=14, fontweight="bold"
    )

    timestamps  = [w.timestamp for w in window_log]
    port_rets   = [w.portfolio_return for w in window_log]
    long_rets   = [w.long_return for w in window_log]
    short_rets  = [w.short_return for w in window_log]
    cascade_vals = [w.cascade_strength for w in window_log]

    idx = pd.DatetimeIndex(timestamps)
    ret_series = pd.Series(port_rets, index=idx)

    # ── Equity curve ──────────────────────────────────────────────────────────
    ax = axes[0, 0]
    equity = (1 + ret_series).cumprod()
    ax.plot(equity.index, equity.values, color=COLORS["primary"], lw=2, label="Blaque Baux L/S")
    ax.axhline(1.0, color=COLORS["neutral"], lw=1, ls="--", alpha=0.5)
    ax.set_title(f"Equity Curve  |  Total: {results.total_return:+.1%}", fontsize=10)
    ax.set_ylabel("Portfolio Value (start=1.0)")
    ax.legend(fontsize=9)

    # ── Drawdown ──────────────────────────────────────────────────────────────
    ax = axes[0, 1]
    peak = equity.cummax()
    dd   = (equity - peak) / peak
    ax.fill_between(dd.index, dd.values, 0, alpha=0.5, color=COLORS["danger"])
    ax.set_title(f"Drawdown  |  Max: {results.max_drawdown:.1%}", fontsize=10)
    ax.set_ylabel("Drawdown")

    # ── Return distribution ───────────────────────────────────────────────────
    ax = axes[1, 0]
    wins   = ret_series[ret_series > 0]
    losses = ret_series[ret_series <= 0]
    ax.hist(losses.values * 100, bins=40, color=COLORS["danger"],  alpha=0.6, label="Losses")
    ax.hist(wins.values   * 100, bins=40, color=COLORS["success"], alpha=0.6, label="Wins")
    ax.axvline(0, color="black", lw=1)
    ax.axvline(ret_series.mean() * 100, color=COLORS["primary"], lw=2,
               ls="--", label=f"Mean: {ret_series.mean()*100:.3f}%")
    ax.set_title(f"Return Distribution  |  Win rate: {results.win_rate:.1%}", fontsize=10)
    ax.set_xlabel("Return per window (%)")
    ax.legend(fontsize=9)

    # ── Long vs Short contribution ────────────────────────────────────────────
    ax = axes[1, 1]
    long_series  = pd.Series(long_rets,  index=idx).rolling(50).mean()
    short_series = pd.Series(short_rets, index=idx).rolling(50).mean()
    ax.plot(long_series.index,  long_series.values  * 100, color=COLORS["success"], lw=1.5, label="Long book")
    ax.plot(short_series.index, short_series.values * 100, color=COLORS["danger"],  lw=1.5, label="Short book")
    ax.axhline(0, color=COLORS["neutral"], lw=1, ls="--", alpha=0.5)
    ax.set_title("Long vs Short Book — 50-Window Rolling Mean Return", fontsize=10)
    ax.set_ylabel("Return (%)")
    ax.legend(fontsize=9)

    plt.tight_layout()
    plt.savefig(EQUITY_CURVE_PLOT, dpi=150, bbox_inches="tight")
    plt.close()
    logger.info(f"Equity curve saved: {EQUITY_CURVE_PLOT}")


def plot_signal_analysis(window_log: List[WindowResult]):
    """Cascade signal analysis — does signal strength predict accuracy?"""
    path = os.path.join(OUTPUT_DIR, "signal_analysis.png")
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("BLAQUE BAUX — Phase 1: Signal Analysis", fontsize=13, fontweight="bold")

    cascade = [w.cascade_strength for w in window_log]
    hits    = [1.0 if w.factor_accuracy_hit else 0.0 for w in window_log]

    # ── Accuracy by cascade strength quartile ────────────────────────────────
    ax = axes[0]
    df = pd.DataFrame({"cascade": cascade, "hit": hits})
    df["cascade_q"] = pd.qcut(df["cascade"], q=4,
                               labels=["Weak\nbear", "Mild\nbear", "Mild\nbull", "Strong\nbull"])
    acc_by_q = df.groupby("cascade_q", observed=True)["hit"].mean()
    bars = ax.bar(acc_by_q.index, acc_by_q.values, color=[
        COLORS["danger"], COLORS["warning"], COLORS["success"], COLORS["primary"]
    ], alpha=0.8, edgecolor="white")
    ax.axhline(ACCURACY_TARGET, color="black", lw=1.5, ls="--", alpha=0.6,
               label=f"Target ({ACCURACY_TARGET:.0%})")
    ax.set_title("Factor Accuracy by Cascade Signal Quartile", fontsize=10)
    ax.set_ylabel("Factor Accuracy")
    ax.set_ylim(0.4, 0.85)
    for bar, val in zip(bars, acc_by_q.values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.005,
                f"{val:.1%}", ha="center", va="bottom", fontsize=9)
    ax.legend(fontsize=9)

    # ── Spread by cascade strength ────────────────────────────────────────────
    ax = axes[1]
    df["spread"] = [w.factor_spread for w in window_log]
    spread_by_q = df.groupby("cascade_q", observed=True)["spread"].mean()
    bars = ax.bar(spread_by_q.index, spread_by_q.values * 100, color=[
        COLORS["danger"], COLORS["warning"], COLORS["success"], COLORS["primary"]
    ], alpha=0.8, edgecolor="white")
    ax.axhline(0, color="black", lw=1, alpha=0.5)
    ax.set_title("Avg Return Spread by Cascade Signal Quartile", fontsize=10)
    ax.set_ylabel("Top/Bottom Quartile Spread (%)")
    for bar, val in zip(bars, spread_by_q.values * 100):
        ax.text(bar.get_x() + bar.get_width()/2,
                bar.get_height() + (0.001 if val >= 0 else -0.003),
                f"{val:.3f}%", ha="center", va="bottom" if val >= 0 else "top", fontsize=9)

    plt.tight_layout()
    plt.savefig(path, dpi=150, bbox_inches="tight")
    plt.close()
    logger.info(f"Signal analysis saved: {path}")


# ── CONSOLE SUMMARY ───────────────────────────────────────────────────────────

def print_summary(results: BacktestResults):
    """Print a clean Phase 1 summary to console."""
    verdict_color = {
        "STRONG":     "\033[92m",  # green
        "PASS":       "\033[92m",  # green
        "BORDERLINE": "\033[93m",  # yellow
        "FAIL":       "\033[91m",  # red
        "INSUFFICIENT": "\033[91m",
    }
    v_key = results.phase1_verdict.split("—")[0].strip().split()[0]
    color = verdict_color.get(v_key, "")
    reset = "\033[0m"

    print(f"\n{'═'*60}")
    print(f"  BLAQUE BAUX — Phase 1 Signal Validation")
    print(f"  {results.start_date} → {results.end_date}")
    print(f"{'═'*60}")
    print(f"\n  {'THE NUMBER':.<35} {results.realized_factor_accuracy:.1%}")
    print(f"  {'(realized factor accuracy)':.<35}")
    print(f"\n  {'Win rate (L/S combined)':.<35} {results.win_rate:.1%}")
    print(f"  {'Avg return spread':.<35} {results.avg_spread*100:+.4f}%/window")
    print(f"  {'Annualized return':.<35} {results.annualized_return:+.1%}")
    print(f"  {'Sharpe ratio':.<35} {results.sharpe_ratio:.2f}")
    print(f"  {'Max drawdown':.<35} {results.max_drawdown:.1%}")
    print(f"  {'Profit factor':.<35} {results.profit_factor:.2f}x")
    print(f"  {'Total windows tested':.<35} {results.n_windows:,}")
    print(f"  {'QP solve failure rate':.<35} {results.qp_failure_rate:.1%}")
    print(f"\n  {'Phase 2 gate (58%)':.<35} {'✓ PASSED' if results.realized_factor_accuracy >= ACCURACY_TARGET else '✗ NOT MET'}")
    print(f"  {'Strong signal (63%)':.<35} {'✓ CONFIRMED' if results.realized_factor_accuracy >= ACCURACY_STRONG else '— not reached'}")
    print(f"\n  VERDICT: {color}{results.phase1_verdict}{reset}")
    print(f"\n  Results saved to: {RESULTS_JSON}")
    print(f"  Charts saved to:  {OUTPUT_DIR}/")
    print(f"{'═'*60}\n")
