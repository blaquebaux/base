"""
blaque_baux/data/fetcher.py
────────────────────────────
Fetches 15-min OHLCV bars from Polygon.io for:
  - Equity universe (long/short candidates)
  - Futures/ETF signal sources (cascade inputs)

Data is cached locally as parquet to avoid redundant API calls.
Re-fetch only when cache is stale or missing.

Polygon.io free tier: 5 API calls/minute.
Polygon.io paid tier: unlimited. Phase 1 recommends paid ($29/mo).
"""

import os
import time
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd
import numpy as np
import requests

from config import (
    POLYGON_API_KEY,
    BACKTEST_START,
    BACKTEST_END,
    BAR_MINUTES,
    EQUITY_UNIVERSE,
    FUTURES_SIGNALS,
)

logger = logging.getLogger(__name__)

CACHE_DIR = Path("./data/cache")
CACHE_DIR.mkdir(parents=True, exist_ok=True)

BASE_URL = "https://api.polygon.io/v2/aggs/ticker"


# ── RAW FETCH ─────────────────────────────────────────────────────────────────

def _fetch_bars(
    ticker: str,
    start: str,
    end: str,
    multiplier: int = 15,
    timespan: str = "minute",
    retries: int = 3,
    delay: float = 0.25,
) -> pd.DataFrame:
    """
    Fetch OHLCV bars from Polygon.io REST API.
    Returns a DataFrame indexed by UTC timestamp.
    Handles pagination automatically.
    """
    if not POLYGON_API_KEY:
        raise ValueError(
            "POLYGON_API_KEY not set. Add it to .env file.\n"
            "Get a key at https://polygon.io (free tier works for Phase 1 testing)"
        )

    all_results = []
    url = f"{BASE_URL}/{ticker}/range/{multiplier}/{timespan}/{start}/{end}"
    params = {
        "adjusted": "true",
        "sort": "asc",
        "limit": 50000,
        "apiKey": POLYGON_API_KEY,
    }

    while url:
        for attempt in range(retries):
            try:
                resp = requests.get(url, params=params, timeout=30)
                if resp.status_code == 429:
                    logger.warning(f"Rate limited on {ticker}, waiting 60s...")
                    time.sleep(60)
                    continue
                resp.raise_for_status()
                data = resp.json()
                break
            except Exception as e:
                if attempt == retries - 1:
                    logger.error(f"Failed to fetch {ticker}: {e}")
                    return pd.DataFrame()
                time.sleep(delay * (attempt + 1))

        results = data.get("results", [])
        all_results.extend(results)

        # Polygon paginates via next_url
        next_url = data.get("next_url")
        if next_url:
            url = next_url
            params = {"apiKey": POLYGON_API_KEY}  # key goes in params for next_url
        else:
            break

        time.sleep(delay)

    if not all_results:
        logger.warning(f"No data returned for {ticker}")
        return pd.DataFrame()

    df = pd.DataFrame(all_results)
    df["timestamp"] = pd.to_datetime(df["t"], unit="ms", utc=True)
    df = df.set_index("timestamp")
    df = df.rename(columns={
        "o": "open", "h": "high", "l": "low",
        "c": "close", "v": "volume", "vw": "vwap", "n": "trades"
    })
    df = df[["open", "high", "low", "close", "volume", "vwap"]].sort_index()

    # Remove pre/post market bars — keep 9:30–16:00 ET only
    et_index = df.index.tz_convert("America/New_York")
    market_mask = (
        (et_index.time >= pd.Timestamp("09:30").time()) &
        (et_index.time <= pd.Timestamp("15:45").time()) &
        (et_index.weekday < 5)
    )
    df = df[market_mask]
    return df


# ── CACHE LAYER ───────────────────────────────────────────────────────────────

def _cache_path(ticker: str) -> Path:
    return CACHE_DIR / f"{ticker}_{BAR_MINUTES}min.parquet"


def _is_cache_fresh(path: Path) -> bool:
    if not path.exists():
        return False
    age_days = (datetime.now() - datetime.fromtimestamp(path.stat().st_mtime)).days
    return age_days < 7  # refresh weekly


def load_ticker(ticker: str, force_refresh: bool = False) -> pd.DataFrame:
    """
    Load OHLCV bars for a single ticker.
    Uses local parquet cache; fetches from Polygon.io if stale/missing.
    """
    cache = _cache_path(ticker)

    if not force_refresh and _is_cache_fresh(cache):
        logger.debug(f"Loading {ticker} from cache")
        return pd.read_parquet(cache)

    logger.info(f"Fetching {ticker} from Polygon.io ({BACKTEST_START} → {BACKTEST_END})")
    df = _fetch_bars(ticker, BACKTEST_START, BACKTEST_END)

    if not df.empty:
        df.to_parquet(cache)
        logger.info(f"  {ticker}: {len(df)} bars cached")
    else:
        logger.warning(f"  {ticker}: empty response, skipping cache")

    return df


# ── BATCH LOADER ──────────────────────────────────────────────────────────────

def load_universe(
    tickers: Optional[List[str]] = None,
    force_refresh: bool = False,
    delay_between: float = 0.25,
) -> Dict[str, pd.DataFrame]:
    """
    Load the full equity universe. Returns dict of {ticker: DataFrame}.
    Respects Polygon.io rate limits with configurable delay between requests.
    """
    tickers = tickers or EQUITY_UNIVERSE
    universe = {}

    for i, ticker in enumerate(tickers):
        df = load_ticker(ticker, force_refresh)
        if not df.empty:
            universe[ticker] = df
        else:
            logger.warning(f"Skipping {ticker} — no data")

        # Rate limiting: free tier = 5 calls/min
        if i % 5 == 4:
            time.sleep(12)  # 12s per 5 calls = 25/min (buffer below free tier limit)
        else:
            time.sleep(delay_between)

    logger.info(f"Universe loaded: {len(universe)}/{len(tickers)} tickers")
    return universe


def load_signals(force_refresh: bool = False) -> Dict[str, pd.DataFrame]:
    """
    Load all futures/ETF signal sources.
    These are used as cascade signal inputs to the factor model.
    """
    signals = {}
    for ticker in FUTURES_SIGNALS:
        df = load_ticker(ticker, force_refresh)
        if not df.empty:
            signals[ticker] = df

    logger.info(f"Signal sources loaded: {list(signals.keys())}")
    return signals


# ── ALIGNMENT ─────────────────────────────────────────────────────────────────

def align_universe(
    universe: Dict[str, pd.DataFrame],
    signals: Dict[str, pd.DataFrame],
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """
    Align all equity and signal DataFrames to a common timestamp index.
    Returns:
        close_prices:  DataFrame [timestamps × tickers]  — equity close prices
        returns:       DataFrame [timestamps × tickers]  — equity 15-min returns
        signal_df:     DataFrame [timestamps × signals]  — signal source close prices
    """
    # Build close price matrix
    close_dict = {t: df["close"] for t, df in universe.items()}
    close_prices = pd.DataFrame(close_dict)

    # Forward-fill small gaps (halts, data drops), drop if >3 consecutive NaN
    close_prices = close_prices.ffill(limit=3).dropna(how="all")

    # Drop timestamps where >20% of universe is missing
    min_valid = int(len(close_prices.columns) * 0.80)
    close_prices = close_prices.dropna(thresh=min_valid)

    # Compute returns
    returns = close_prices.pct_change().fillna(0)

    # Build signal matrix
    sig_dict = {t: df["close"] for t, df in signals.items()}
    signal_df = pd.DataFrame(sig_dict).reindex(close_prices.index).ffill(limit=3)
    signal_returns = signal_df.pct_change().fillna(0)

    logger.info(
        f"Aligned universe: {len(close_prices)} bars × "
        f"{len(close_prices.columns)} tickers"
    )
    return close_prices, returns, signal_returns


# ── CONVENIENCE ───────────────────────────────────────────────────────────────

def load_all(force_refresh: bool = False):
    """
    Top-level convenience function — loads and aligns everything.
    This is the single call used by the backtest engine.

    Returns:
        close_prices, equity_returns, signal_returns
    """
    logger.info("=" * 60)
    logger.info("BLAQUE BAUX — Phase 1 Data Load")
    logger.info(f"Period: {BACKTEST_START} → {BACKTEST_END}")
    logger.info(f"Universe: {len(EQUITY_UNIVERSE)} equities")
    logger.info(f"Signals:  {len(FUTURES_SIGNALS)} sources")
    logger.info("=" * 60)

    universe = load_universe(force_refresh=force_refresh)
    signals  = load_signals(force_refresh=force_refresh)
    return align_universe(universe, signals)
