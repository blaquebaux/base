"""
blaque_baux/ibkr/borrow_feed.py
─────────────────────────────────
Live stock borrow rate feed from IBKR.

Called before every QP solve — the circuit breaker uses this to
filter out hard-to-borrow (HTB) names from the short universe
before the optimizer even sees them.

IBKR provides borrow rates via:
  - reqShortableShares() — availability (shares available to borrow)
  - reqScannerSubscription() — HTB names by fee rate
  - Or via the IBKR Portal API (REST)

Borrow cost tiers:
  Easy-to-borrow (ETB):  0.00–0.75% annualized  → always include
  Medium borrow:         0.75–3.00% annualized   → include if spread covers
  Hard-to-borrow (HTB):  3.00%+ annualized       → exclude (filter_shortable)

The IBKR Short Stock Availability API updates in real-time.
We cache for 60 seconds to avoid hammering the API each window.

Note: Index constituents (S&P 500, Nikkei, FTSE, etc.) are
almost always ETB — this filter is mainly protection against
accidentally including recently-added names or sector rotations
that have attracted heavy short interest.
"""

import asyncio
import logging
import time
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

try:
    from ib_insync import IB, Stock
    IBKR_AVAILABLE = True
except ImportError:
    IBKR_AVAILABLE = False


# ── BORROW RATE FEED ──────────────────────────────────────────────────────────

class BorrowRateFeed:
    """
    Provides live annualized borrow rates for the short universe.

    Caches rates for CACHE_TTL seconds to avoid over-querying.
    Falls back to ETB assumption (0.0%) when IBKR unavailable.
    """

    CACHE_TTL = 60          # seconds between refreshes
    HTB_THRESHOLD = 0.03    # 3% annualized = exclude from short book
    DEFAULT_RATE = 0.0      # assume ETB when rate unknown

    def __init__(self, connection_pool):
        self.pool       = connection_pool
        self._cache:    Dict[str, float] = {}
        self._last_refresh: float = 0.0
        self._refresh_lock = asyncio.Lock()

    async def get_current_rates(
        self,
        tickers: List[str],
    ) -> Dict[str, float]:
        """
        Returns {ticker: annualized_borrow_rate} for all requested tickers.
        Refreshes cache if stale.

        Called at step 2 of the window loop (before circuit breaker filter).
        """
        now = time.time()
        if now - self._last_refresh > self.CACHE_TTL:
            async with self._refresh_lock:
                if now - self._last_refresh > self.CACHE_TTL:
                    await self._refresh(tickers)

        return {t: self._cache.get(t, self.DEFAULT_RATE) for t in tickers}

    async def _refresh(self, tickers: List[str]):
        """
        Refresh borrow rates from IBKR.
        Uses the 'coordinator' connection (client_id=9).
        """
        ib = self.pool.get("coordinator")
        if not ib or not ib.isConnected():
            logger.debug("Borrow feed: IBKR not available, using ETB defaults")
            self._last_refresh = time.time()
            return

        if not IBKR_AVAILABLE:
            # MockIB: return zero borrow cost for all (ETB assumption)
            self._cache = {t: 0.0 for t in tickers}
            self._last_refresh = time.time()
            return

        try:
            # IBKR provides borrow availability via reqShortableShares
            # The fee rate is available via the IBKR Portal API
            # For Phase 3, we use a simplified approach:
            # 1. Request shortable shares count
            # 2. Map low availability → elevated borrow estimate
            new_rates = {}
            batch_size = 20  # IBKR API: process in batches

            for i in range(0, len(tickers), batch_size):
                batch = tickers[i:i+batch_size]
                for ticker in batch:
                    try:
                        contract = Stock(ticker, "SMART", "USD")
                        ib.qualifyContracts(contract)
                        shortable = ib.reqShortableShares(contract)
                        # Map shortable count to borrow cost estimate
                        # <100k shares = HTB territory
                        rate = self._shortable_to_rate(shortable)
                        new_rates[ticker] = rate
                    except Exception:
                        new_rates[ticker] = self.DEFAULT_RATE

                await asyncio.sleep(0.05)  # rate limit

            htb_count = sum(1 for r in new_rates.values() if r >= self.HTB_THRESHOLD)
            if htb_count > 0:
                htb_names = [t for t, r in new_rates.items() if r >= self.HTB_THRESHOLD]
                logger.info(f"Borrow feed: {htb_count} HTB names detected: {htb_names[:5]}")

            self._cache = new_rates
            self._last_refresh = time.time()

        except Exception as e:
            logger.warning(f"Borrow feed refresh failed: {e} — using cached rates")
            self._last_refresh = time.time()  # prevent retry storm

    def _shortable_to_rate(self, shortable_shares: float) -> float:
        """
        Map IBKR shortable shares count to estimated annualized borrow rate.

        Rough tier mapping based on market observation:
          > 10M shares available:  ETB (< 0.5%)
          1M–10M:                  Mild (0.5–1.0%)
          100k–1M:                 Medium (1.0–2.5%)
          10k–100k:                HTB (2.5–5.0%)
          < 10k:                   Very HTB (5.0%+)
        """
        if shortable_shares > 10_000_000:
            return 0.002      # 0.2% — ETB
        elif shortable_shares > 1_000_000:
            return 0.007      # 0.7%
        elif shortable_shares > 100_000:
            return 0.018      # 1.8%
        elif shortable_shares > 10_000:
            return 0.035      # 3.5% — HTB
        else:
            return 0.08       # 8.0% — Very HTB

    def get_cached_rate(self, ticker: str) -> float:
        """Synchronous access to cached rate — use in non-async contexts."""
        return self._cache.get(ticker, self.DEFAULT_RATE)

    def htb_tickers(self, threshold: Optional[float] = None) -> List[str]:
        """Return current HTB tickers above threshold."""
        limit = threshold or self.HTB_THRESHOLD
        return [t for t, r in self._cache.items() if r >= limit]

    def summary(self) -> Dict:
        """Diagnostic summary of current borrow landscape."""
        rates = list(self._cache.values())
        if not rates:
            return {"status": "empty", "last_refresh": self._last_refresh}
        return {
            "total_tickers": len(rates),
            "etb_count":     sum(1 for r in rates if r < 0.0075),
            "medium_count":  sum(1 for r in rates if 0.0075 <= r < self.HTB_THRESHOLD),
            "htb_count":     sum(1 for r in rates if r >= self.HTB_THRESHOLD),
            "max_rate":      max(rates),
            "cache_age_sec": time.time() - self._last_refresh,
        }
