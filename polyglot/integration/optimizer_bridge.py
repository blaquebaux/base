"""
blaque_baux/integration/optimizer_bridge.py
────────────────────────────────────────────
Drop-in bridge: Julia optimizer ↔ Python orchestrator.

Replaces qp_solver.py (CVXPY) with Julia/JuMP for:
  - QP portfolio optimization (Clarabel solver, native Julia)
  - Efficient frontier computation
  - Six Sigma Oracle (1M Monte Carlo)
  - Distribution fitting (AIC)
  - Monte Carlo simulation (GBM + jump-diffusion)

Usage:
    # Swap one import in optimizer_service.py:
    # OLD: from optimizer.qp_solver import optimize_portfolio
    # NEW: from integration.optimizer_bridge import optimize_portfolio

Fallback: If Julia/juliacall not available, falls back to CVXPY.
"""

import logging
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# ── Julia initialization ────────────────────────────────────────────────────
# juliacall starts a Julia process and keeps it alive for the session.
# First call has ~3s JIT warmup; subsequent calls are fast.

JULIA_DIR = Path(__file__).parent.parent / "optimizer_jl"
JULIA_AVAILABLE = False
jl = None

def _init_julia():
    """Lazy Julia initialization — called on first use."""
    global JULIA_AVAILABLE, jl
    if jl is not None:
        return

    try:
        from juliacall import Main as _jl
        jl = _jl

        # Activate the project environment
        jl.seval(f'using Pkg; Pkg.activate("{JULIA_DIR}")')

        # Include the modules
        jl.include(str(JULIA_DIR / "qp_solver.jl"))
        jl.include(str(JULIA_DIR / "six_sigma_oracle.jl"))

        # Warm up JIT (first call compiles everything)
        logger.info("Julia JIT warmup — first solve will be slow (~3s)")
        _warmup()

        JULIA_AVAILABLE = True
        logger.info("Julia optimizer loaded — JuMP/Clarabel active")

    except ImportError:
        logger.warning(
            "juliacall not found — falling back to CVXPY. "
            "Install: pip install juliacall"
        )
    except Exception as e:
        logger.warning(f"Julia init failed: {e} — falling back to CVXPY")


def _warmup():
    """JIT warmup with a trivial 4-asset problem."""
    n = 4
    scores = jl.Vector[jl.Float64]([0.01, 0.02, -0.01, -0.02])
    hist = jl.Matrix[jl.Float64](np.random.randn(100, n) * 0.01)
    long_idx = jl.Vector[jl.Int]([1, 2])
    short_idx = jl.Vector[jl.Int]([3, 4])
    jl.QPSolver.optimize_portfolio(scores, hist, long_idx, short_idx)


# ── Type conversion helpers ──────────────────────────────────────────────────

def _to_jl_vec(arr: np.ndarray):
    """Convert numpy array to Julia Vector{Float64}."""
    return jl.Vector[jl.Float64](arr.astype(np.float64).tolist())

def _to_jl_mat(arr: np.ndarray):
    """Convert numpy 2D array to Julia Matrix{Float64}."""
    return jl.Matrix[jl.Float64](arr.astype(np.float64))

def _to_jl_int_vec(arr) -> list:
    """Convert Python list of 0-based indices to Julia 1-based Vector{Int}."""
    return jl.Vector[jl.Int]([i + 1 for i in arr])

def _from_jl_vec(jl_vec) -> np.ndarray:
    """Convert Julia Vector to numpy array."""
    return np.array(list(jl_vec), dtype=np.float64)

def _from_jl_dict(jl_dict) -> Dict:
    """Convert Julia Dict to Python dict."""
    return {str(k): v for k, v in jl_dict.items()}


# ══════════════════════════════════════════════════════════════════════════════
# PORTFOLIO OPTIMIZER — drop-in for qp_solver.optimize_portfolio
# ══════════════════════════════════════════════════════════════════════════════

def optimize_portfolio(
    factor_scores: pd.Series,
    returns_history: pd.DataFrame,
    long_tickers: List[str],
    short_tickers: List[str],
    prev_weights: Optional[Dict[str, float]] = None,
    borrow_costs: Optional[Dict[str, float]] = None,
    confidence_levels: Optional[List[float]] = None,
    risk_params=None,
    lane_cfg=None,
    oracle=None,
) -> Tuple[Dict[str, float], Dict]:
    """
    Main portfolio optimizer. Interface-identical to qp_solver.optimize_portfolio().
    Routes to Julia/JuMP if available, falls back to CVXPY.
    """
    _init_julia()

    if not JULIA_AVAILABLE:
        try:
            from optimizer.qp_solver import optimize_portfolio as _cvxpy_optimize
        except ImportError:
            from qp_solver import optimize_portfolio as _cvxpy_optimize
        return _cvxpy_optimize(
            factor_scores, returns_history,
            long_tickers, short_tickers,
            prev_weights, borrow_costs, confidence_levels,
            risk_params, lane_cfg, oracle,
        )

    return _optimize_julia(
        factor_scores, returns_history,
        long_tickers, short_tickers,
        prev_weights, borrow_costs,
        risk_params, lane_cfg, oracle,
    )


def _optimize_julia(
    factor_scores, returns_history,
    long_tickers, short_tickers,
    prev_weights, borrow_costs,
    risk_params, lane_cfg, oracle,
):
    """Julia/JuMP optimization path."""
    all_tickers = long_tickers + short_tickers
    n_long = len(long_tickers)
    n_total = len(all_tickers)

    if n_total < 4:
        try:
            from optimizer.qp_solver import _equal_weight_fallback
        except ImportError:
            from qp_solver import _equal_weight_fallback
        return _equal_weight_fallback(long_tickers, short_tickers), {"status": "fallback"}

    # Build inputs
    scores_arr = np.array([factor_scores.get(t, 0.0) for t in all_tickers])
    valid_hist = returns_history[all_tickers].dropna()
    if len(valid_hist) < 20:
        valid_hist = returns_history[all_tickers].fillna(0)
    hist_arr = valid_hist.values

    # Index arrays (0-based Python → 1-based Julia)
    long_idx = list(range(n_long))
    short_idx = list(range(n_long, n_total))

    # Convert to Julia types
    jl_scores = _to_jl_vec(scores_arr)
    jl_hist = _to_jl_mat(hist_arr)
    jl_long = _to_jl_int_vec(long_idx)
    jl_short = _to_jl_int_vec(short_idx)

    # Build kwargs
    kwargs = {}

    if prev_weights is not None:
        pw = np.array([prev_weights.get(t, 0.0) for t in all_tickers])
        kwargs["prev_weights"] = _to_jl_vec(pw)

    if borrow_costs is not None:
        bc = np.array([borrow_costs.get(t, 0.0) for t in all_tickers])
        kwargs["borrow_costs"] = _to_jl_vec(bc)

    if risk_params is not None:
        kwargs["risk_params"] = jl.QPSolver.RiskParams(
            long_ratio=risk_params.long_ratio,
            short_ratio=risk_params.short_ratio,
            var_constraint=risk_params.var_constraint,
            svar_constraint=risk_params.svar_constraint,
            position_scalar=risk_params.position_scalar,
            trend_label=risk_params.trend_label,
            trend_strength=risk_params.trend_strength,
        )

    # Oracle prior (L4)
    if oracle is not None and lane_cfg is not None and lane_cfg.lane == 'L4':
        w_prior, blend = oracle.oracle_penalty_term(all_tickers)
        if w_prior is not None:
            kwargs["oracle_prior"] = _to_jl_vec(w_prior)
            kwargs["oracle_blend"] = blend

    # Call Julia
    t0 = time.perf_counter()
    jl_weights, jl_meta = jl.QPSolver.optimize_portfolio(
        jl_scores, jl_hist, jl_long, jl_short,
        **kwargs,
    )
    bridge_ms = (time.perf_counter() - t0) * 1000

    # Convert back to Python
    weights_arr = _from_jl_vec(jl_weights)
    weights = {t: float(weights_arr[i]) for i, t in enumerate(all_tickers)
               if abs(weights_arr[i]) > 0.005}

    meta = _from_jl_dict(jl_meta)
    meta["bridge_ms"] = bridge_ms
    meta["engine"] = "julia_jump"

    return weights, meta


# ══════════════════════════════════════════════════════════════════════════════
# SIX SIGMA ORACLE — drop-in for risk_engine.SixSigmaOracle
# ══════════════════════════════════════════════════════════════════════════════

def compute_oracle_weights_julia(
    returns_history: pd.DataFrame,
    current_weights: Dict[str, float],
    n_sims: int = 1_000_000,
) -> Dict[str, float]:
    """
    Run the Six Sigma Oracle weight search in Julia.
    50-100× faster than the Python for-loop implementation.
    """
    _init_julia()

    if not JULIA_AVAILABLE:
        logger.warning("Julia unavailable for oracle — use Python fallback")
        return current_weights

    tickers = [t for t in current_weights if t in returns_history.columns]
    if len(tickers) < 4:
        return current_weights

    hist = returns_history[tickers].dropna().values
    cw = np.array([current_weights.get(t, 0.0) for t in tickers])

    cfg = jl.SixSigmaOracle.OracleConfig(
        n_simulations=n_sims,
        n_candidates=min(n_sims // 100, 10_000),
    )

    t0 = time.perf_counter()
    result = jl.SixSigmaOracle.compute_oracle_weights(
        _to_jl_mat(hist), _to_jl_vec(cw), cfg=cfg,
    )
    elapsed = (time.perf_counter() - t0) * 1000

    weights_out = _from_jl_vec(result.weights)

    logger.info(
        f"Julia SixSigmaOracle: {elapsed:.0f}ms | "
        f"loss_rate={result.loss_rate:.6f} | "
        f"target={result.target_loss_rate:.6f} | "
        f"gap={result.oracle_gap:.6f}"
    )

    return {t: float(weights_out[i]) for i, t in enumerate(tickers)}


# ══════════════════════════════════════════════════════════════════════════════
# MONTE CARLO BRIDGE
# ══════════════════════════════════════════════════════════════════════════════

def monte_carlo_gbm_julia(
    initial_prices: np.ndarray,
    drift: np.ndarray,
    volatility: np.ndarray,
    horizon_years: float,
    dt: float,
    n_paths: int,
    corr_matrix: Optional[np.ndarray] = None,
) -> np.ndarray:
    """
    GBM Monte Carlo via Julia. Returns (n_steps+1, n_assets, n_paths) array.
    """
    _init_julia()
    if not JULIA_AVAILABLE:
        raise RuntimeError("Julia not available for MC simulation")

    kwargs = {}
    if corr_matrix is not None:
        kwargs["corr_matrix"] = _to_jl_mat(corr_matrix)

    paths = jl.SixSigmaOracle.monte_carlo_gbm(
        _to_jl_vec(initial_prices),
        _to_jl_vec(drift),
        _to_jl_vec(volatility),
        horizon_years,
        dt,
        n_paths,
        **kwargs,
    )

    return np.array(paths)


def monte_carlo_jump_diffusion_julia(
    initial_prices: np.ndarray,
    drift: np.ndarray,
    volatility: np.ndarray,
    horizon_years: float,
    dt: float,
    n_paths: int,
    jump_intensity: float = 1.0,
    jump_mean: float = -0.05,
    jump_std: float = 0.10,
    corr_matrix: Optional[np.ndarray] = None,
) -> np.ndarray:
    """
    Merton jump-diffusion MC via Julia. Better for crypto tail events.
    Returns (n_steps+1, n_assets, n_paths) array.
    """
    _init_julia()
    if not JULIA_AVAILABLE:
        raise RuntimeError("Julia not available for MC simulation")

    kwargs = {
        "jump_intensity": jump_intensity,
        "jump_mean": jump_mean,
        "jump_std": jump_std,
    }
    if corr_matrix is not None:
        kwargs["corr_matrix"] = _to_jl_mat(corr_matrix)

    paths = jl.SixSigmaOracle.monte_carlo_jump_diffusion(
        _to_jl_vec(initial_prices),
        _to_jl_vec(drift),
        _to_jl_vec(volatility),
        horizon_years,
        dt,
        n_paths,
        **kwargs,
    )

    return np.array(paths)


# ══════════════════════════════════════════════════════════════════════════════
# DISTRIBUTION FITTING BRIDGE
# ══════════════════════════════════════════════════════════════════════════════

def fit_distribution_julia(returns: np.ndarray) -> Dict:
    """
    AIC distribution fitting via Julia + TAR/Kelly computation.
    Returns best-fit distribution, all candidates, and tail metrics.

    Maps to distribution_regime.py regime classification:
      normal    → BELL_CURVE
      student_t → INVERTED_BELL
      gev       → L_CURVE

    Also computes TAR (Tail Asymmetry Ratio) and Kelly fraction,
    which flow into the StrategyGate in distribution_regime.py:
      TAR > 2.0  → gain tail dominant → bet with it
      TAR < 0.5  → loss tail dominant → invert directional book
      Kelly < 0  → math confirms reversal
    """
    _init_julia()
    if not JULIA_AVAILABLE:
        return {"distribution": "normal", "aic": float("inf"), "tar": 1.0, "kelly": 0.0}

    best, all_fits = jl.SixSigmaOracle.fit_distribution_aic(
        _to_jl_vec(returns)
    )

    result = {
        "distribution": str(best.distribution),
        "aic": float(best.aic),
        "params": _from_jl_dict(best.params),
        "all_fits": [
            {
                "distribution": str(f.distribution),
                "aic": float(f.aic),
            }
            for f in all_fits
        ],
    }

    # Map to regime
    dist_to_regime = {
        "normal": "bell_curve",
        "student_t": "inverted_bell",
        "gev": "l_curve",
    }
    result["regime"] = dist_to_regime.get(result["distribution"], "bell_curve")

    # Extract GEV tail exponent (ξ) — drives barbell severity in L-curve gate
    if result["distribution"] == "gev" and "xi" in result["params"]:
        result["tail_exponent"] = result["params"]["xi"]
    else:
        result["tail_exponent"] = None

    # Compute TAR/Kelly alongside the fit (same returns, avoids redundant call)
    tar_result = compute_tar_kelly_julia(returns)
    result.update(tar_result)

    return result


def compute_tar_kelly_julia(
    returns: np.ndarray,
    confidence: float = 0.95,
    win_probability: float = 0.05,
) -> Dict:
    """
    Compute TAR and Kelly fraction via Julia.

    TAR (Tail Asymmetry Ratio) = upside_potential / VaR
      TAR > 2.0: gain tail fatter → "1 extraordinary win in 20"
      TAR < 0.5: loss tail fatter → "1 catastrophic loss in 20"

    Kelly = (p × b - q) / b, where b = CVaR_upside / CVaR
      Kelly > 0: positive expectation, bet with position
      Kelly < 0: negative expectation, reverse position

    These flow into distribution_regime.py → StrategyGate:
      - TAR > 2.0 → extend directional book
      - TAR < 0.5 → INVERT directional book (longs → shorts, shorts → longs)
      - TAR 0.5–2.0 → standard barbell
    """
    _init_julia()
    if not JULIA_AVAILABLE:
        return {"tar": 1.0, "kelly": 0.0, "tar_signal": "neutral"}

    tk = jl.SixSigmaOracle.compute_tar_kelly(
        _to_jl_vec(returns),
        confidence=confidence,
        win_probability=win_probability,
    )

    tar = float(tk.tar)
    kelly = float(tk.kelly)

    # Classify
    if tar > 2.0:
        tar_signal = "long_tail"
    elif tar < 0.5:
        tar_signal = "short_tail"
    else:
        tar_signal = "neutral"

    return {
        "tar": tar,
        "kelly": kelly,
        "tar_signal": tar_signal,
        "var_95": float(tk.var_95),
        "upside_95": float(tk.upside_95),
        "cvar_95": float(tk.cvar_95),
        "cvar_upside_95": float(tk.cvar_upside_95),
        "cf_var": float(tk.cf_var),
        "cf_applied": bool(tk.cf_applied),
    }

