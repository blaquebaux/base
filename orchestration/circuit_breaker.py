"""
blaque_baux/orchestration/circuit_breaker.py
─────────────────────────────────────────────
Always-on risk circuit breaker layer.

Every pool's window loop passes through the circuit breaker before
executing. The breaker evaluates rolling accuracy, VIX level, cascade
regime detection, and borrow cost spikes to decide whether to:

  NORMAL:   proceed with full position sizing
  REDUCED:  proceed with half position sizing
  PAUSED:   skip this window, log reason, alert coordination bus
  HALTED:   stop pool completely, require manual reset

The circuit breaker also manages the 0DTE strategy selector —
when VIX crosses 28, straddles become iron condors become credit
spreads, per the risk framework.

Rules are stored in the coordination bus with Bayesian trust scores.
New rules can be proposed by any pool and earn trust through outcomes.
"""

import logging
import sys
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# ── RealTimeRiskManager (risk_intelligence.py) ────────────────────────────────
# snapshot() replaces manual per-bar VaR calculation:
#   • risk_multiplier feeds into position_scalar  (scales down on elevated risk)
#   • RNIV > 0.30      triggers REDUCED state     (model uncertainty gate)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from risk_intelligence import RealTimeRiskManager, RiskSnapshot


# ── STATE ─────────────────────────────────────────────────────────────────────

class CircuitState(str, Enum):
    NORMAL  = "normal"    # full position sizing
    REDUCED = "reduced"   # 50% position sizing
    PAUSED  = "paused"    # skip window, hold positions
    HALTED  = "halted"    # stop pool, require manual reset


class DTEStrategy(str, Enum):
    STRADDLE    = "straddle"     # VIX < 20
    IRON_CONDOR = "iron_condor"  # VIX 20–28
    CREDIT_SPREAD = "credit_spread"  # VIX 28–35
    SKIP        = "skip"         # VIX > 35 or cascade regime


@dataclass
class CircuitStatus:
    state:           CircuitState
    dte_strategy:    DTEStrategy
    position_scalar: float           # circuit scalar × risk_multiplier combined
    reason:          str
    triggered_by:    str             # which rule triggered the state
    vix_level:       Optional[float]
    accuracy_20w:    Optional[float]
    cascade_active:  bool
    rniv:            float = 0.0     # Risk Not In VaR (from RealTimeRiskManager)
    risk_multiplier: float = 1.0     # position size multiplier from risk manager


# ── CONFIGURATION ─────────────────────────────────────────────────────────────

@dataclass
class CircuitConfig:
    # Accuracy gates
    accuracy_floor_reduced: float = 0.52   # below this → REDUCED
    accuracy_floor_paused:  float = 0.50   # below this → PAUSED
    accuracy_window:        int   = 20     # rolling window for accuracy check

    # VIX gates (0DTE strategy selection)
    vix_straddle_max:    float = 20.0
    vix_condor_max:      float = 28.0
    vix_spread_max:      float = 35.0

    # Drawdown gates
    drawdown_reduced:    float = 0.08   # 8% drawdown → REDUCED
    drawdown_paused:     float = 0.12   # 12% drawdown → PAUSED
    drawdown_halted:     float = 0.20   # 20% drawdown → HALTED

    # Crypto cascade detection
    cascade_vol_mult:    float = 3.0    # vol spike this many × normal → cascade regime
    cascade_window:      int   = 4      # windows to measure spike over

    # Borrow cost limit (annualized)
    borrow_cost_max:     float = 0.03   # 3% annualized → exclude from short universe


DEFAULT_CONFIG = CircuitConfig()


# ── CIRCUIT BREAKER ───────────────────────────────────────────────────────────

class CircuitBreaker:
    """
    Evaluates current market and pool conditions each window
    and returns a CircuitStatus that governs execution decisions.

    Stateful: tracks rolling accuracy, drawdown path, and
    vix history across windows for each pool independently.
    """

    def __init__(
        self,
        pool_id:    str,
        config:     CircuitConfig = DEFAULT_CONFIG,
        bus=None,
    ):
        self.pool_id       = pool_id
        self.config        = config
        self.bus           = bus
        self._state        = CircuitState.NORMAL
        self._accuracy_log: List[float] = []
        self._return_log:   List[float] = []
        self._vix_history:  List[float] = []
        self._peak_value:   float = 1.0
        self._current_value: float = 1.0
        self._halted_at:    Optional[datetime] = None
        self._consecutive_pauses: int = 0

        # RealTimeRiskManager: replaces manual VaR calc.
        # Cornish-Fisher VaR + RNIV dispersion + risk_multiplier per bar.
        self._risk_manager = RealTimeRiskManager(
            lookback    = 252,
            var_limit   = 0.03,   # 3% VaR → reduce 20%
            cvar_limit  = 0.05,   # 5% CVaR → cut 50%
            rniv_limit  = 0.30,   # 30% RNIV → REDUCED state + reduce 30%
        )

    # ── PUBLIC API ─────────────────────────────────────────────────────────────

    def evaluate(
        self,
        accuracy_hit:    bool,
        portfolio_return: float,
        vix:             Optional[float] = None,
        cascade_strength: float = 0.0,
        is_crypto:       bool = False,
    ) -> CircuitStatus:
        """
        Called once per window. Returns the circuit status for this window.
        Updates internal state with observed outcomes.
        """
        # Update logs
        self._accuracy_log.append(1.0 if accuracy_hit else 0.0)
        self._accuracy_log = self._accuracy_log[-100:]  # keep last 100

        self._current_value *= (1 + portfolio_return)
        if self._current_value > self._peak_value:
            self._peak_value = self._current_value
        self._return_log.append(portfolio_return)
        self._return_log = self._return_log[-200:]

        if vix is not None:
            self._vix_history.append(vix)
            self._vix_history = self._vix_history[-50:]

        # ── RealTimeRiskManager snapshot ──────────────────────────────────────
        # Replaces manual VaR calculation. Cornish-Fisher VaR + RNIV dispersion.
        # risk_multiplier is the position-sizing scalar produced by the manager
        # (e.g. 0.70 when RNIV > 30%, 0.50 when CVaR > 5%).
        self._risk_manager.update(np.array([portfolio_return]))
        risk_snap: RiskSnapshot = self._risk_manager.snapshot()

        # Evaluate each gate (RNIV check lives inside _evaluate_gates)
        state, reason, triggered_by = self._evaluate_gates(
            vix, cascade_strength, is_crypto, risk_snap
        )
        dte = self._select_dte_strategy(vix, cascade_strength)

        # Combined scalar: circuit state × risk_multiplier
        # e.g. NORMAL (1.0) × risk_multiplier(0.70) = 0.70 when RNIV is high
        circuit_scalar = self._position_scalar(state)
        scalar = float(circuit_scalar * risk_snap.risk_multiplier)

        status = CircuitStatus(
            state           = state,
            dte_strategy    = dte,
            position_scalar = scalar,
            reason          = reason,
            triggered_by    = triggered_by,
            vix_level       = vix,
            accuracy_20w    = self._rolling_accuracy(self.config.accuracy_window),
            cascade_active  = self._is_cascade(cascade_strength),
            rniv            = risk_snap.rniv,
            risk_multiplier = risk_snap.risk_multiplier,
        )

        # Alert coordination bus on state transitions
        if state != self._state:
            self._on_state_change(state, status)
        self._state = state

        if self.bus:
            self.bus.log_window(
                self.pool_id,
                factor_accuracy  = self._rolling_accuracy(20),
                portfolio_return = portfolio_return,
                circuit_state    = state.value,
                cascade_strength = cascade_strength,
            )

        return status

    def reset(self):
        """Manual reset from HALTED state."""
        if self._state == CircuitState.HALTED:
            logger.info(f"[{self.pool_id}] Circuit reset manually")
            self._state = CircuitState.NORMAL
            self._halted_at = None
            self._consecutive_pauses = 0

    def can_trade(self, status: CircuitStatus) -> bool:
        return status.state not in (CircuitState.PAUSED, CircuitState.HALTED)

    # ── GATE EVALUATION ────────────────────────────────────────────────────────

    def _evaluate_gates(
        self,
        vix:              Optional[float],
        cascade_strength: float,
        is_crypto:        bool,
        risk_snap:        Optional["RiskSnapshot"] = None,
    ) -> Tuple[CircuitState, str, str]:
        """
        Evaluate gates in priority order. First gate that fires wins.
        Returns (state, reason, rule_name).
        """
        c = self.config

        # 1. Hard halt: excessive drawdown
        dd = self._current_drawdown()
        if dd >= c.drawdown_halted:
            if self._halted_at is None:
                self._halted_at = datetime.now(timezone.utc)
            return (CircuitState.HALTED,
                    f"Drawdown {dd:.1%} exceeds halt threshold {c.drawdown_halted:.1%}",
                    "drawdown_halt")

        # 2. Hard halt: consecutive pauses (signal has broken down)
        if self._consecutive_pauses >= 10:
            return (CircuitState.HALTED,
                    f"{self._consecutive_pauses} consecutive paused windows — signal review required",
                    "consecutive_pause_halt")

        # 3. Pause: accuracy too low
        acc = self._rolling_accuracy(c.accuracy_window)
        if acc is not None and acc < c.accuracy_floor_paused:
            self._consecutive_pauses += 1
            return (CircuitState.PAUSED,
                    f"Rolling {c.accuracy_window}-window accuracy {acc:.1%} below floor {c.accuracy_floor_paused:.1%}",
                    "accuracy_floor")
        else:
            self._consecutive_pauses = 0

        # 4. Pause: high VIX (only relevant for 0DTE, not pool execution)
        # Pools continue trading during high VIX — only 0DTE strategy changes.
        # No pool pause gate for VIX.

        # 5. Crypto: cascade regime detected
        if is_crypto and self._is_cascade(cascade_strength):
            return (CircuitState.REDUCED,
                    f"Cascade regime detected (strength={cascade_strength:.3f}), switching to 2hr cadence",
                    "crypto_cascade")

        # 6. Reduced: accuracy declining
        if acc is not None and acc < c.accuracy_floor_reduced:
            return (CircuitState.REDUCED,
                    f"Rolling {c.accuracy_window}-window accuracy {acc:.1%} declining",
                    "accuracy_declining")

        # 7. Reduced: drawdown warning
        if dd >= c.drawdown_reduced:
            return (CircuitState.REDUCED,
                    f"Drawdown {dd:.1%} in warning zone",
                    "drawdown_warning")

        # 8. Reduced: RNIV > 0.30 — risk model uncertainty (new trigger)
        # RNIV = dispersion between parametric, historical, and stressed VaR.
        # When the three VaR methods disagree by >30%, the model cannot be trusted
        # at full size. Reduce to 50% while position_scalar is also multiplied by
        # risk_multiplier (0.70 from RealTimeRiskManager), giving an effective
        # scalar of ~0.35 — the system's most conservative non-PAUSED state.
        if risk_snap is not None and risk_snap.rniv > 0.30:
            return (CircuitState.REDUCED,
                    f"RNIV {risk_snap.rniv:.2f} > 0.30 — risk model uncertainty, reducing size",
                    "rniv_elevated")

        return (CircuitState.NORMAL, "All gates clear", "none")

    def _select_dte_strategy(
        self,
        vix: Optional[float],
        cascade_strength: float,
    ) -> DTEStrategy:
        """Select 0DTE overlay strategy based on VIX and regime."""
        if vix is None:
            return DTEStrategy.IRON_CONDOR  # safe default

        c = self.config
        if self._is_cascade(cascade_strength):
            return DTEStrategy.SKIP
        if vix > c.vix_spread_max:
            return DTEStrategy.SKIP
        if vix > c.vix_condor_max:
            return DTEStrategy.CREDIT_SPREAD
        if vix > c.vix_straddle_max:
            return DTEStrategy.IRON_CONDOR
        return DTEStrategy.STRADDLE

    def _position_scalar(self, state: CircuitState) -> float:
        scalars = {
            CircuitState.NORMAL:  1.0,
            CircuitState.REDUCED: 0.5,
            CircuitState.PAUSED:  0.0,
            CircuitState.HALTED:  0.0,
        }
        return scalars[state]

    # ── HELPERS ────────────────────────────────────────────────────────────────

    def _rolling_accuracy(self, window: int) -> Optional[float]:
        if len(self._accuracy_log) < max(5, window // 4):
            return None
        return float(np.mean(self._accuracy_log[-window:]))

    def _current_drawdown(self) -> float:
        if self._peak_value == 0:
            return 0.0
        return (self._peak_value - self._current_value) / self._peak_value

    def _is_cascade(self, cascade_strength: float, threshold: float = -0.5) -> bool:
        """Cascade regime: cascade signal strongly negative AND vol spike."""
        if cascade_strength > threshold:
            return False
        if len(self._return_log) < self.config.cascade_window:
            return False
        recent_vol = float(np.std(self._return_log[-self.config.cascade_window:]))
        if len(self._return_log) < 20:
            return False
        baseline_vol = float(np.std(self._return_log[-20:]))
        if baseline_vol < 1e-8:
            return False
        return (recent_vol / baseline_vol) >= self.config.cascade_vol_mult

    def _on_state_change(self, new_state: CircuitState, status: CircuitStatus):
        logger.warning(
            f"[{self.pool_id}] Circuit state: {self._state.value} → "
            f"{new_state.value} | {status.reason}"
        )
        if self.bus:
            import uuid
            from orchestration.event_bus import Message
            self.bus.publish(Message(
                id         = str(uuid.uuid4()),
                from_agent = self.pool_id,
                to_agent   = None,  # broadcast
                msg_type   = "circuit_alert",
                payload    = {
                    "pool_id":    self.pool_id,
                    "from_state": self._state.value,
                    "to_state":   new_state.value,
                    "reason":     status.reason,
                    "rule":       status.triggered_by,
                    "vix":        status.vix_level,
                    "accuracy":   status.accuracy_20w,
                }
            ))


# ── BORROW COST FILTER ────────────────────────────────────────────────────────

def filter_shortable(
    candidates: List[str],
    borrow_costs: Dict[str, float],
    config: CircuitConfig = DEFAULT_CONFIG,
) -> List[str]:
    """
    Remove any short candidates whose annualized borrow cost
    exceeds the alpha threshold. Called pre-QP on every window.

    borrow_costs: {ticker: annualized_rate} — from live IBKR API
    Returns filtered list with HTB names removed.
    """
    filtered = []
    removed  = []
    for ticker in candidates:
        cost = borrow_costs.get(ticker, 0.0)
        if cost <= config.borrow_cost_max:
            filtered.append(ticker)
        else:
            removed.append(f"{ticker}({cost:.1%})")

    if removed:
        logger.debug(f"Borrow cost filter removed: {removed}")
    return filtered
