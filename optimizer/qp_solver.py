"""
blaque_baux/optimizer/qp_solver.py
────────────────────────────────────
Quadratic program portfolio optimizer using CVXPY.

This is exactly the Solver workflow from your finance grad school,
productionized for 15-minute rebalancing.

Problem formulation:
    minimize    w' Σ w  (portfolio variance)
    subject to:
        w' μ ≥ target_return          (minimum return constraint)
        sum(w_long)  = long_ratio     (long book sums to 1)
        sum(w_short) = -(1-long_ratio) (short book sums to -1)
        w_i ≥ min_wt  for i in longs  (minimum position)
        w_i ≤ max_wt  for i in longs  (maximum position)
        w_i ≤ -min_wt for i in shorts
        w_i ≥ -max_wt for i in shorts
        turnover penalty (minimize |w_new - w_prev|)

The optimizer also respects borrow costs by adjusting expected
returns for short positions before solving.

Outputs: weights dict {ticker: weight}
  Positive weights = long positions
  Negative weights = short positions
"""

import logging
import warnings
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
import cvxpy as cp

from config import optimizer_cfg

logger = logging.getLogger(__name__)

# Suppress CVXPY solver verbosity
warnings.filterwarnings("ignore", category=UserWarning)


# ── COVARIANCE ESTIMATION ─────────────────────────────────────────────────────

def ewma_covariance(
    returns: pd.DataFrame,
    lam: float = 0.94,
    min_periods: int = 20,
) -> np.ndarray:
    """
    Compute EWMA (exponentially weighted) covariance matrix.
    RiskMetrics standard: lambda = 0.94 for daily, 0.97 for monthly.
    For 15-min bars we use 0.94 (same decay, more observations).

    Returns: (n_assets × n_assets) covariance matrix
    """
    n = len(returns.columns)
    if len(returns) < min_periods:
        return np.eye(n) * returns.std().values ** 2  # diagonal fallback

    # Use pandas EWMA covariance
    ewm_cov = returns.ewm(com=(1 - lam) / lam, min_periods=min_periods).cov()

    # Extract the last timestamp's covariance matrix
    last_ts = ewm_cov.index.get_level_values(0)[-1]
    cov_matrix = ewm_cov.loc[last_ts].values

    # Ensure positive semi-definite (numerical cleanup)
    cov_matrix = _ensure_psd(cov_matrix)
    return cov_matrix


def _ensure_psd(matrix: np.ndarray, epsilon: float = 1e-6) -> np.ndarray:
    """
    Ensure matrix is positive semi-definite by clipping negative eigenvalues.
    """
    eigvals, eigvecs = np.linalg.eigh(matrix)
    eigvals = np.maximum(eigvals, epsilon)
    return eigvecs @ np.diag(eigvals) @ eigvecs.T


# ── MAIN OPTIMIZER ────────────────────────────────────────────────────────────

def optimize_portfolio(
    factor_scores: pd.Series,
    returns_history: pd.DataFrame,
    long_tickers: List[str],
    short_tickers: List[str],
    prev_weights: Optional[Dict[str, float]] = None,
    borrow_costs: Optional[Dict[str, float]] = None,
    confidence_levels: Optional[List[float]] = None,
) -> Tuple[Dict[str, float], Dict]:
    """
    Main portfolio optimizer. Runs the QP solve for one window.

    Args:
        factor_scores:     Series {ticker: score} — expected relative returns
        returns_history:   DataFrame of recent returns for covariance estimation
        long_tickers:      tickers selected for long book
        short_tickers:     tickers selected for short book
        prev_weights:      previous window's weights (for turnover penalty)
        borrow_costs:      annualized borrow cost per ticker (for HTB stocks)
        confidence_levels: list of confidence levels for efficient frontier
                           (mimics the Solver multi-confidence run from grad school)

    Returns:
        weights:    {ticker: weight}  (positive=long, negative=short)
        meta:       diagnostic info (expected_return, expected_vol, solve_status)
    """
    all_tickers = long_tickers + short_tickers
    n_long  = len(long_tickers)
    n_short = len(short_tickers)
    n_total = n_long + n_short

    if n_total < 4:
        logger.warning("Too few tickers for optimization, returning equal weight")
        return _equal_weight_fallback(long_tickers, short_tickers), {"status": "fallback"}

    # ── Expected returns (factor scores → per-window alpha estimates) ──────────
    mu = np.array([
        factor_scores.get(t, 0) * optimizer_cfg.target_return
        for t in all_tickers
    ])

    # Adjust for borrow costs on short positions
    if borrow_costs:
        for i, ticker in enumerate(all_tickers[n_long:], start=n_long):
            cost_annual = borrow_costs.get(ticker, 0)
            cost_per_window = cost_annual / (252 * 26)  # 26 windows/day approx
            mu[i] -= cost_per_window

    # ── Covariance matrix ───────────────────────────────────────────────────
    valid_hist = returns_history[all_tickers].dropna()
    if len(valid_hist) < 20:
        valid_hist = returns_history[all_tickers].fillna(0)

    cov = ewma_covariance(valid_hist)

    # ── CVXPY Variables ─────────────────────────────────────────────────────
    w = cp.Variable(n_total)

    # ── Objective: minimize variance + turnover penalty ────────────────────
    portfolio_variance = cp.quad_form(w, cov)

    if prev_weights is not None:
        w_prev = np.array([prev_weights.get(t, 0) for t in all_tickers])
        turnover = cp.norm1(w - w_prev)
        objective = cp.Minimize(
            optimizer_cfg.risk_aversion * portfolio_variance +
            optimizer_cfg.turnover_penalty * turnover
        )
    else:
        objective = cp.Minimize(optimizer_cfg.risk_aversion * portfolio_variance)

    # ── Constraints ─────────────────────────────────────────────────────────
    long_ratio  = optimizer_cfg.long_ratio
    short_ratio = 1 - long_ratio

    constraints = [
        # Long book: weights sum to long_ratio, each bounded
        cp.sum(w[:n_long]) == long_ratio,
        w[:n_long] >= optimizer_cfg.min_position_wt,
        w[:n_long] <= optimizer_cfg.max_position_wt,

        # Short book: weights sum to -short_ratio, each bounded
        cp.sum(w[n_long:]) == -short_ratio,
        w[n_long:] <= -optimizer_cfg.min_position_wt,
        w[n_long:] >= -optimizer_cfg.max_position_wt,

        # Minimum expected return (net of drag)
        mu @ w >= optimizer_cfg.target_return - optimizer_cfg.execution_drag * 2,
    ]

    # ── Solve ────────────────────────────────────────────────────────────────
    problem = cp.Problem(objective, constraints)

    try:
        problem.solve(solver=cp.CLARABEL, verbose=False)
    except Exception:
        try:
            problem.solve(solver=cp.SCS, verbose=False)
        except Exception as e:
            logger.warning(f"QP solve failed: {e}, using equal weight fallback")
            return _equal_weight_fallback(long_tickers, short_tickers), {"status": "failed"}

    if w.value is None or problem.status not in ["optimal", "optimal_inaccurate"]:
        return _equal_weight_fallback(long_tickers, short_tickers), {"status": problem.status}

    # ── Package results ──────────────────────────────────────────────────────
    weights = {t: float(w.value[i]) for i, t in enumerate(all_tickers)}

    # Clean up tiny weights (numerical noise)
    weights = {
        t: v for t, v in weights.items()
        if abs(v) >= optimizer_cfg.min_position_wt * 0.5
    }

    # Compute diagnostics
    w_arr = np.array([weights.get(t, 0) for t in all_tickers])
    expected_return = float(mu @ w_arr)
    expected_vol    = float(np.sqrt(w_arr @ cov @ w_arr))

    meta = {
        "status":          problem.status,
        "expected_return": expected_return,
        "expected_vol":    expected_vol,
        "sharpe_est":      expected_return / max(expected_vol, 1e-8),
        "n_long":          sum(1 for v in weights.values() if v > 0),
        "n_short":         sum(1 for v in weights.values() if v < 0),
    }

    return weights, meta


# ── EFFICIENT FRONTIER ────────────────────────────────────────────────────────

def compute_efficient_frontier(
    factor_scores: pd.Series,
    returns_history: pd.DataFrame,
    long_tickers: List[str],
    short_tickers: List[str],
    confidence_levels: List[float] = None,
) -> pd.DataFrame:
    """
    Run the optimizer at multiple target return levels to trace the
    efficient frontier — exactly the Solver multi-confidence workflow
    from your finance grad school.

    Returns DataFrame with columns:
        target_return, achieved_return, achieved_vol, sharpe, weights_json

    This is a diagnostic tool — Phase 1 runs this on sample windows
    to show the tradeoff curve and validate the optimizer is working.
    """
    if confidence_levels is None:
        confidence_levels = [0.90, 0.93, 0.95, 0.97, 0.98, 0.99]

    results = []
    all_tickers = long_tickers + short_tickers

    # Get base covariance once
    valid_hist = returns_history[all_tickers].dropna()
    cov = ewma_covariance(valid_hist)
    mu = np.array([factor_scores.get(t, 0) * optimizer_cfg.target_return for t in all_tickers])

    for confidence in confidence_levels:
        # Interpret confidence as: achieve this percentile of the return distribution
        # Higher confidence = higher target return = higher risk required
        target_scalar = _confidence_to_target(confidence, mu, cov)
        weights, meta = optimize_portfolio(
            factor_scores=factor_scores,
            returns_history=returns_history,
            long_tickers=long_tickers,
            short_tickers=short_tickers,
        )

        results.append({
            "confidence":      confidence,
            "target_return":   target_scalar,
            "achieved_return": meta.get("expected_return", 0),
            "achieved_vol":    meta.get("expected_vol", 0),
            "sharpe":          meta.get("sharpe_est", 0),
            "solve_status":    meta.get("status", "unknown"),
        })

    return pd.DataFrame(results)


def _confidence_to_target(
    confidence: float,
    mu: np.ndarray,
    cov: np.ndarray,
) -> float:
    """
    Convert a confidence level to a target return.
    At 99% confidence, target = top 1% of achievable return.
    Uses the maximum Sharpe portfolio's return × confidence scalar.
    """
    max_achievable = float(np.max(mu))
    return max_achievable * confidence


# ── FALLBACK ──────────────────────────────────────────────────────────────────

def _equal_weight_fallback(
    long_tickers: List[str],
    short_tickers: List[str],
) -> Dict[str, float]:
    """
    Equal-weight fallback when QP solve fails.
    Used for robustness — the backtest should never crash on a bad window.
    """
    n_long  = len(long_tickers)
    n_short = len(short_tickers)
    long_ratio  = optimizer_cfg.long_ratio
    short_ratio = 1 - long_ratio

    weights = {}
    if n_long  > 0: weights.update({t: long_ratio  / n_long  for t in long_tickers})
    if n_short > 0: weights.update({t: -short_ratio / n_short for t in short_tickers})
    return weights
