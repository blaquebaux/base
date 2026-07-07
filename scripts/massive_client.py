"""
massive_client.py — Massive.com market data client for BlaqueBaux dashboard.

Massive.com API base: https://api.massive.com/v1  (set MASSIVE_API_KEY env var)

Set the following environment variables before launching the dashboard:
    export MASSIVE_API_KEY="your-key-here"
    export MASSIVE_API_BASE="https://api.massive.com/v1"   # or your custom endpoint

If MASSIVE_API_KEY is not set, the client falls back to yfinance for local testing.
"""

import os
import logging
import requests
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
from typing import Optional

log = logging.getLogger(__name__)

MASSIVE_API_BASE = os.environ.get("MASSIVE_API_BASE", "https://api.massive.com/v1")
MASSIVE_API_KEY  = os.environ.get("MASSIVE_API_KEY", "")

# ---------------------------------------------------------------------------
# Massive.com REST client
# ---------------------------------------------------------------------------

class MassiveClient:
    """
    Thin wrapper around the Massive.com REST API.
    Adjust the endpoint paths below to match your Massive account tier.
    """

    def __init__(self, api_key: str = MASSIVE_API_KEY, base_url: str = MASSIVE_API_BASE):
        self.base_url = base_url.rstrip("/")
        self.session  = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
            "Accept":        "application/json",
        })

    def _get(self, path: str, params: dict = None) -> dict:
        url = f"{self.base_url}/{path.lstrip('/')}"
        r   = self.session.get(url, params=params, timeout=30)
        r.raise_for_status()
        return r.json()

    # -- Market data endpoints -----------------------------------------------

    def get_prices(
        self,
        tickers: list[str],
        start:   str,          # "YYYY-MM-DD"
        end:     str,          # "YYYY-MM-DD"
        freq:    str = "1d",   # "1d" | "1w" | "1m"
    ) -> pd.DataFrame:
        """
        Fetch adjusted close prices.
        Returns a (T+1) x N DataFrame indexed by date.
        """
        payload = {
            "symbols":   tickers,
            "start_date": start,
            "end_date":   end,
            "frequency":  freq,
            "fields":    ["adjusted_close"],
        }
        data = self._get("/market/prices/bulk", params=payload)

        # Expected response shape:
        # { "data": { "AAPL": [{"date":"2024-01-02","adjusted_close":185.2}, ...], ... } }
        frames = {}
        for ticker, records in data.get("data", {}).items():
            df_t = pd.DataFrame(records).set_index("date")["adjusted_close"]
            df_t.index = pd.to_datetime(df_t.index)
            frames[ticker] = df_t

        if not frames:
            raise ValueError("Massive.com returned no price data")

        prices = pd.DataFrame(frames).sort_index()
        prices = prices.ffill().dropna()
        return prices

    def get_universe(self, exchange: str = "US") -> list[dict]:
        """Return available tickers on the given exchange."""
        data = self._get(f"/reference/universe", params={"exchange": exchange})
        return data.get("symbols", [])

    def ping(self) -> bool:
        try:
            self._get("/health")
            return True
        except Exception:
            return False


# ---------------------------------------------------------------------------
# yfinance fallback (when MASSIVE_API_KEY not set — local dev / testing)
# ---------------------------------------------------------------------------

def _yfinance_prices(tickers: list[str], start: str, end: str) -> pd.DataFrame:
    try:
        import yfinance as yf
        raw = yf.download(tickers, start=start, end=end, auto_adjust=True, progress=False)
        if isinstance(raw.columns, pd.MultiIndex):
            prices = raw["Close"]
        else:
            prices = raw[["Close"]] if len(tickers) == 1 else raw
        prices.columns = tickers[:len(prices.columns)]
        return prices.ffill().dropna()
    except ImportError:
        raise RuntimeError("yfinance not installed — pip install yfinance")


# ---------------------------------------------------------------------------
# Public fetch function (router: Massive → yfinance fallback)
# ---------------------------------------------------------------------------

def fetch_prices(
    tickers: list[str],
    start:   str,
    end:     str,
    freq:    str = "1d",
    force_fallback: bool = False,
) -> pd.DataFrame:
    """
    Fetch adjusted close prices for `tickers` between `start` and `end`.
    Uses Massive.com if MASSIVE_API_KEY is set, otherwise falls back to yfinance.

    Returns a (T+1) x N pd.DataFrame of adjusted close prices, indexed by date.
    """
    if MASSIVE_API_KEY and not force_fallback:
        log.info("Fetching from Massive.com: %s", tickers)
        client = MassiveClient()
        try:
            return client.get_prices(tickers, start, end, freq)
        except Exception as exc:
            log.warning("Massive.com fetch failed (%s) — falling back to yfinance", exc)

    log.info("Fetching from yfinance (fallback): %s", tickers)
    return _yfinance_prices(tickers, start, end)


def prices_to_log_returns(prices: pd.DataFrame) -> np.ndarray:
    """Convert price DataFrame to log-return matrix (T x N), drop NaN row."""
    return np.log(prices / prices.shift(1)).dropna().values


def prices_to_simple_returns(prices: pd.DataFrame) -> np.ndarray:
    return prices.pct_change().dropna().values


# ---------------------------------------------------------------------------
# Convenience: default universe
# ---------------------------------------------------------------------------

DEFAULT_UNIVERSE = [
    "AAPL", "MSFT", "NVDA", "GOOGL", "AMZN",
    "META",  "TSLA", "BRK-B", "JPM",  "UNH",
    "LLY",   "V",    "XOM",   "MA",   "AVGO",
    "JNJ",   "PG",   "HD",    "MRK",  "CVX",
    "ABBV",  "COST", "KO",    "PEP",  "WMT",
    "BAC",   "AMD",  "NFLX",  "CRM",  "TMO",
]


if __name__ == "__main__":
    # Quick smoke test
    import sys
    tickers = sys.argv[1:] or ["AAPL", "MSFT", "NVDA"]
    end   = datetime.today().strftime("%Y-%m-%d")
    start = (datetime.today() - timedelta(days=365)).strftime("%Y-%m-%d")
    prices = fetch_prices(tickers, start, end)
    print(prices.tail())
    R = prices_to_log_returns(prices)
    print(f"Returns shape: {R.shape}")
