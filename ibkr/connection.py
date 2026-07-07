"""
blaque_baux/ibkr/connection.py
────────────────────────────────
IBKR connection pool using ib_insync (async Python IBKR API).

Manages both paper trading and live trading connections.
Each pool gets its own connection slot — IBKR supports
up to 32 simultaneous client IDs on a single account.

Paper account:  TWS or IB Gateway on port 7497, client IDs 10–19
Live account:   TWS or IB Gateway on port 7496, client IDs 20–29

Setup required:
  1. Install TWS (Trader Workstation) or IB Gateway
  2. Enable API in TWS: Edit → Global Configuration → API
  3. Allow connections from localhost
  4. Disable read-only API if placing real orders
  5. Set "Master API client ID" to 0

For automated/headless use, IB Gateway is preferred over TWS.
IB Gateway uses less memory and doesn't require a GUI.

Download IB Gateway: https://www.interactivebrokers.com/en/trading/ibgateway-latest.html
"""

import asyncio
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# ib_insync is the async Python wrapper for the IBKR TWS API
# pip install ib_insync
try:
    from ib_insync import IB, util
    IBKR_AVAILABLE = True
except ImportError:
    IBKR_AVAILABLE = False
    logger.warning(
        "ib_insync not installed. Run: pip install ib_insync\n"
        "IBKR connection will be simulated in paper mode."
    )


# ── CONFIGURATION ─────────────────────────────────────────────────────────────

@dataclass
class IBKRConfig:
    """
    IBKR connection configuration.

    Paper trading:  host=127.0.0.1, port=7497
    Live trading:   host=127.0.0.1, port=7496
    IB Gateway paper:  port=4002
    IB Gateway live:   port=4001
    """
    host:           str  = "127.0.0.1"
    paper_port:     int  = 7497    # TWS paper trading
    live_port:      int  = 7496    # TWS live trading
    gateway_paper:  int  = 4002    # IB Gateway paper (preferred for automated)
    gateway_live:   int  = 4001    # IB Gateway live
    timeout:        int  = 10      # connection timeout seconds
    readonly:       bool = False   # set True if you only need market data
    # Client IDs: each connection needs a unique ID
    # Pool mapping: APAC=10, EMEA=11, US=12, COMM=13, CRYPTO=14, 0DTE=15
    base_client_id_paper: int = 10
    base_client_id_live:  int = 20


POOL_CLIENT_IDS = {
    "equities_apac": 10,
    "equities_emea": 11,
    "equities_us":   12,
    "commodities":   13,
    "crypto":        14,
    "dte_overlay":   15,
    "coordinator":   9,   # health checks, borrow feed
}

DEFAULT_CONFIG = IBKRConfig()


# ── MOCK IB (when ib_insync not available) ────────────────────────────────────

class MockIB:
    """
    Mock IBKR connection for development/testing without TWS running.
    Simulates connection, account data, and order placement.
    """
    def __init__(self, client_id: int):
        self.client_id = client_id
        self._connected = False

    async def connectAsync(self, host, port, clientId, timeout=10):
        await asyncio.sleep(0.1)
        self._connected = True
        logger.info(f"MockIB[{clientId}]: connected (simulated paper)")

    def isConnected(self) -> bool:
        return self._connected

    async def disconnectAsync(self):
        self._connected = False

    def reqAccountSummaryAsync(self, *args, **kwargs):
        return []

    async def reqPositionsAsync(self):
        return []

    async def placeOrderAsync(self, contract, order):
        import random
        class MockTrade:
            orderStatus = type("s", (), {"status": "Filled",
                                          "avgFillPrice": 100.0 * (1 + random.gauss(0, 0.001)),
                                          "filled": order.totalQuantity})()
        return MockTrade()

    def qualifyContracts(self, *contracts):
        return list(contracts)

    def portfolio(self):
        return []

    def accountValues(self):
        return []


# ── CONNECTION POOL ───────────────────────────────────────────────────────────

class IBKRConnectionPool:
    """
    Manages a pool of IBKR connections, one per trading pool.

    Each pool gets a dedicated client ID to avoid message routing
    conflicts. The coordinator gets its own ID for health checks
    and the borrow rate feed.

    Thread-safe: each connection is used by exactly one asyncio task.
    """

    def __init__(
        self,
        paper:  bool = True,
        config: IBKRConfig = DEFAULT_CONFIG,
    ):
        self.paper   = paper
        self.config  = config
        self._conns: Dict[str, "IB"] = {}
        self._lock   = asyncio.Lock()

        port_map = {
            True:  config.paper_port,   # TWS paper
            False: config.live_port,    # TWS live
        }
        self._port = port_map[paper]
        logger.info(
            f"IBKRConnectionPool initialized | "
            f"{'PAPER' if paper else '*** LIVE ***'} | "
            f"port={self._port}"
        )

    async def connect(self):
        """
        Establish connections for all registered pools.
        Called once at coordinator startup.
        """
        logger.info("IBKR: connecting pools...")
        for pool_id, client_id in POOL_CLIENT_IDS.items():
            await self._connect_pool(pool_id, client_id)
        logger.info(f"IBKR: {len(self._conns)} connections established")

    async def _connect_pool(self, pool_id: str, client_id: int):
        actual_id = (
            client_id
            if self.paper
            else client_id + (self.config.base_client_id_live -
                               self.config.base_client_id_paper)
        )
        try:
            if IBKR_AVAILABLE:
                ib = IB()
                await ib.connectAsync(
                    host     = self.config.host,
                    port     = self._port,
                    clientId = actual_id,
                    timeout  = self.config.timeout,
                )
            else:
                ib = MockIB(actual_id)
                await ib.connectAsync(
                    self.config.host, self._port, actual_id
                )

            self._conns[pool_id] = ib
            logger.info(f"  IBKR[{pool_id}]: client_id={actual_id} connected")

        except Exception as e:
            logger.error(f"  IBKR[{pool_id}]: connection failed: {e}")
            # Use mock as fallback
            mock = MockIB(actual_id)
            await mock.connectAsync(self.config.host, self._port, actual_id)
            self._conns[pool_id] = mock

    def get(self, pool_id: str) -> Optional["IB"]:
        """Get the connection for a specific pool."""
        return self._conns.get(pool_id)

    async def disconnect(self):
        for pool_id, ib in self._conns.items():
            try:
                await ib.disconnectAsync()
                logger.info(f"  IBKR[{pool_id}]: disconnected")
            except Exception as e:
                logger.warning(f"  IBKR[{pool_id}]: disconnect error: {e}")
        self._conns.clear()

    def is_connected(self, pool_id: str) -> bool:
        ib = self._conns.get(pool_id)
        return ib.isConnected() if ib else False

    def health_report(self) -> Dict:
        return {
            pid: {"connected": self.is_connected(pid)}
            for pid in POOL_CLIENT_IDS
        }
