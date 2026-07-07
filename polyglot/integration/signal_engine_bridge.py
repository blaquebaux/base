"""
blaque_baux/integration/signal_engine_bridge.py
─────────────────────────────────────────────────
Drop-in bridge: Rust hot path ↔ Python orchestrator.

Replaces HybridSignalEngine from signal_engine.py with the Rust
implementation for layers 1-2b (Kalman, NIG, Welford, James-Stein),
while keeping CompressedADVI in Python/numpy (session-end, not latency-critical).

Usage:
    # Swap one import line in optimizer_service.py:
    # OLD: from signal_engine import HybridSignalEngine
    # NEW: from integration.signal_engine_bridge import HybridSignalBridge as HybridSignalEngine

    engine = HybridSignalBridge(
        n_assets=50,
        tickers=["AAPL", "MSFT", ...],
        z_threshold=1.5,
    )
    alpha, unc, mask = engine.update_bar(returns_series)
    # Identical interface — optimizer_service.py doesn't change.

Fallback: If the Rust library isn't compiled, falls back to pure Python
HybridSignalEngine transparently (with a warning log).
"""

import logging
import time
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# ── Try importing the Rust engine ────────────────────────────────────────────
try:
    from signal_engine_rs import HybridEngine as RustHybridEngine
    from signal_engine_rs import FastMvoSolver as RustFastMvo
    RUST_AVAILABLE = True
    logger.info("signal_engine_rs (Rust) loaded — hot path active")
except ImportError:
    RUST_AVAILABLE = False
    logger.warning(
        "signal_engine_rs not found — falling back to Python. "
        "Build with: cd signal_engine_rs && maturin develop --release"
    )

# ── Python signal_engine (fallback path + session-end ADVI) ──────────────────
try:
    from signal_engine import CompressedADVI, HybridSignalEngine
    PYTHON_ENGINE_AVAILABLE = True
except ImportError:
    PYTHON_ENGINE_AVAILABLE = False
    HybridSignalEngine = None  # only needed when RUST_AVAILABLE is False

    class CompressedADVI:  # type: ignore[no-redef]
        """No-op stub — session-end ADVI skipped when signal_engine.py is absent."""
        def __init__(self, *args, **kwargs):
            pass
        def push(self, *args, **kwargs):
            pass
        def fit(self, *args, **kwargs):
            return 0.0
        @property
        def corrections(self):
            return None


class HybridSignalBridge:
    """
    Bridge that uses Rust for per-bar hot path and Python for session-end ADVI.

    Interface-compatible with HybridSignalEngine from signal_engine.py.
    optimizer_service.py calls the same methods — only the import changes.
    """

    def __init__(
        self,
        n_assets: int,
        tickers: List[str],
        z_threshold: float = 1.5,
        advi_features: int = 5,
        decay: float = 0.95,
    ):
        self.n_assets = n_assets
        self.tickers = tickers
        self.z_threshold = z_threshold

        if RUST_AVAILABLE:
            # Hot path in Rust
            self._rust_engine = RustHybridEngine(
                tickers=tickers,
                z_threshold=z_threshold,
                decay=decay,
            )
            self._mode = "rust"
        else:
            # Fallback: pure Python (identical behavior, slower)
            if not PYTHON_ENGINE_AVAILABLE:
                raise RuntimeError(
                    "signal_engine_rs (Rust) is not compiled and signal_engine.py "
                    "is not importable. Run: cd signal_engine_rs && maturin develop --release"
                )
            self._python_engine = HybridSignalEngine(
                n_assets=n_assets,
                tickers=tickers,
                z_threshold=z_threshold,
                advi_features=advi_features,
                decay=decay,
            )
            self._mode = "python"

        # ADVI always runs in Python (session-end, not latency-critical)
        self._advi = CompressedADVI(n_assets, advi_features)

        # ADVI feature buffer (accumulates during session)
        self._advi_buffer_features: List[np.ndarray] = []
        self._advi_buffer_targets: List[float] = []

        # Performance tracking
        self._bar_times_ms: List[float] = []

    @property
    def mode(self) -> str:
        return self._mode

    # ── PER-BAR UPDATE (hot path) ────────────────────────────────────────────

    def update_bar(
        self,
        returns_t: pd.Series,
        push_advi_features: bool = True,
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """
        Process one 15-minute bar across all assets.

        Returns:
            (alpha, uncertainty, active_mask) — numpy arrays [n_assets]

        Identical interface to HybridSignalEngine.update_bar().
        """
        if self._mode == "rust":
            return self._update_bar_rust(returns_t, push_advi_features)
        else:
            return self._python_engine.update_bar(returns_t, push_advi_features)

    def _update_bar_rust(
        self,
        returns_t: pd.Series,
        push_advi_features: bool,
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Rust hot path + Python ADVI buffer accumulation."""
        t0 = time.perf_counter()

        # Build returns array in ticker order
        returns_arr = np.array(
            [returns_t.get(t, 0.0) for t in self.tickers],
            dtype=np.float32,
        )

        # Rust: Kalman + NIG + Welford + James-Stein + combine
        alpha, uncertainty, active_mask = self._rust_engine.update_bar(returns_arr)

        # Python: accumulate ADVI features (not latency-critical)
        if push_advi_features:
            # Simple feature vector for ADVI buffer
            feat_vec = np.array([
                float(np.mean(returns_arr)),
                float(np.std(returns_arr)),
                float(np.mean(alpha)),
                float(np.std(alpha)),
                float(np.mean(uncertainty)),
            ], dtype=np.float32)
            self._advi.push(feat_vec, float(np.mean(returns_arr)))

        elapsed_ms = (time.perf_counter() - t0) * 1000
        self._bar_times_ms.append(elapsed_ms)

        return alpha, uncertainty, active_mask

    # ── SESSION-END ADVI CORRECTION ──────────────────────────────────────────

    def run_session_correction(self) -> Dict:
        """
        Run CompressedADVI on the session's buffered observations.
        Call once per session (end-of-day or end of each regional session).

        ADVI runs in Python/numpy — not latency-critical (~15ms).
        Results are injected back into the Rust engine.
        """
        elapsed = self._advi.fit(n_iter=100)
        corrections = self._advi.corrections

        if self._mode == "rust" and corrections is not None:
            # Inject ADVI corrections into Rust engine
            self._rust_engine.set_advi_corrections(
                corrections.astype(np.float32)
            )
            self._rust_engine.reset_kalman_from_advi()
        else:
            # Python path handles this internally
            for i, ticker in enumerate(self.tickers):
                if i < len(corrections):
                    self._python_engine.states[ticker].kalman.reset(
                        alpha=float(corrections[i]),
                        uncertainty=0.01,
                    )

        logger.info(
            f"Session ADVI correction [{self._mode}]: {elapsed:.1f}ms | "
            f"mean_correction={float(corrections.mean()):.6f}"
        )
        return {
            "elapsed_ms": elapsed,
            "mean_correction": float(corrections.mean()),
            "std_correction": float(corrections.std()),
            "mode": self._mode,
        }

    # ── DIAGNOSTICS ──────────────────────────────────────────────────────────

    def diagnostics(self) -> Dict:
        base = {
            "mode": self._mode,
            "n_assets": self.n_assets,
            "z_threshold": self.z_threshold,
        }

        if self._mode == "rust":
            rust_diag = self._rust_engine.diagnostics()
            base.update(rust_diag)
        else:
            base.update(self._python_engine.diagnostics())

        if self._bar_times_ms:
            base["bridge_avg_bar_ms"] = float(np.mean(self._bar_times_ms[-100:]))
            base["bridge_p95_bar_ms"] = float(
                np.percentile(self._bar_times_ms[-100:], 95)
            )

        return base


# ══════════════════════════════════════════════════════════════════════════════
# FAST MVO BRIDGE
# ══════════════════════════════════════════════════════════════════════════════

class FastMvoBridge:
    """
    Bridge for RealTimePortfolioOptimizer → Rust FastMvoSolver.
    Replaces signal_engine.RealTimePortfolioOptimizer for the SNR path.
    """

    def __init__(
        self,
        long_ratio: float = 0.50,
        max_position_wt: float = 0.08,
        risk_aversion: float = 1.0,
    ):
        if RUST_AVAILABLE:
            self._solver = RustFastMvo(
                long_ratio=long_ratio,
                max_position_wt=max_position_wt,
                risk_aversion=risk_aversion,
            )
            self._mode = "rust"
        else:
            from signal_engine import RealTimePortfolioOptimizer
            self._solver = RealTimePortfolioOptimizer(
                long_ratio=long_ratio,
                max_position_wt=max_position_wt,
                risk_aversion=risk_aversion,
            )
            self._mode = "python"

    def signal_to_noise_weights(
        self,
        alphas: np.ndarray,
        uncertainties: np.ndarray,
        long_mask: np.ndarray,
        short_mask: np.ndarray,
    ) -> np.ndarray:
        if self._mode == "rust":
            return self._solver.snr_weights(
                alphas.astype(np.float64),
                uncertainties.astype(np.float64),
                long_mask.astype(bool),
                short_mask.astype(bool),
            )
        else:
            return self._solver.signal_to_noise_weights(
                alphas, uncertainties, long_mask, short_mask,
            )
