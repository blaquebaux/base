"""
blaque_baux/config.py
─────────────────────
Central configuration for Phase 1 signal validation backtest.
Copy .env.example to .env and fill in your Polygon.io API key.

All parameters are tunable here — no magic numbers elsewhere in the codebase.
"""

import os
from dataclasses import dataclass, field
from typing import List, Dict
from dotenv import load_dotenv

load_dotenv()


# ── API ───────────────────────────────────────────────────────────────────────

POLYGON_API_KEY: str = os.getenv("POLYGON_API_KEY", "")


# ── BACKTEST WINDOW ───────────────────────────────────────────────────────────

BACKTEST_START: str = "2023-01-01"   # 2 years of 15-min data
BACKTEST_END:   str = "2024-12-31"
REGION:         str = "US"           # Phase 1: US only. Expand in Phase 4.


# ── BAR CADENCE ───────────────────────────────────────────────────────────────

BAR_MINUTES: int = 15   # 15-min windows for equity. Change to 60/120 for crypto.


# ── EQUITY UNIVERSE ───────────────────────────────────────────────────────────
# Liquid S&P 500 names only — index constituents = easy-to-borrow, tight spreads.
# 50 longs + 50 shorts = 100 names. Start with 40 for Phase 1 to reduce API load.

EQUITY_UNIVERSE: List[str] = [
    # Tech / Growth
    "AAPL", "MSFT", "NVDA", "GOOGL", "META", "AMZN", "TSLA", "AMD", "INTC", "QCOM",
    # Financials
    "JPM", "BAC", "GS", "MS", "WFC", "C", "BLK", "AXP", "USB", "PNC",
    # Energy
    "XOM", "CVX", "COP", "SLB", "OXY", "PSX", "VLO", "MPC", "HAL", "BKR",
    # Healthcare
    "JNJ", "UNH", "PFE", "ABBV", "MRK", "LLY", "TMO", "ABT", "DHR", "BMY",
    # Consumer / Industrials
    "HD", "WMT", "PG", "KO", "PEP", "MCD", "NKE", "CAT", "GE", "BA",
    # Utilities / Rates-sensitive
    "NEE", "DUK", "SO", "D", "AEP",
    # Materials
    "FCX", "NEM", "AA", "CF", "MOS",
]

N_LONGS:  int = 25   # long book size per window
N_SHORTS: int = 25   # short book size per window


# ── FUTURES SIGNAL SOURCES ────────────────────────────────────────────────────
# These are the cascade signal inputs. Polygon carries these as indices/futures.
# Ticker format for Polygon futures: I:{TICKER} for indices, X:{TICKER} for forex

FUTURES_SIGNALS: Dict[str, Dict] = {
    # Index futures — primary cascade source
    "SPY":  {"type": "etf",    "maps_to": "broad_market",  "weight": 0.35},
    "QQQ":  {"type": "etf",    "maps_to": "tech_growth",   "weight": 0.25},
    "IWM":  {"type": "etf",    "maps_to": "small_cap",     "weight": 0.10},
    # Sector ETFs — cross-sectional signal
    "XLE":  {"type": "sector", "maps_to": "energy",        "weight": 0.08},
    "XLF":  {"type": "sector", "maps_to": "financials",    "weight": 0.08},
    "XLK":  {"type": "sector", "maps_to": "technology",    "weight": 0.08},
    "XLV":  {"type": "sector", "maps_to": "healthcare",    "weight": 0.06},
    # Macro / inter-market signals
    "TLT":  {"type": "rates",  "maps_to": "rates_inverse", "weight": 0.05},  # proxy for ZN
    "GLD":  {"type": "metals", "maps_to": "risk_off",      "weight": 0.03},  # proxy for GC
    "UUP":  {"type": "fx",     "maps_to": "dollar",        "weight": 0.03},  # proxy for DX
}

# Sector membership for each equity (used for relative strength factor)
SECTOR_MAP: Dict[str, str] = {
    "AAPL":"tech", "MSFT":"tech", "NVDA":"tech", "GOOGL":"tech", "META":"tech",
    "AMZN":"tech", "TSLA":"tech", "AMD":"tech", "INTC":"tech", "QCOM":"tech",
    "JPM":"financials", "BAC":"financials", "GS":"financials", "MS":"financials",
    "WFC":"financials", "C":"financials", "BLK":"financials", "AXP":"financials",
    "USB":"financials", "PNC":"financials",
    "XOM":"energy", "CVX":"energy", "COP":"energy", "SLB":"energy", "OXY":"energy",
    "PSX":"energy", "VLO":"energy", "MPC":"energy", "HAL":"energy", "BKR":"energy",
    "JNJ":"healthcare", "UNH":"healthcare", "PFE":"healthcare", "ABBV":"healthcare",
    "MRK":"healthcare", "LLY":"healthcare", "TMO":"healthcare", "ABT":"healthcare",
    "DHR":"healthcare", "BMY":"healthcare",
    "HD":"consumer", "WMT":"consumer", "PG":"consumer", "KO":"consumer",
    "PEP":"consumer", "MCD":"consumer", "NKE":"consumer",
    "CAT":"industrials", "GE":"industrials", "BA":"industrials",
    "NEE":"utilities", "DUK":"utilities", "SO":"utilities", "D":"utilities", "AEP":"utilities",
    "FCX":"materials", "NEM":"materials", "AA":"materials", "CF":"materials", "MOS":"materials",
}


# ── SIGNAL PARAMETERS ─────────────────────────────────────────────────────────

@dataclass
class SignalConfig:
    # Momentum look-back: how many prior bars to measure futures momentum
    momentum_lookback:  int   = 4      # 4 × 15min = 1 hour of prior momentum
    # Relative strength look-back: compare sector performance over
    rel_strength_bars:  int   = 8      # 2 hours of sector relative strength
    # EWMA decay for covariance estimation (RiskMetrics standard)
    ewma_lambda:        float = 0.94
    # Minimum bars of history before producing a signal
    min_history_bars:   int   = 96     # 1 full trading day
    # Signal combination weights
    w_futures_momentum: float = 0.45
    w_rel_strength:     float = 0.30
    w_inter_market:     float = 0.25


# ── OPTIMIZER PARAMETERS ─────────────────────────────────────────────────────

@dataclass
class OptimizerConfig:
    # Long/short ratio
    long_ratio:         float = 0.50   # 50/50 for Phase 1 — tune per region later
    # Maximum weight in any single position
    max_position_wt:    float = 0.08   # 8% max per name
    min_position_wt:    float = 0.01   # 1% minimum (avoid trivial positions)
    # Target portfolio return per window (used as QP constraint)
    target_return:      float = 0.008  # 0.8% per window
    # Turnover penalty (discourages excessive rebalancing)
    turnover_penalty:   float = 0.0005
    # Risk aversion parameter
    risk_aversion:      float = 0.5
    # Execution drag per leg (spread + commission)
    execution_drag:     float = 0.0008  # 0.08% per leg


# ── BACKTEST ENGINE PARAMETERS ────────────────────────────────────────────────

@dataclass
class BacktestConfig:
    # Walk-forward: train on this many bars, test on next bar
    train_window_bars:  int   = 480    # 5 days of 15-min bars
    # Step size between windows (1 = every bar, higher = faster backtest)
    step_size:          int   = 1
    # Whether to compute factor accuracy vs a simple long-only benchmark
    compute_benchmark:  bool  = True
    # Minimum number of valid test windows before reporting accuracy
    min_test_windows:   int   = 100


# ── PERFORMANCE THRESHOLDS ────────────────────────────────────────────────────
# Phase 1 pass/fail gates — if realized accuracy falls below these,
# the signal needs rework before Phase 2 paper trading begins.

ACCURACY_TARGET:    float = 0.58   # 58% minimum to proceed to Phase 2
ACCURACY_STRONG:    float = 0.63   # 63%+ = strong signal, proceed to Phase 2 immediately
WIN_RATE_TARGET:    float = 0.72   # combined L/S win rate
SHARPE_TARGET:      float = 1.5    # annualized Sharpe on backtest
MAX_DRAWDOWN_LIMIT: float = 0.15   # 15% max drawdown acceptable


# ── OUTPUT ────────────────────────────────────────────────────────────────────

OUTPUT_DIR:         str = "./results"
RESULTS_JSON:       str = "./results/phase1_results.json"
ACCURACY_PLOT:      str = "./results/factor_accuracy.png"
EQUITY_CURVE_PLOT:  str = "./results/equity_curve.png"


# ── INSTANTIATE DEFAULTS ──────────────────────────────────────────────────────

signal_cfg    = SignalConfig()
optimizer_cfg = OptimizerConfig()
backtest_cfg  = BacktestConfig()
