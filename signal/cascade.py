"""
blaque_baux/signal/cascade.py
──────────────────────────────
Implements the circular futures cascade signal.

The cascade logic:
  US close  → informs APAC open signal (APAC gets 1 prior session)
  APAC close → informs EMEA open signal (EMEA gets 1 prior session)
  EMEA close → informs US open signal   (US gets 2 prior sessions)

For Phase 1 (US only), this translates to:
  Prior day's US session performance → today's US open signal boost

The cascade_boost is the accuracy multiplier we validated in the simulator.
In Phase 4 (global), this extends to the full circular structure.

Output per bar: a cascade_strength float in [-1, +1]
  +1 = strong prior session tailwind (cascade boosts long signal)
  -1 = strong prior session headwind (cascade boosts short signal)
   0 = neutral / no cascade signal
"""

import logging
from typing import Optional

import numpy as np
import pandas as pd

from config import signal_cfg, FUTURES_SIGNALS

logger = logging.getLogger(__name__)


# ── PRIOR SESSION PERFORMANCE ─────────────────────────────────────────────────

def compute_prior_session_returns(
    signal_returns: pd.DataFrame,
) -> pd.Series:
    """
    For each trading day, compute the prior day's aggregate signal return.
    This is the raw cascade input — how did the prior session close?

    Uses SPY + QQQ + IWM as the primary cascade signal (broad market).
    """
    # Weight the three broad-market ETFs to form a single market signal
    broad_tickers = [t for t in ["SPY", "QQQ", "IWM"] if t in signal_returns.columns]
    if not broad_tickers:
        logger.warning("No broad market signal tickers found in signal_returns")
        return pd.Series(0, index=signal_returns.index)

    weights = {"SPY": 0.50, "QQQ": 0.35, "IWM": 0.15}
    broad_signal = sum(
        signal_returns[t] * weights.get(t, 0.1)
        for t in broad_tickers
        if t in signal_returns.columns
    )

    # Compute daily session total returns
    # Handle both tz-aware and tz-naive indices
    idx = signal_returns.index
    if idx.tz is None:
        et_index = idx.tz_localize("UTC").tz_convert("America/New_York")
    else:
        et_index = idx.tz_convert("America/New_York")
    dates = et_index.date
    unique_dates = sorted(set(dates))

    prior_session = pd.Series(0.0, index=signal_returns.index)

    for i in range(1, len(unique_dates)):
        today = unique_dates[i]
        yesterday = unique_dates[i - 1]

        prior_mask = dates == yesterday
        today_mask = dates == today

        if prior_mask.sum() == 0:
            continue

        # Prior session aggregate return
        prior_ret = (1 + broad_signal[prior_mask]).prod() - 1
        prior_session[today_mask] = prior_ret

    return prior_session


# ── INTRADAY FUTURES MOMENTUM ─────────────────────────────────────────────────

def compute_futures_momentum(
    signal_returns: pd.DataFrame,
    lookback: int = None,
) -> pd.DataFrame:
    """
    Compute rolling momentum for each signal source over the lookback window.
    This is the intraday signal — what are futures doing RIGHT NOW?

    Returns DataFrame of momentum scores per signal source, same index as input.
    """
    lookback = lookback or signal_cfg.momentum_lookback
    momentum = {}

    for ticker in signal_returns.columns:
        # Rolling sum of returns over lookback bars
        roll_ret = signal_returns[ticker].rolling(lookback, min_periods=1).sum()
        # Normalize to z-score over trailing 50 bars
        roll_mean = roll_ret.rolling(50, min_periods=10).mean()
        roll_std  = roll_ret.rolling(50, min_periods=10).std().clip(lower=1e-8)
        momentum[ticker] = (roll_ret - roll_mean) / roll_std

    return pd.DataFrame(momentum, index=signal_returns.index).fillna(0)


# ── CASCADE STRENGTH ──────────────────────────────────────────────────────────

def compute_cascade_signal(
    signal_returns: pd.DataFrame,
    lookback: int = None,
) -> pd.Series:
    """
    Combine prior session performance + intraday futures momentum
    into a single cascade_strength signal per bar.

    cascade_strength > 0: bullish tape — favor long weights in optimizer
    cascade_strength < 0: bearish tape — favor short weights in optimizer
    |cascade_strength| magnitude: confidence level

    This is the number that boosts factor accuracy in the cascade regions:
    APAC gets +cascade_boost from US prior session
    EMEA gets +cascade_boost from APAC close
    US gets +2×cascade_boost from both APAC + EMEA
    """
    lookback = lookback or signal_cfg.momentum_lookback

    # 1. Prior session direction (strategic signal)
    prior_session = compute_prior_session_returns(signal_returns)

    # 2. Intraday futures momentum (tactical signal)
    momentum = compute_futures_momentum(signal_returns, lookback)

    # 3. Inter-market cross-asset signal
    inter_market = _compute_inter_market(signal_returns)

    # 4. Combine with weights from config
    w_f = signal_cfg.w_futures_momentum
    w_r = signal_cfg.w_rel_strength
    w_i = signal_cfg.w_inter_market

    # Aggregate momentum across all broad-market futures
    broad_momentum = momentum[
        [t for t in ["SPY", "QQQ", "IWM"] if t in momentum.columns]
    ].mean(axis=1)

    cascade = (
        w_f * broad_momentum +
        w_r * prior_session.clip(-3, 3) / 3 +  # normalize prior session
        w_i * inter_market
    )

    # Smooth slightly to reduce bar-to-bar noise
    cascade = cascade.ewm(span=2, min_periods=1).mean()

    # Clip to [-1, 1] range
    cascade = cascade.clip(-1, 1)

    logger.debug(
        f"Cascade signal: mean={cascade.mean():.4f}, "
        f"std={cascade.std():.4f}, "
        f"bullish_pct={( cascade > 0.1).mean():.1%}"
    )
    return cascade.rename("cascade_strength")


def _compute_inter_market(signal_returns: pd.DataFrame) -> pd.Series:
    """
    Inter-market signal: cross-asset relationships that predict equity moves.
    - TLT falling → rates rising → financials benefit, utilities hurt
    - GLD rising  → risk-off → defensive names benefit
    - UUP rising  → dollar strength → multinationals hurt, importers benefit
    """
    inter = pd.Series(0.0, index=signal_returns.index)

    if "TLT" in signal_returns.columns:
        # Rates proxy: falling TLT = rising rates = broadly equity positive (growth)
        tlt_mom = signal_returns["TLT"].rolling(
            signal_cfg.momentum_lookback, min_periods=1
        ).sum()
        inter -= tlt_mom * 0.4  # rates up = inverse TLT = equity positive signal

    if "GLD" in signal_returns.columns:
        # Gold momentum: rising gold often = risk-off = equity caution signal
        gld_mom = signal_returns["GLD"].rolling(
            signal_cfg.momentum_lookback, min_periods=1
        ).sum()
        inter -= gld_mom * 0.3

    if "UUP" in signal_returns.columns:
        # Dollar strength: mixed for equities; mildly negative for broad market
        uup_mom = signal_returns["UUP"].rolling(
            signal_cfg.momentum_lookback, min_periods=1
        ).sum()
        inter -= uup_mom * 0.3

    return inter.clip(-1, 1)


# ── SECTOR ROTATION SIGNAL ────────────────────────────────────────────────────

def compute_sector_rotation(
    signal_returns: pd.DataFrame,
    lookback: int = None,
) -> pd.Series:
    """
    Which sector is showing the strongest momentum right now?
    Returns a dict-like Series mapping sector name → momentum score.
    Used by the factor model to tilt weights toward hot sectors.
    """
    lookback = lookback or signal_cfg.rel_strength_bars
    sector_etfs = {
        "energy":    "XLE",
        "financials":"XLF",
        "technology":"XLK",
        "healthcare":"XLV",
    }
    scores = {}
    for sector, etf in sector_etfs.items():
        if etf in signal_returns.columns:
            scores[sector] = signal_returns[etf].rolling(
                lookback, min_periods=1
            ).sum()

    if not scores:
        return pd.Series(0.0, index=signal_returns.index)

    sector_df = pd.DataFrame(scores, index=signal_returns.index)
    # Normalize: z-score across sectors at each bar
    sector_mean = sector_df.mean(axis=1)
    sector_std  = sector_df.std(axis=1).clip(lower=1e-8)
    sector_z    = sector_df.sub(sector_mean, axis=0).div(sector_std, axis=0)
    return sector_z
