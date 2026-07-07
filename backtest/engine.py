"""
blaque_baux/backtest/engine.py
───────────────────────────────
Walk-forward backtest engine for Phase 1 signal validation.

Walk-forward methodology:
  For each window t:
    1. Use returns[t-train_window : t] to estimate covariance
    2. Use signal at bar t to generate factor scores
    3. Run QP optimizer → weights
    4. Compute realized return from returns[t+1]
    5. Record: predicted direction, actual direction, P&L, accuracy

This avoids look-ahead bias — the model only uses information
available at the time of the signal.

Phase 1 output: the single most important number is
    realized_factor_accuracy = correct_windows / total_windows

Everything else — return, Sharpe, drawdown — is secondary to that number.
"""

import logging
import os
import sys
import json
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field, asdict

import numpy as np
import pandas as pd
from tqdm import tqdm

from config import (
    backtest_cfg,
    optimizer_cfg,
    signal_cfg,
    N_LONGS,
    N_SHORTS,
    OUTPUT_DIR,
)
from signal.cascade import compute_cascade_signal
from signal.factors import compute_factor_scores, select_long_short, measure_window_accuracy
from optimizer.qp_solver import optimize_portfolio

# ── HybridSignalEngine: per-bar Bayesian signal for backtest accuracy ──────────
# update_bar() runs Kalman filter + NIG Bayesian updater + James-Stein shrinkage.
# Lets us measure Kalman/Bayesian accuracy vs raw factor accuracy head-to-head.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
try:
    from blaque_baux.signal_engine import HybridSignalEngine
    _SIGNAL_ENGINE_AVAILABLE = True
except ImportError:
    try:
        # Fallback: look one level up (blaque_baux-v2 parent = project root sibling)
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "blaque_baux"))
        from signal_engine import HybridSignalEngine
        _SIGNAL_ENGINE_AVAILABLE = True
    except ImportError:
        _SIGNAL_ENGINE_AVAILABLE = False
        HybridSignalEngine = None

logger = logging.getLogger(__name__)


# ── RESULT STRUCTURES ─────────────────────────────────────────────────────────

@dataclass
class WindowResult:
    """Stores the outcome of a single 15-min trading window."""
    timestamp:           pd.Timestamp
    factor_accuracy_hit: bool          # did top-quartile beat bottom-quartile?
    factor_spread:       float         # actual return spread (top - bottom quartile)
    portfolio_return:    float         # realized weighted portfolio return
    long_return:         float         # long book return
    short_return:        float         # short book return (positive = shorts fell)
    n_long:              int
    n_short:             int
    cascade_strength:    float         # cascade signal value at this bar
    qp_status:           str           # optimizer status
    expected_return:     float         # optimizer's predicted return
    expected_vol:        float         # optimizer's predicted volatility
    # ── Kalman/Bayesian signal engine accuracy (vs raw factor accuracy) ────────
    kalman_accuracy_hit: bool  = False  # did Kalman alpha top-quartile beat bottom?
    kalman_alpha_spread: float = 0.0    # realized spread from Kalman alpha ranking
    signal_uncertainty:  float = 0.0    # mean posterior uncertainty this bar


@dataclass
class BacktestResults:
    """Aggregate results for the full backtest period."""
    # THE key metric — this is what we're here to measure
    realized_factor_accuracy: float = 0.0
    accuracy_by_week:         List[float] = field(default_factory=list)
    accuracy_rolling_20:      List[float] = field(default_factory=list)

    # Portfolio performance
    total_return:    float = 0.0
    annualized_return: float = 0.0
    sharpe_ratio:    float = 0.0
    max_drawdown:    float = 0.0
    win_rate:        float = 0.0       # % of windows with positive P&L
    avg_win:         float = 0.0
    avg_loss:        float = 0.0
    profit_factor:   float = 0.0

    # Distribution
    p10_return:      float = 0.0       # worst 10% of windows
    p90_return:      float = 0.0       # best 10% of windows
    avg_spread:      float = 0.0       # average top/bottom quartile spread

    # Metadata
    n_windows:       int   = 0
    n_valid_windows: int   = 0
    qp_failure_rate: float = 0.0
    start_date:      str   = ""
    end_date:        str   = ""
    signal_params:   dict  = field(default_factory=dict)

    # Phase 1 verdict
    phase1_verdict:  str   = ""        # PROCEED / INVESTIGATE / REBUILD

    # ── Kalman/Bayesian vs raw factor accuracy comparison ─────────────────────
    kalman_factor_accuracy: float = 0.0   # Kalman alpha top/bottom quartile accuracy
    bayesian_vs_raw_lift:   float = 0.0   # kalman_accuracy - raw accuracy (lift)
    signal_engine_used:     bool  = False # True when HybridSignalEngine was available


# ── BACKTEST ENGINE ───────────────────────────────────────────────────────────

class BacktestEngine:
    """
    Walk-forward backtest engine for Blaque Baux Phase 1.

    Usage:
        engine = BacktestEngine(close_prices, equity_returns, signal_returns)
        results, window_log = engine.run()
    """

    def __init__(
        self,
        close_prices:    pd.DataFrame,
        equity_returns:  pd.DataFrame,
        signal_returns:  pd.DataFrame,
    ):
        self.close_prices   = close_prices
        self.equity_returns = equity_returns
        self.signal_returns = signal_returns
        self.n_bars         = len(close_prices)
        self.tickers        = list(close_prices.columns)

        # Pre-compute cascade signal and factor scores for all bars
        logger.info("Pre-computing cascade signal...")
        self.cascade_signal = compute_cascade_signal(signal_returns)

        logger.info("Pre-computing factor scores...")
        self.factor_scores = compute_factor_scores(
            equity_returns,
            signal_returns,
            self.cascade_signal,
        )

        # ── HybridSignalEngine: stateful per-bar Kalman + Bayesian signal ──────
        # Runs alongside raw factor scoring to measure accuracy head-to-head.
        # update_bar() produces (alpha, uncertainty, active_mask) at each bar.
        # We rank by alpha to get a Kalman/Bayesian long-short book and measure
        # whether it beat the raw factor-score book in the next bar.
        if _SIGNAL_ENGINE_AVAILABLE:
            logger.info(
                f"HybridSignalEngine initialized — "
                f"{len(self.tickers)} assets, Kalman+Bayesian accuracy tracking active"
            )
            self._signal_engine = HybridSignalEngine(
                n_assets   = len(self.tickers),
                tickers    = self.tickers,
                z_threshold = 1.5,
            )
        else:
            logger.warning(
                "HybridSignalEngine not available — "
                "Kalman/Bayesian accuracy metrics will be skipped"
            )
            self._signal_engine = None

    def run(self, verbose: bool = True) -> Tuple[BacktestResults, List[WindowResult]]:
        """
        Run the full walk-forward backtest.

        Returns:
            results:    BacktestResults aggregate
            window_log: List[WindowResult] per-window detail
        """
        train_window = backtest_cfg.train_window_bars
        step         = backtest_cfg.step_size
        window_log: List[WindowResult] = []

        # Track portfolio equity curve
        portfolio_value = 1.0
        equity_curve = [portfolio_value]
        prev_weights: Optional[Dict[str, float]] = None

        # Walk-forward loop
        start_idx = train_window
        indices = range(start_idx, self.n_bars - 1, step)

        iterator = tqdm(indices, desc="Walk-forward backtest") if verbose else indices

        for t in iterator:
            # ── Training window ──────────────────────────────────────────────
            train_returns = self.equity_returns.iloc[t - train_window : t]

            # ── Signal at bar t ──────────────────────────────────────────────
            scores_t     = self.factor_scores.iloc[t]
            cascade_t    = float(self.cascade_signal.iloc[t])
            timestamp_t  = self.equity_returns.index[t]

            # ── Select long/short candidates ─────────────────────────────────
            long_tickers, short_tickers = select_long_short(
                scores_t, N_LONGS, N_SHORTS
            )
            if not long_tickers or not short_tickers:
                continue

            # ── QP optimize ──────────────────────────────────────────────────
            weights, meta = optimize_portfolio(
                factor_scores    = scores_t,
                returns_history  = train_returns,
                long_tickers     = long_tickers,
                short_tickers    = short_tickers,
                prev_weights     = prev_weights,
            )

            # ── Realized return at bar t+1 ───────────────────────────────────
            next_returns = self.equity_returns.iloc[t + 1]
            portfolio_ret = sum(
                weights.get(ticker, 0) * next_returns.get(ticker, 0)
                for ticker in weights
            )
            # Net of execution drag (both legs)
            net_ret = portfolio_ret - optimizer_cfg.execution_drag * 2

            # ── Factor accuracy measurement ──────────────────────────────────
            accuracy_hit, spread = measure_window_accuracy(scores_t, next_returns)

            # ── Kalman/Bayesian accuracy (HybridSignalEngine) ─────────────────
            # Feed this bar's returns into the signal engine and measure whether
            # the Kalman alpha ranking beats the raw factor score ranking.
            kalman_hit        = False
            kalman_spread     = 0.0
            mean_uncertainty  = 0.0

            if self._signal_engine is not None:
                try:
                    returns_bar = self.equity_returns.iloc[t]
                    alpha, uncertainty, active_mask = self._signal_engine.update_bar(
                        returns_bar
                    )
                    mean_uncertainty = float(np.mean(uncertainty))

                    # Build alpha Series aligned to tickers
                    alpha_s = pd.Series(
                        alpha * active_mask.astype(float),
                        index=self.tickers,
                    ).reindex(next_returns.index).dropna()

                    # Kalman accuracy: top-quartile alpha vs bottom-quartile alpha
                    if len(alpha_s) >= 4:
                        kalman_hit, kalman_spread = measure_window_accuracy(
                            alpha_s, next_returns
                        )
                except Exception as _exc:
                    logger.debug(f"Signal engine update_bar failed at t={t}: {_exc}")

            # ── Long/short split P&L ─────────────────────────────────────────
            long_ret = np.mean([
                next_returns.get(t, 0)
                for t in long_tickers if t in next_returns.index
            ])
            short_ret = -np.mean([
                next_returns.get(t, 0)
                for t in short_tickers if t in next_returns.index
            ])  # positive when shorts fell

            # ── Update portfolio ─────────────────────────────────────────────
            portfolio_value *= (1 + net_ret)
            equity_curve.append(portfolio_value)
            prev_weights = weights

            # ── Log window ───────────────────────────────────────────────────
            window_log.append(WindowResult(
                timestamp           = timestamp_t,
                factor_accuracy_hit = accuracy_hit,
                factor_spread       = spread,
                portfolio_return    = net_ret,
                long_return         = long_ret,
                short_return        = short_ret,
                n_long              = len(long_tickers),
                n_short             = len(short_tickers),
                cascade_strength    = cascade_t,
                qp_status           = meta.get("status", "unknown"),
                expected_return     = meta.get("expected_return", 0),
                expected_vol        = meta.get("expected_vol", 0),
                kalman_accuracy_hit = kalman_hit,
                kalman_alpha_spread = kalman_spread,
                signal_uncertainty  = mean_uncertainty,
            ))

        # ── Aggregate results ────────────────────────────────────────────────
        results = self._aggregate(window_log, equity_curve)
        logger.info(f"\n{'='*60}")
        logger.info(f"PHASE 1 RESULTS")
        logger.info(f"{'='*60}")
        logger.info(f"Realized factor accuracy: {results.realized_factor_accuracy:.1%}")
        if results.signal_engine_used:
            lift_sign = "+" if results.bayesian_vs_raw_lift >= 0 else ""
            logger.info(
                f"Kalman/Bayesian accuracy: {results.kalman_factor_accuracy:.1%}  "
                f"(lift vs raw: {lift_sign}{results.bayesian_vs_raw_lift:.1%})"
            )
        logger.info(f"Annualized return:        {results.annualized_return:.1%}")
        logger.info(f"Sharpe ratio:             {results.sharpe_ratio:.2f}")
        logger.info(f"Max drawdown:             {results.max_drawdown:.1%}")
        logger.info(f"Win rate:                 {results.win_rate:.1%}")
        logger.info(f"Phase 1 verdict:          {results.phase1_verdict}")
        logger.info(f"{'='*60}")

        return results, window_log

    def _aggregate(
        self,
        window_log: List[WindowResult],
        equity_curve: List[float],
    ) -> BacktestResults:
        """Compute aggregate statistics from window log."""
        if not window_log:
            return BacktestResults(phase1_verdict="INSUFFICIENT_DATA")

        # Factor accuracy (raw factor scores)
        n_valid   = sum(1 for w in window_log if w.factor_spread != 0)
        n_correct = sum(1 for w in window_log if w.factor_accuracy_hit)
        accuracy  = n_correct / n_valid if n_valid > 0 else 0.0

        # Rolling accuracy (20-window)
        acc_series = pd.Series([w.factor_accuracy_hit for w in window_log]).astype(float)
        rolling_acc = acc_series.rolling(20, min_periods=5).mean().dropna().tolist()

        # Kalman/Bayesian accuracy (HybridSignalEngine)
        kalman_valid   = sum(1 for w in window_log if w.kalman_alpha_spread != 0)
        kalman_correct = sum(1 for w in window_log if w.kalman_accuracy_hit)
        kalman_accuracy = kalman_correct / kalman_valid if kalman_valid > 0 else 0.0
        bayesian_lift   = kalman_accuracy - accuracy   # positive = Kalman beats raw

        # Weekly accuracy
        timestamps = [w.timestamp for w in window_log]
        acc_df = pd.DataFrame({
            "timestamp": timestamps,
            "hit": [w.factor_accuracy_hit for w in window_log]
        }).set_index("timestamp")
        weekly_acc = acc_df.resample("W").mean()["hit"].tolist()

        # Portfolio performance
        returns = pd.Series([w.portfolio_return for w in window_log])
        equity  = pd.Series(equity_curve)

        total_ret     = equity.iloc[-1] / equity.iloc[0] - 1
        n_windows     = len(returns)
        bars_per_year = 252 * 26  # 26 15-min bars/day
        annual_ret    = (1 + total_ret) ** (bars_per_year / n_windows) - 1

        # Sharpe
        ann_vol = returns.std() * np.sqrt(bars_per_year)
        sharpe  = annual_ret / ann_vol if ann_vol > 0 else 0

        # Drawdown
        peak = equity.cummax()
        dd   = (equity - peak) / peak
        max_dd = float(dd.min())

        # Win rate
        wins   = returns[returns > 0]
        losses = returns[returns <= 0]
        win_rate    = len(wins) / n_windows if n_windows > 0 else 0
        avg_win     = float(wins.mean()) if len(wins) > 0 else 0
        avg_loss    = float(losses.mean()) if len(losses) > 0 else 0
        profit_factor = abs(wins.sum() / losses.sum()) if losses.sum() != 0 else float("inf")

        # QP failure rate
        qp_failures = sum(1 for w in window_log if w.qp_status == "failed")
        qp_fail_rate = qp_failures / n_windows if n_windows > 0 else 0

        # Phase 1 verdict
        from config import ACCURACY_TARGET, ACCURACY_STRONG
        if accuracy >= ACCURACY_STRONG:
            verdict = "STRONG — PROCEED TO PHASE 2 IMMEDIATELY"
        elif accuracy >= ACCURACY_TARGET:
            verdict = "PASS — PROCEED TO PHASE 2"
        elif accuracy >= 0.54:
            verdict = "BORDERLINE — INVESTIGATE SIGNAL BEFORE PHASE 2"
        else:
            verdict = "FAIL — REBUILD SIGNAL BEFORE PHASE 2"

        return BacktestResults(
            realized_factor_accuracy = accuracy,
            accuracy_by_week         = weekly_acc,
            accuracy_rolling_20      = rolling_acc,
            total_return             = float(total_ret),
            annualized_return        = float(annual_ret),
            sharpe_ratio             = float(sharpe),
            max_drawdown             = float(max_dd),
            win_rate                 = float(win_rate),
            avg_win                  = avg_win,
            avg_loss                 = avg_loss,
            profit_factor            = float(profit_factor),
            p10_return               = float(returns.quantile(0.10)),
            p90_return               = float(returns.quantile(0.90)),
            avg_spread               = float(np.mean([w.factor_spread for w in window_log])),
            n_windows                = n_windows,
            n_valid_windows          = n_valid,
            qp_failure_rate          = qp_fail_rate,
            start_date               = str(timestamps[0].date()) if timestamps else "",
            end_date                 = str(timestamps[-1].date()) if timestamps else "",
            signal_params            = {
                "momentum_lookback":  signal_cfg.momentum_lookback,
                "ewma_lambda":        0.94,
                "w_futures_momentum": signal_cfg.w_futures_momentum,
                "w_rel_strength":     signal_cfg.w_rel_strength,
                "w_inter_market":     signal_cfg.w_inter_market,
            },
            phase1_verdict           = verdict,
            kalman_factor_accuracy   = kalman_accuracy,
            bayesian_vs_raw_lift     = bayesian_lift,
            signal_engine_used       = _SIGNAL_ENGINE_AVAILABLE,
        )

    def save_window_log(
        self,
        window_log: List[WindowResult],
        path: str = "./results/window_log.parquet",
    ):
        """Save per-window log for detailed analysis."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        df = pd.DataFrame([
            {
                "timestamp":           w.timestamp,
                "factor_accuracy_hit": w.factor_accuracy_hit,
                "factor_spread":       w.factor_spread,
                "kalman_accuracy_hit": w.kalman_accuracy_hit,
                "kalman_alpha_spread": w.kalman_alpha_spread,
                "signal_uncertainty":  w.signal_uncertainty,
                "portfolio_return":    w.portfolio_return,
                "long_return":         w.long_return,
                "short_return":        w.short_return,
                "cascade_strength":    w.cascade_strength,
                "qp_status":           w.qp_status,
            }
            for w in window_log
        ])
        df.to_parquet(path)
        logger.info(f"Window log saved: {path}")
        return df
