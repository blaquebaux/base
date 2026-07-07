"""
blaque_baux/orchestration/pool_manager.py
──────────────────────────────────────────
Individual pool manager — one instance per trading pool.

Each pool runs as an independent asyncio coroutine with its own:
  - Data feed subscription (Polygon.io WebSocket or REST poll)
  - Signal evaluation cycle
  - Circuit breaker state
  - IBKR order channel
  - Coordination bus connection (read/write)

Pool lifecycle:
  INITIALIZING → WAITING_SESSION → ACTIVE → PAUSED → STOPPED

The pool manager owns the per-window loop:
  1. Wait for bar close (15-min / 1-hr / 2-hr depending on pool)
  2. Check circuit breaker
  3. Fetch latest signal data
  4. Score factor model
  5. Call optimizer service (Crypto Quant)
  6. Submit orders to IBKR (if circuit allows)
  7. Log to event bus
  8. Sleep until next bar

Pools run simultaneously via asyncio — no blocking between them.
The coordinator starts all pools and monitors their health.
"""

import asyncio
import logging
import sys
import os
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

from config import signal_cfg, optimizer_cfg, BAR_MINUTES, N_LONGS, N_SHORTS

# ── AdaptiveVolatilityDetector + RegimeConfig (risk_intelligence.py) ──────────
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from risk_intelligence import AdaptiveVolatilityDetector, RegimeConfig

logger = logging.getLogger(__name__)


# ── POOL DEFINITIONS ──────────────────────────────────────────────────────────

class PoolType(str, Enum):
    EQUITIES_APAC  = "equities_apac"
    EQUITIES_EMEA  = "equities_emea"
    EQUITIES_US    = "equities_us"
    COMMODITIES    = "commodities"
    CRYPTO         = "crypto"
    DTE_OVERLAY    = "dte_overlay"


class PoolStatus(str, Enum):
    INITIALIZING    = "initializing"
    WAITING_SESSION = "waiting_session"
    ACTIVE          = "active"
    PAUSED          = "paused"
    STOPPED         = "stopped"


@dataclass
class PoolConfig:
    pool_id:        str
    pool_type:      PoolType
    bar_minutes:    int              # 15 for equity, 60-120 for crypto
    n_longs:        int = N_LONGS
    n_shorts:       int = N_SHORTS
    machine_id:     str = "m4mini"  # which fleet machine runs this pool
    capital:        float = 10_000.0
    cascade_boost:  float = 0.03    # accuracy boost from prior session
    is_crypto:      bool = False
    session_start_utc: Optional[str] = None   # "HH:MM" UTC
    session_end_utc:   Optional[str] = None   # "HH:MM" UTC


# Canonical pool configurations
POOL_CONFIGS: Dict[str, PoolConfig] = {
    "equities_apac": PoolConfig(
        pool_id      = "equities_apac",
        pool_type    = PoolType.EQUITIES_APAC,
        bar_minutes  = 15,
        machine_id   = "m2studio",
        capital      = 10_000.0,
        cascade_boost = 0.03,        # US prior close → APAC open
        session_start_utc = "00:00", # Tokyo open
        session_end_utc   = "06:30", # Tokyo/HK close
    ),
    "equities_emea": PoolConfig(
        pool_id      = "equities_emea",
        pool_type    = PoolType.EQUITIES_EMEA,
        bar_minutes  = 15,
        machine_id   = "m3studio",
        capital      = 10_000.0,
        cascade_boost = 0.03,        # APAC close → EMEA open
        session_start_utc = "07:00", # Frankfurt/London open
        session_end_utc   = "15:30", # London close
    ),
    "equities_us": PoolConfig(
        pool_id      = "equities_us",
        pool_type    = PoolType.EQUITIES_US,
        bar_minutes  = 15,
        machine_id   = "m4mini",
        capital      = 10_000.0,
        cascade_boost = 0.06,        # APAC + EMEA → US (+2 hops)
        session_start_utc = "13:30", # NYSE open
        session_end_utc   = "20:00", # NYSE close
    ),
    "commodities": PoolConfig(
        pool_id      = "commodities",
        pool_type    = PoolType.COMMODITIES,
        bar_minutes  = 15,
        machine_id   = "m4mini",
        capital      = 0.0,          # funded from equity P&L
        cascade_boost = 0.0,
        # No session window — 23hr continuous
    ),
    "crypto": PoolConfig(
        pool_id      = "crypto",
        pool_type    = PoolType.CRYPTO,
        bar_minutes  = 60,           # 1-hour cadence (Phase 4)
        machine_id   = "m2studio",
        capital      = 0.0,          # funded from equity P&L
        cascade_boost = 0.0,
        is_crypto    = True,
        # 24/7 — no session window
    ),
    "dte_overlay": PoolConfig(
        pool_id      = "dte_overlay",
        pool_type    = PoolType.DTE_OVERLAY,
        bar_minutes  = 0,            # event-driven, not bar-driven
        machine_id   = "m4mini",
        capital      = 0.0,          # 2.5% of daily equity P&L
        cascade_boost = 0.06,        # uses US signal
        session_start_utc = "15:00", # enter after 11am ET (16:00 UTC)
        session_end_utc   = "19:30", # exit before close
    ),
}


# ── POOL MANAGER ──────────────────────────────────────────────────────────────

class PoolManager:
    """
    Manages one trading pool's full lifecycle.
    Instantiated by the coordinator; runs as an asyncio Task.
    """

    def __init__(
        self,
        config:           PoolConfig,
        optimizer_svc,    # OptimizerService singleton
        ibkr_mgr,         # IBKROrderManager
        borrow_feed,      # BorrowRateFeed
        bus,              # NetworkBus (event bus)
        data_loader,      # data.fetcher functions
    ):
        self.config        = config
        self.optimizer     = optimizer_svc
        self.ibkr          = ibkr_mgr
        self.borrow_feed   = borrow_feed
        self.bus           = bus
        self.data_loader   = data_loader
        self.pool_id       = config.pool_id

        # Runtime state
        self._status       = PoolStatus.INITIALIZING
        self._circuit      = None      # CircuitBreaker — initialized in start()
        self._window_count = 0
        self._daily_pnl    = 0.0
        self._running      = False

        # Rolling data buffers — maintained in memory, refreshed each session
        self._close_prices: Optional[pd.DataFrame] = None
        self._equity_returns: Optional[pd.DataFrame] = None
        self._signal_returns: Optional[pd.DataFrame] = None

        # ── Adaptive volatility regime detector ───────────────────────────────
        # Replaces static session detection + drives bar cadence.
        # RegimeConfig.block_size_minutes overrides config.bar_minutes each bar.
        # RegimeConfig.signal_threshold feeds into HybridSignalEngine z_threshold.
        # RegimeConfig.kalman_gain is forwarded to the signal engine on change.
        self._vol_detector: AdaptiveVolatilityDetector = AdaptiveVolatilityDetector()
        self._regime_cfg:   Optional[RegimeConfig]     = None   # set on first bar
        # Live bar minutes — updated each window when regime changes
        self._current_bar_minutes: int = config.bar_minutes

    # ── LIFECYCLE ─────────────────────────────────────────────────────────────

    async def start(self):
        """Initialize and start the pool loop."""
        from orchestration.circuit_breaker import CircuitBreaker
        from orchestration.event_bus import AgentRecord

        self._circuit = CircuitBreaker(
            pool_id = self.pool_id,
            bus     = self.bus,
        )
        self._running = True

        # Register with coordination bus
        await self.bus.register_agent(AgentRecord(
            agent_id        = self.pool_id,
            machine_id      = self.config.machine_id,
            capability_tier = 1.0,
            status          = "idle",
            current_task    = None,
            judgment_policy = {
                "pool_type":     self.config.pool_type.value,
                "bar_minutes":   self.config.bar_minutes,
                "n_longs":       self.config.n_longs,
                "n_shorts":      self.config.n_shorts,
                "cascade_boost": self.config.cascade_boost,
            },
        ))

        logger.info(f"[{self.pool_id}] Pool started on {self.config.machine_id}")
        self._status = PoolStatus.WAITING_SESSION
        await self._run_loop()

    async def stop(self):
        self._running = False
        self._status = PoolStatus.STOPPED
        logger.info(f"[{self.pool_id}] Pool stopped")

    # ── MAIN LOOP ─────────────────────────────────────────────────────────────

    async def _run_loop(self):
        """
        The core per-window loop.
        Runs continuously; sessions are gated by _in_session().
        """
        while self._running:
            if not self._in_session():
                self._status = PoolStatus.WAITING_SESSION
                await asyncio.sleep(60)     # check every minute
                continue

            self._status = PoolStatus.ACTIVE
            await self.bus.heartbeat(self.pool_id, "working",
                                     f"window_{self._window_count}")
            try:
                await self._execute_window()
            except Exception as e:
                logger.error(f"[{self.pool_id}] Window error: {e}", exc_info=True)

            self._window_count += 1

            # Wait for next bar close — cadence driven by current vol regime
            await asyncio.sleep(self._current_bar_minutes * 60)

    # ── WINDOW EXECUTION ──────────────────────────────────────────────────────

    async def _execute_window(self):
        """
        One 15-minute (or 1-hr / 2-hr) window execution.
        Steps 1-8 of the per-window loop from the project brief.
        """
        # 1. Ensure data is fresh (refresh at session start)
        if self._close_prices is None:
            await self._refresh_data()
            if self._close_prices is None:
                logger.warning(f"[{self.pool_id}] No data — skipping window")
                return

        # 2. Live borrow costs (pre-circuit-breaker filter)
        borrow_costs = await self.borrow_feed.get_current_rates(
            self._close_prices.columns.tolist()
        )

        # 3. Cascade signal
        from signal.cascade import compute_cascade_signal
        cascade_signal = compute_cascade_signal(self._signal_returns)
        cascade_t = float(cascade_signal.iloc[-1]) if len(cascade_signal) else 0.0

        # 4. VIX proxy + regime detection
        vix = self._estimate_vix()

        # Feed latest SPY bar return into the adaptive vol detector.
        # This replaces static session detection:
        #   • RegimeConfig.block_size_minutes → _current_bar_minutes (bar cadence)
        #   • RegimeConfig.signal_threshold   → HybridSignalEngine z_threshold
        #   • RegimeConfig.kalman_gain        → signal engine Kalman process noise
        spy_ret_15m = None
        if (self._signal_returns is not None
                and "SPY" in self._signal_returns.columns
                and len(self._signal_returns) > 0):
            spy_ret_15m = float(self._signal_returns["SPY"].iloc[-1])

        if spy_ret_15m is not None:
            new_regime_cfg = self._vol_detector.update(
                return_1m  = spy_ret_15m,   # best proxy available at 15-min cadence
                return_15m = spy_ret_15m,
            )
            regime_changed = (
                self._regime_cfg is None
                or new_regime_cfg.regime != self._regime_cfg.regime
            )
            self._regime_cfg = new_regime_cfg

            # Update bar cadence from regime
            self._current_bar_minutes = new_regime_cfg.block_size_minutes

            # On regime change: forward new signal_threshold + kalman_gain to the
            # HybridSignalEngine/HybridSignalBridge inside the optimizer service.
            if regime_changed:
                logger.info(
                    f"[{self.pool_id}] Vol regime → {new_regime_cfg.regime.value} | "
                    f"bar={new_regime_cfg.block_size_minutes}m | "
                    f"z_threshold={new_regime_cfg.signal_threshold} | "
                    f"kalman_gain={new_regime_cfg.kalman_gain}"
                )
                self.optimizer.reconfigure_signal_engine(
                    pool_id       = self.pool_id,
                    z_threshold   = new_regime_cfg.signal_threshold,
                    kalman_gain   = new_regime_cfg.kalman_gain,
                )

        # 5. Circuit breaker evaluation
        # Use dummy accuracy_hit=True if we haven't accumulated enough windows
        if self._window_count < 20:
            accuracy_hit = True
            portfolio_return_prev = 0.0
        else:
            accuracy_hit = self._last_accuracy_hit
            portfolio_return_prev = self._last_portfolio_return

        circuit_status = self._circuit.evaluate(
            accuracy_hit      = accuracy_hit,
            portfolio_return  = portfolio_return_prev,
            vix               = vix,
            cascade_strength  = cascade_t,
            is_crypto         = self.config.is_crypto,
        )

        # 6. Gate execution on circuit state
        if not self._circuit.can_trade(circuit_status):
            logger.info(f"[{self.pool_id}] Window skipped: {circuit_status.reason}")
            return

        # 7. Factor scoring via HybridSignalEngine (Rust hot path / Python fallback).
        # Passing returns_t replaces the static compute_factor_scores() call:
        #   optimizer.optimize() internally calls HybridSignalBridge.update_bar(),
        #   which runs the 3-layer Bayesian engine (Kalman → NIG → James-Stein)
        #   and produces alpha + active_mask → factor_scores.
        returns_t = self._equity_returns.iloc[-1]   # latest bar: Series[ticker → return]

        # 8. Optimizer call (Crypto Quant engine)
        opt_result = await self.optimizer.optimize(
            pool_id         = self.pool_id,
            factor_scores   = None,         # derived from returns_t by signal engine
            returns_t       = returns_t,    # ← HybridSignalEngine.update_bar() path
            returns_history = self._equity_returns.iloc[-480:],  # 5-day train window
            n_longs         = self.config.n_longs,
            n_shorts        = self.config.n_shorts,
            borrow_costs    = borrow_costs,
            confidence      = 0.95,
            # Run frontier at end of day only
            run_frontier    = self._is_end_of_session(),
        )

        # Scale weights by circuit breaker position scalar
        scaled_weights = {
            t: w * circuit_status.position_scalar
            for t, w in opt_result.weights.items()
        }

        # 9. Submit orders to IBKR
        if scaled_weights and opt_result.solve_status != "fallback":
            fill_report = await self.ibkr.submit_rebalance(
                pool_id  = self.pool_id,
                weights  = scaled_weights,
                capital  = self.config.capital,
            )
            realized_return = fill_report.get("realized_return", 0.0)
        else:
            realized_return = 0.0
            fill_report     = {}

        # 10. Track accuracy (will be used next window)
        # Accuracy = did top quartile beat bottom quartile in realized fills?
        self._last_accuracy_hit      = opt_result.solve_status == "optimal"
        self._last_portfolio_return  = realized_return

        # 11. Log to event bus
        from orchestration.event_bus import Memory
        self.bus.log_window(
            self.pool_id,
            factor_accuracy  = 1.0 if self._last_accuracy_hit else 0.0,
            portfolio_return = realized_return,
            qp_status        = opt_result.solve_status,
            cascade_strength = cascade_t,
            n_long           = opt_result.n_long,
            n_short          = opt_result.n_short,
            circuit_state    = circuit_status.state.value,
        )

        # Log 0DTE strategy selection at end of session
        if self._is_end_of_session() and self.pool_id == "equities_us":
            logger.info(
                f"[{self.pool_id}] 0DTE strategy today: "
                f"{circuit_status.dte_strategy.value} "
                f"(VIX={vix:.1f})"
            )

        logger.debug(
            f"[{self.pool_id}] Window {self._window_count} | "
            f"circuit={circuit_status.state.value} | "
            f"solve={opt_result.solve_status} | "
            f"E[r]={opt_result.expected_return*100:.3f}% | "
            f"{opt_result.n_long}L/{opt_result.n_short}S | "
            f"{opt_result.solve_time_ms:.0f}ms"
        )

    # ── HELPERS ───────────────────────────────────────────────────────────────

    def _in_session(self) -> bool:
        """Check if this pool should be trading right now."""
        if self.config.pool_type in (PoolType.COMMODITIES, PoolType.CRYPTO):
            return True     # 24/7 or near-24hr
        if not self.config.session_start_utc or not self.config.session_end_utc:
            return True

        now_utc = datetime.now(timezone.utc).strftime("%H:%M")
        return (self.config.session_start_utc <= now_utc
                <= self.config.session_end_utc)

    def _is_end_of_session(self) -> bool:
        if not self.config.session_end_utc:
            return False
        now_utc = datetime.now(timezone.utc).strftime("%H:%M")
        # Within 30 minutes of session end
        from datetime import timedelta
        end = datetime.strptime(self.config.session_end_utc, "%H:%M")
        now = datetime.strptime(now_utc, "%H:%M")
        return (end - now).total_seconds() <= 1800

    def _estimate_vix(self) -> Optional[float]:
        """Estimate VIX proxy from signal data (realized vol of SPY returns)."""
        if self._signal_returns is None or "SPY" not in self._signal_returns.columns:
            return None
        spy_ret = self._signal_returns["SPY"].dropna()
        if len(spy_ret) < 26:
            return None
        # Annualize 15-min vol as VIX proxy
        daily_vol = float(spy_ret.tail(26).std() * (26 ** 0.5))
        ann_vol   = daily_vol * (252 ** 0.5)
        return ann_vol * 100   # convert to VIX scale

    async def _refresh_data(self):
        """Reload data for current session. Called at session open."""
        logger.info(f"[{self.pool_id}] Refreshing data...")
        try:
            loop = asyncio.get_running_loop()
            from data.fetcher import load_all
            result = await loop.run_in_executor(
                None, lambda: load_all(force_refresh=False)
            )
            self._close_prices, self._equity_returns, self._signal_returns = result
            logger.info(f"[{self.pool_id}] Data refreshed: "
                        f"{len(self._close_prices)} bars × "
                        f"{len(self._close_prices.columns)} tickers")
        except Exception as e:
            logger.error(f"[{self.pool_id}] Data refresh failed: {e}")

    # Internal state for accuracy tracking
    _last_accuracy_hit: bool = True
    _last_portfolio_return: float = 0.0
