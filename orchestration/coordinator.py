"""
blaque_baux/orchestration/coordinator.py
─────────────────────────────────────────
Blaque Baux main coordinator — the top-level orchestration layer.

Starts and monitors all trading pools simultaneously via asyncio.
Manages the shared service layer (Crypto Quant optimizer, IBKR connection,
borrow feed). Bridges to the @smallclaw/coordination event bus.

Usage:
    python run_live.py           # starts all Phase 3 pools
    python run_live.py --phase 3 # US equity + commodities only
    python run_live.py --phase 4 # full global deployment
    python run_live.py --pool equities_us  # single pool (testing)
    python run_live.py --paper   # paper trading mode (IBKR paper account)

The coordinator never exposes individual pool internals — each pool
is an opaque unit. The coordinator only sees:
  - pool health (status from event bus)
  - aggregate P&L (from window_log)
  - circuit alerts (broadcast messages on event bus)
"""

import asyncio
import logging
import signal
import sys
from typing import Dict, List, Optional, Set

from orchestration.event_bus import make_bus, Memory
from orchestration.optimizer_service import get_optimizer
from orchestration.pool_manager import PoolManager, PoolConfig, POOL_CONFIGS, PoolType
from orchestration.circuit_breaker import CircuitBreaker

logger = logging.getLogger(__name__)


# ── PHASE DEFINITIONS ─────────────────────────────────────────────────────────

PHASE_POOLS: Dict[int, List[str]] = {
    1: [],                                          # Phase 1 = backtest only
    2: [],                                          # Phase 2 = Crypto Quant QA
    3: ["equities_us", "commodities"],              # Phase 3 = US live
    4: ["equities_us", "equities_emea",
        "equities_apac", "commodities", "crypto"],  # Phase 4 = global
    5: ["equities_us", "equities_emea",
        "equities_apac", "commodities",
        "crypto", "dte_overlay"],                   # Phase 5 = full
}


# ── COORDINATOR ───────────────────────────────────────────────────────────────

class Coordinator:
    """
    Top-level orchestrator for Blaque Baux.

    Manages:
      - Shared services (optimizer, IBKR, borrow feed, event bus)
      - Pool lifecycle (start, monitor, stop)
      - Health monitoring loop
      - Graceful shutdown
    """

    def __init__(
        self,
        phase:       int  = 3,
        paper_mode:  bool = True,
        pool_filter: Optional[List[str]] = None,
    ):
        self.phase       = phase
        self.paper_mode  = paper_mode
        self.pool_ids    = pool_filter or PHASE_POOLS.get(phase, [])
        self._tasks:     Dict[str, asyncio.Task] = {}
        self._pools:     Dict[str, PoolManager]  = {}
        self._running    = False

        # Shared services — initialized in start()
        self._bus        = None
        self._optimizer  = None
        self._ibkr       = None
        self._borrow     = None

        logger.info(
            f"Coordinator initialized | Phase {phase} | "
            f"{'PAPER' if paper_mode else 'LIVE'} | "
            f"Pools: {self.pool_ids}"
        )

    # ── LIFECYCLE ─────────────────────────────────────────────────────────────

    async def start(self):
        """
        Initialize all shared services and start pool tasks.
        Called once at process start.
        """
        logger.info("=" * 60)
        logger.info("BLAQUE BAUX — Starting coordinator")
        logger.info(f"Phase:   {self.phase}")
        logger.info(f"Mode:    {'PAPER TRADING' if self.paper_mode else '*** LIVE TRADING ***'}")
        logger.info(f"Pools:   {self.pool_ids}")
        logger.info("=" * 60)

        # 1. Event bus
        self._bus = make_bus(use_network=True)
        await self._bus.check_health()
        logger.info(f"Event bus: {'network (@smallclaw/coordination)' if self._bus._online else 'local SQLite fallback'}")

        # 2. Crypto Quant optimizer service
        self._optimizer = get_optimizer()
        await self._optimizer.start()
        logger.info("Crypto Quant optimizer service: online")

        # 3. IBKR connection
        from ibkr.connection import IBKRConnectionPool
        from ibkr.order_manager import IBKROrderManager
        from ibkr.borrow_feed import BorrowRateFeed

        self._ibkr_pool = IBKRConnectionPool(paper=self.paper_mode)
        await self._ibkr_pool.connect()
        self._ibkr    = IBKROrderManager(self._ibkr_pool)
        self._borrow  = BorrowRateFeed(self._ibkr_pool)
        logger.info(f"IBKR: connected ({'paper' if self.paper_mode else 'LIVE'})")

        # 4. Start pools
        self._running = True
        for pool_id in self.pool_ids:
            await self._start_pool(pool_id)

        # 5. Health monitor
        asyncio.create_task(self._health_loop(), name="health_monitor")

        # 6. Signal handlers for graceful shutdown
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(self.stop()))

        logger.info("Coordinator started — all pools running")

    async def stop(self):
        """Graceful shutdown — cancel all pool tasks cleanly."""
        logger.info("Coordinator stopping...")
        self._running = False

        # Stop all pools
        for pool_id, pool in self._pools.items():
            await pool.stop()
            logger.info(f"  Pool {pool_id}: stopped")

        # Cancel asyncio tasks
        for task in self._tasks.values():
            task.cancel()
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)

        # Disconnect services
        if self._ibkr_pool:
            await self._ibkr_pool.disconnect()
        if self._optimizer:
            await self._optimizer.stop()

        logger.info("Coordinator stopped cleanly")
        sys.exit(0)

    async def run_forever(self):
        """Block until shutdown signal."""
        await start()
        while self._running:
            await asyncio.sleep(1)

    # ── POOL MANAGEMENT ───────────────────────────────────────────────────────

    async def _start_pool(self, pool_id: str):
        if pool_id not in POOL_CONFIGS:
            logger.error(f"Unknown pool: {pool_id}")
            return

        cfg = POOL_CONFIGS[pool_id]
        from data.fetcher import load_all

        pool = PoolManager(
            config        = cfg,
            optimizer_svc = self._optimizer,
            ibkr_mgr      = self._ibkr,
            borrow_feed   = self._borrow,
            bus           = self._bus,
            data_loader   = load_all,
        )
        self._pools[pool_id] = pool

        task = asyncio.create_task(pool.start(), name=f"pool_{pool_id}")
        self._tasks[pool_id] = task
        logger.info(f"  Pool {pool_id}: started on {cfg.machine_id}")

    # ── HEALTH MONITOR ────────────────────────────────────────────────────────

    async def _health_loop(self):
        """
        Runs every 60 seconds. Checks pool health, logs diagnostics,
        handles any broadcast circuit alerts from the event bus.
        """
        while self._running:
            await asyncio.sleep(60)
            try:
                await self._check_pool_health()
                self._log_optimizer_diagnostics()
                await self._process_circuit_alerts()
            except Exception as e:
                logger.error(f"Health loop error: {e}", exc_info=True)

    async def _check_pool_health(self):
        """Check for crashed pool tasks and restart if needed."""
        for pool_id, task in list(self._tasks.items()):
            if task.done():
                exc = task.exception() if not task.cancelled() else None
                if exc:
                    logger.error(f"Pool {pool_id} crashed: {exc} — restarting")
                    await self._start_pool(pool_id)
                else:
                    logger.warning(f"Pool {pool_id} exited cleanly — not restarting")

    def _log_optimizer_diagnostics(self):
        if self._optimizer:
            diag = self._optimizer.diagnostics()
            for pid, d in diag.items():
                if d["failure_rate"] > 0.05:
                    logger.warning(
                        f"  Optimizer [{pid}]: "
                        f"{d['failure_rate']:.1%} failure rate, "
                        f"avg solve {d['last_solve_ms']:.0f}ms"
                    )

    async def _process_circuit_alerts(self):
        """Read broadcast circuit alerts from the event bus."""
        # Each pool publishes circuit state changes as broadcasts
        # The coordinator logs them centrally for operational visibility
        msg = self._bus.local.claim_message("coordinator")
        while msg:
            if msg.get("msg_type") == "circuit_alert":
                p = msg["payload"]
                logger.warning(
                    f"CIRCUIT ALERT [{p.get('pool_id')}]: "
                    f"{p.get('from_state')} → {p.get('to_state')} | "
                    f"{p.get('reason')}"
                )
            msg = self._bus.local.claim_message("coordinator")

    # ── STATUS ────────────────────────────────────────────────────────────────

    def status(self) -> Dict:
        return {
            "phase":       self.phase,
            "paper_mode":  self.paper_mode,
            "pools":       {
                pid: pool._status.value
                for pid, pool in self._pools.items()
            },
            "optimizer":   self._optimizer.diagnostics() if self._optimizer else {},
            "bus_online":  self._bus._online if self._bus else False,
        }
