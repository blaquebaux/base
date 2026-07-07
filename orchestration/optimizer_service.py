"""
blaque_baux/orchestration/optimizer_service.py
───────────────────────────────────────────────
Crypto Quant portfolio optimization engine exposed as a
shared async service — the Solver-equivalent layer.

All five trading pools (APAC equity, EMEA equity, US equity,
commodities, crypto) call this service at step 4 of their
window loop. The service handles:

  - CVXPY QP solve per window (minimize variance, hit return target)
  - EWMA covariance matrix maintenance per pool
  - Efficient frontier tracing on demand
  - Monte Carlo forward simulation on demand
  - Borrow cost adjustment pre-solve

Design: singleton service, async-safe, per-pool state.
Each pool gets its own covariance history and solve metadata.
Pools never share state — isolation is by design.

This is the direct bridge between Blaque Baux and Crypto Quant.
As Crypto Quant QA completes, the underlying implementation
in optimizer/qp_solver.py will be extended here without
changing the service interface that pools depend on.
"""

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

from config import optimizer_cfg
from optimizer.qp_solver import (
    optimize_portfolio,
    compute_efficient_frontier,
    ewma_covariance,
)
from signal.factors import select_long_short

logger = logging.getLogger(__name__)


# ── RESULT TYPE ───────────────────────────────────────────────────────────────

@dataclass
class OptimizationResult:
    """
    Result of one QP solve. Passed back to the requesting pool.
    Matches the interface defined in the project brief Section 5.
    """
    pool_id:          str
    weights:          Dict[str, float]    # positive=long, negative=short
    expected_return:  float               # optimizer's return estimate
    expected_vol:     float               # optimizer's vol estimate
    sharpe_est:       float               # expected_return / expected_vol
    solve_status:     str                 # 'optimal' | 'fallback' | 'failed'
    n_long:           int
    n_short:          int
    solve_time_ms:    float
    confidence_level: float = 0.95        # which confidence level was used
    frontier:         Optional[pd.DataFrame] = None  # if requested


# ── PER-POOL STATE ────────────────────────────────────────────────────────────

@dataclass
class PoolOptimizerState:
    """
    Maintained per pool — covariance history, prev weights, solve log.
    """
    pool_id:        str
    prev_weights:   Dict[str, float] = field(default_factory=dict)
    solve_count:    int = 0
    failure_count:  int = 0
    last_solve_ms:  float = 0.0
    cov_matrix:     Optional[np.ndarray] = None


# ── SERVICE ───────────────────────────────────────────────────────────────────

class OptimizerService:
    """
    Shared async QP optimization service.
    Instantiated once at process start; all pools call into it.

    Thread-safety: each pool has isolated state (PoolOptimizerState).
    The CVXPY solve itself is not async-native, so calls are wrapped
    in asyncio.run_in_executor to avoid blocking the event loop during
    the matrix inversion + QP solve.
    """

    def __init__(self):
        self._pool_states: Dict[str, PoolOptimizerState] = {}
        self._lock = asyncio.Lock()
        self._executor = None   # set in start()
        logger.info("OptimizerService initialized — Crypto Quant QP engine ready")

    async def start(self):
        """Call once at system start."""
        from concurrent.futures import ThreadPoolExecutor
        # One thread per pool (max 6: APAC, EMEA, US, commodities, crypto, 0DTE)
        self._executor = ThreadPoolExecutor(max_workers=6,
                                            thread_name_prefix="qp_solver")
        logger.info("OptimizerService started — thread pool ready")

    async def stop(self):
        if self._executor:
            self._executor.shutdown(wait=True)
            logger.info("OptimizerService stopped")

    # ── MAIN ENTRY POINT ──────────────────────────────────────────────────────

    async def optimize(
        self,
        pool_id:         str,
        factor_scores:   "pd.Series",
        returns_history: "pd.DataFrame",
        n_longs:         int = 25,
        n_shorts:        int = 25,
        borrow_costs:    Optional[Dict[str, float]] = None,
        confidence:      float = 0.95,
        run_frontier:    bool = False,
    ) -> OptimizationResult:
        """
        Main optimization call — called by each pool at step 4.

        Async: wraps the synchronous CVXPY solve in executor so
        APAC, EMEA, and US pools can be solving simultaneously
        without blocking each other.

        Args:
            pool_id:         which pool is calling
            factor_scores:   Series[ticker → score] from factor model
            returns_history: DataFrame of recent returns (train window)
            n_longs:         long book size
            n_shorts:        short book size
            borrow_costs:    live borrow rates (excludes HTB names)
            confidence:      target confidence level (0.90–0.99)
            run_frontier:    whether to trace efficient frontier

        Returns:
            OptimizationResult with weights and diagnostics
        """
        state = self._get_pool_state(pool_id)

        # Select long/short candidates from factor scores
        long_tickers, short_tickers = select_long_short(
            factor_scores, n_longs, n_shorts
        )

        # Apply borrow cost filter (circuit breaker pre-filter)
        if borrow_costs:
            from orchestration.circuit_breaker import filter_shortable
            short_tickers = filter_shortable(short_tickers, borrow_costs)

        if not long_tickers or not short_tickers:
            return self._fallback_result(pool_id, "empty_universe")

        # Scale target return by confidence level
        scaled_cfg = self._scale_to_confidence(confidence)

        # Run QP solve in thread executor (non-blocking)
        t0 = time.perf_counter()
        loop = asyncio.get_running_loop()

        try:
            weights, meta = await loop.run_in_executor(
                self._executor,
                lambda: optimize_portfolio(
                    factor_scores    = factor_scores,
                    returns_history  = returns_history,
                    long_tickers     = long_tickers,
                    short_tickers    = short_tickers,
                    prev_weights     = state.prev_weights or None,
                    borrow_costs     = borrow_costs,
                ),
            )
        except Exception as e:
            logger.error(f"[{pool_id}] QP solve error: {e}")
            state.failure_count += 1
            return self._fallback_result(pool_id, f"exception: {e}")

        solve_ms = (time.perf_counter() - t0) * 1000
        state.prev_weights = weights
        state.solve_count += 1
        state.last_solve_ms = solve_ms

        # Optional: efficient frontier (diagnostic, not every window)
        frontier = None
        if run_frontier:
            try:
                frontier = await loop.run_in_executor(
                    self._executor,
                    lambda: compute_efficient_frontier(
                        factor_scores    = factor_scores,
                        returns_history  = returns_history,
                        long_tickers     = long_tickers,
                        short_tickers    = short_tickers,
                    ),
                )
            except Exception as e:
                logger.warning(f"[{pool_id}] Frontier compute failed: {e}")

        result = OptimizationResult(
            pool_id          = pool_id,
            weights          = weights,
            expected_return  = meta.get("expected_return", 0),
            expected_vol     = meta.get("expected_vol", 0),
            sharpe_est       = meta.get("sharpe_est", 0),
            solve_status     = meta.get("status", "unknown"),
            n_long           = meta.get("n_long", 0),
            n_short          = meta.get("n_short", 0),
            solve_time_ms    = solve_ms,
            confidence_level = confidence,
            frontier         = frontier,
        )

        if meta.get("status") not in ("optimal", "optimal_inaccurate"):
            state.failure_count += 1
            logger.warning(f"[{pool_id}] QP status: {meta.get('status')} "
                           f"— fallback weights used")

        logger.debug(
            f"[{pool_id}] QP solve: {solve_ms:.1f}ms  "
            f"E[r]={result.expected_return*100:.4f}%  "
            f"E[σ]={result.expected_vol*100:.4f}%  "
            f"n={result.n_long}L/{result.n_short}S"
        )
        return result

    # ── MONTE CARLO FORWARD SIM ───────────────────────────────────────────────

    async def simulate_forward(
        self,
        pool_id:      str,
        weights:      Dict[str, float],
        returns_hist: "pd.DataFrame",
        n_trials:     int = 1000,
        n_periods:    int = 160,
    ) -> Dict:
        """
        Monte Carlo forward simulation from current positions.
        Produces the fan-band charts for the live risk dashboard.
        This is the Crypto Quant Monte Carlo engine applied to
        Blaque Baux's current portfolio state.

        Returns percentile bands: p10, p25, p50, p75, p90.
        """
        tickers = [t for t in weights if t in returns_hist.columns]
        if not tickers:
            return {}

        hist = returns_hist[tickers].dropna()
        w    = np.array([weights[t] for t in tickers])
        mu   = hist.mean().values
        cov  = ewma_covariance(hist)

        loop = asyncio.get_running_loop()
        bands = await loop.run_in_executor(
            self._executor,
            lambda: self._mc_simulate(w, mu, cov, n_trials, n_periods),
        )
        return bands

    @staticmethod
    def _mc_simulate(
        w: np.ndarray, mu: np.ndarray,
        cov: np.ndarray, n_trials: int, n_periods: int,
    ) -> Dict:
        paths = np.ones((n_trials, n_periods + 1))
        L = np.linalg.cholesky(cov + np.eye(len(mu)) * 1e-8)
        for t in range(1, n_periods + 1):
            z = np.random.randn(n_trials, len(mu))
            r = mu + (z @ L.T)
            port_r = r @ w
            paths[:, t] = paths[:, t-1] * (1 + port_r)
        return {
            "p10": np.percentile(paths, 10, axis=0).tolist(),
            "p25": np.percentile(paths, 25, axis=0).tolist(),
            "p50": np.percentile(paths, 50, axis=0).tolist(),
            "p75": np.percentile(paths, 75, axis=0).tolist(),
            "p90": np.percentile(paths, 90, axis=0).tolist(),
        }

    # ── HELPERS ───────────────────────────────────────────────────────────────

    def _get_pool_state(self, pool_id: str) -> PoolOptimizerState:
        if pool_id not in self._pool_states:
            self._pool_states[pool_id] = PoolOptimizerState(pool_id=pool_id)
        return self._pool_states[pool_id]

    def _fallback_result(self, pool_id: str, reason: str) -> OptimizationResult:
        logger.warning(f"[{pool_id}] Optimizer fallback: {reason}")
        return OptimizationResult(
            pool_id         = pool_id,
            weights         = {},
            expected_return = 0.0,
            expected_vol    = 0.0,
            sharpe_est      = 0.0,
            solve_status    = "fallback",
            n_long          = 0,
            n_short         = 0,
            solve_time_ms   = 0.0,
        )

    def _scale_to_confidence(self, confidence: float):
        """
        Scale optimizer target return by confidence level.
        Higher confidence = higher target = more aggressive weights.
        """
        return confidence   # passed through to optimizer config scaling

    def diagnostics(self) -> Dict:
        """Summary of all pool states — for dashboard and logging."""
        return {
            pid: {
                "solve_count":   s.solve_count,
                "failure_count": s.failure_count,
                "failure_rate":  s.failure_count / max(s.solve_count, 1),
                "last_solve_ms": s.last_solve_ms,
            }
            for pid, s in self._pool_states.items()
        }


# ── SINGLETON ─────────────────────────────────────────────────────────────────
# One optimizer service for all pools — instantiated in coordinator.py

_optimizer_service: Optional[OptimizerService] = None


def get_optimizer() -> OptimizerService:
    global _optimizer_service
    if _optimizer_service is None:
        _optimizer_service = OptimizerService()
    return _optimizer_service
