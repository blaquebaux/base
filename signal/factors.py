"""
blaque_baux/signal/factors.py
──────────────────────────────
Computes a composite factor score for each stock at each 15-min window.

Three factors, weighted per config:
  1. Futures momentum factor    — does the broad tape support this stock's direction?
  2. Relative strength factor   — is this stock outperforming its sector peers?
  3. Inter-market factor        — does cross-asset signal support this stock's sector?

Output: factor_scores DataFrame [timestamps × tickers]
  Positive score = long candidate
  Negative score = short candidate
  Magnitude = conviction

The top N_LONGS scores → long book
The bottom N_SHORTS scores → short book

Phase 1 validation goal: measure what % of windows the
top-quartile stocks actually outperformed the bottom-quartile.
That percentage IS the realized factor accuracy.
"""

import logging
from typing import Optional

import numpy as np
import pandas as pd

from config import (
    signal_cfg,
    SECTOR_MAP,
    N_LONGS,
    N_SHORTS,
    FUTURES_SIGNALS,
)
from signal.cascade import (
    compute_cascade_signal,
    compute_sector_rotation,
    compute_futures_momentum,
)

logger = logging.getLogger(__name__)


# ── FACTOR 1: FUTURES MOMENTUM ────────────────────────────────────────────────

def futures_momentum_factor(
    returns: pd.DataFrame,
    signal_returns: pd.DataFrame,
    cascade_signal: pd.Series,
) -> pd.DataFrame:
    """
    Map the broad futures/cascade signal onto individual stocks.

    Logic:
    - When cascade is bullish (+), high-beta stocks score higher (long)
    - When cascade is bearish (-), high-beta stocks score lower (short)
    - Beta is computed as rolling correlation × vol ratio (CAPM beta)

    This is the primary factor — cascade signal direction × stock beta.
    """
    # Rolling 1-day beta for each stock vs SPY proxy (broad returns)
    broad_return = signal_returns[
        [c for c in ["SPY", "QQQ"] if c in signal_returns.columns]
    ].mean(axis=1)

    lookback = signal_cfg.momentum_lookback * 8  # ~2 trading days
    scores = pd.DataFrame(index=returns.index, columns=returns.columns, dtype=float)

    for ticker in returns.columns:
        # Rolling correlation with broad market
        corr = returns[ticker].rolling(lookback, min_periods=20).corr(broad_return)
        # Rolling vol ratio (ticker vol / market vol)
        ticker_vol = returns[ticker].rolling(lookback, min_periods=20).std()
        market_vol = broad_return.rolling(lookback, min_periods=20).std().clip(lower=1e-8)
        beta = corr * (ticker_vol / market_vol)
        # Score = cascade signal × stock beta
        scores[ticker] = cascade_signal * beta

    return scores.fillna(0)


# ── FACTOR 2: RELATIVE STRENGTH ───────────────────────────────────────────────

def relative_strength_factor(
    returns: pd.DataFrame,
    signal_returns: pd.DataFrame,
) -> pd.DataFrame:
    """
    Within each sector, rank stocks by their recent performance
    relative to their sector peers.

    Stocks outperforming their sector peers → positive score
    Stocks underperforming their sector peers → negative score

    This captures: "which specific names are the market moving into/out of?"
    independent of broad direction.
    """
    lookback = signal_cfg.rel_strength_bars
    scores = pd.DataFrame(0.0, index=returns.index, columns=returns.columns)

    # Group tickers by sector
    sector_groups: dict[str, list[str]] = {}
    for ticker, sector in SECTOR_MAP.items():
        if ticker in returns.columns:
            sector_groups.setdefault(sector, []).append(ticker)

    for sector, tickers in sector_groups.items():
        if len(tickers) < 2:
            continue

        # Rolling sum of returns for each ticker in this sector
        sector_returns = returns[tickers].rolling(lookback, min_periods=1).sum()

        # Cross-sectional rank within sector (normalized to [-1, +1])
        ranked = sector_returns.rank(axis=1, pct=True)  # 0–1 percentile rank
        normalized = (ranked - 0.5) * 2  # shift to [-1, +1]

        scores[tickers] = normalized

    return scores.fillna(0)


# ── FACTOR 3: INTER-MARKET SECTOR TILT ───────────────────────────────────────

def inter_market_factor(
    returns: pd.DataFrame,
    signal_returns: pd.DataFrame,
) -> pd.DataFrame:
    """
    Use cross-asset signals to tilt toward/away from specific sectors.

    Rules (from our conversation):
    - CL (oil) rising  → overweight energy stocks
    - TLT falling (rates rising) → overweight financials, underweight utilities
    - GLD rising      → defensive tilt (healthcare, consumer staples)
    - UUP rising      → underweight export-heavy multinationals

    Each stock gets a score based on which signals favor its sector.
    """
    scores = pd.DataFrame(0.0, index=returns.index, columns=returns.columns)
    lookback = signal_cfg.momentum_lookback

    # Compute momentum for relevant signal sources
    sector_signal_map = {
        "energy":     ("XLE", +1),   # XLE momentum → energy sector tilt
        "financials": ("XLF", +1),   # XLF momentum → financials tilt
        "technology": ("XLK", +1),   # XLK momentum → tech tilt
        "healthcare": ("XLV", +1),   # XLV momentum → healthcare tilt
        "utilities":  ("TLT", -0.5), # TLT falls (rates up) → utilities hurt
    }

    for sector, (signal_ticker, multiplier) in sector_signal_map.items():
        if signal_ticker not in signal_returns.columns:
            continue

        signal_mom = (
            signal_returns[signal_ticker]
            .rolling(lookback, min_periods=1)
            .sum()
        )
        # Normalize
        sig_mean = signal_mom.rolling(50, min_periods=10).mean()
        sig_std  = signal_mom.rolling(50, min_periods=10).std().clip(lower=1e-8)
        sig_z    = ((signal_mom - sig_mean) / sig_std).clip(-2, 2) * multiplier

        # Apply to all stocks in this sector
        sector_tickers = [t for t, s in SECTOR_MAP.items() if s == sector and t in returns.columns]
        for ticker in sector_tickers:
            scores[ticker] += sig_z * 0.5  # 0.5 weight for inter-market factor

    return scores.fillna(0)


# ── COMPOSITE FACTOR SCORE ────────────────────────────────────────────────────

def compute_factor_scores(
    returns: pd.DataFrame,
    signal_returns: pd.DataFrame,
    cascade_signal: Optional[pd.Series] = None,
) -> pd.DataFrame:
    """
    Combine all three factors into a single composite score per stock per bar.

    Returns DataFrame [timestamps × tickers] of composite scores.
    Higher = stronger long candidate.
    Lower  = stronger short candidate.
    """
    if cascade_signal is None:
        cascade_signal = compute_cascade_signal(signal_returns)

    # Compute individual factors
    f1 = futures_momentum_factor(returns, signal_returns, cascade_signal)
    f2 = relative_strength_factor(returns, signal_returns)
    f3 = inter_market_factor(returns, signal_returns)

    # Weighted combination
    w1 = signal_cfg.w_futures_momentum
    w2 = signal_cfg.w_rel_strength
    w3 = signal_cfg.w_inter_market

    composite = w1 * f1 + w2 * f2 + w3 * f3

    # Cross-sectional z-score at each timestamp (removes time-series level shifts)
    row_mean = composite.mean(axis=1)
    row_std  = composite.std(axis=1).clip(lower=1e-8)
    composite = composite.sub(row_mean, axis=0).div(row_std, axis=0)

    logger.debug(
        f"Factor scores: mean={composite.mean().mean():.4f}, "
        f"std={composite.std().mean():.4f}"
    )
    return composite.fillna(0)


# ── LONG/SHORT SELECTION ──────────────────────────────────────────────────────

def select_long_short(
    factor_scores: pd.Series,
    n_longs: int = N_LONGS,
    n_shorts: int = N_SHORTS,
) -> tuple[list[str], list[str]]:
    """
    Select top N_LONGS and bottom N_SHORTS from factor scores at a single bar.

    Args:
        factor_scores: Series [ticker → score] at one timestamp
        n_longs:       number of long positions
        n_shorts:      number of short positions

    Returns:
        (long_tickers, short_tickers)
    """
    valid = factor_scores.dropna()
    if len(valid) < n_longs + n_shorts:
        # Only warn if critically short (less than half expected universe)
        if len(valid) < (n_longs + n_shorts) // 2:
            logger.warning(f"Only {len(valid)} valid scores — critically small universe")
        n_longs  = max(1, len(valid) // 2)
        n_shorts = max(1, len(valid) - n_longs)

    sorted_scores = valid.sort_values(ascending=False)
    long_tickers  = sorted_scores.head(n_longs).index.tolist()
    short_tickers = sorted_scores.tail(n_shorts).index.tolist()

    return long_tickers, short_tickers


# ── FACTOR ACCURACY MEASUREMENT ───────────────────────────────────────────────

def measure_window_accuracy(
    factor_scores_t: pd.Series,
    next_returns_t: pd.Series,
    quantile: float = 0.25,
) -> tuple[bool, float]:
    """
    For a single window: did the top-quartile predicted stocks
    actually outperform the bottom-quartile stocks in the NEXT bar?

    This is the core Phase 1 measurement.
    Realized factor accuracy = mean(window_accuracy) over all windows.

    Args:
        factor_scores_t: scores at time t (prediction)
        next_returns_t:  actual returns at time t+1 (outcome)
        quantile:        what fraction defines top/bottom (0.25 = quartile)

    Returns:
        (is_correct, spread)
        is_correct: True if top-quartile outperformed bottom-quartile
        spread:     realized return spread (top_mean - bottom_mean)
    """
    valid = factor_scores_t.dropna().index.intersection(next_returns_t.dropna().index)
    if len(valid) < 10:
        return False, 0.0

    scores  = factor_scores_t[valid]
    returns = next_returns_t[valid]

    n = max(1, int(len(valid) * quantile))
    top_tickers    = scores.nlargest(n).index
    bottom_tickers = scores.nsmallest(n).index

    # Success = top quartile outperformed bottom quartile next bar
    top_mean    = returns[top_tickers].mean()
    bottom_mean = returns[bottom_tickers].mean()
    spread      = top_mean - bottom_mean
    is_correct  = spread > 0

    return is_correct, float(spread)
