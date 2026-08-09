#!/usr/bin/python3
# =============================================================================
# blunt_5_ulcer_pain.py — BLAQUE BAUX BLUNT #5.
#
# PROPOSED: rank names by the Ulcer Index (Peter Martin's RMS-of-drawdown; the
#   "Pain Index" of Becker/Moore is the mean absolute drawdown) and SHORT the ones
#   with the worst downside pain.
# FINDING:  backwards, and for the same reason as #1 — the highest-Ulcer/Pain names
#   are exactly the recent losers, which bounce. Shorting them loses (~-1.0 Sharpe).
#   Per "go long the backwards ones", the sleeve is FLIPPED to long the highest-pain
#   names. Unlike #1, this one KEEPS a real edge after removing beta: long highest-
#   Ulcer, beta-neutral, is ~+0.46 Sharpe — the strongest short-term contrarian
#   (loser-bounce) signal of the flipped trio. The raw long leg is still mostly
#   beta, but the drawdown screen genuinely selects the best bounce candidates.
# Directional research; gross of borrow/costs. Read-only.
# =============================================================================
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _blunt_common import load_basket, quantile_legs, ann

used, dts, C, R = load_basket()
T, N = R.shape
W = 60
ulcer = np.full((T, N), np.nan); pain = np.full((T, N), np.nan)
for t in range(W, T):
    seg = C[t - W:t + 1]                          # price window, known at close t
    dd = (seg / np.maximum.accumulate(seg, 0) - 1) * 100
    ulcer[t] = np.sqrt((dd ** 2).mean(0))
    pain[t] = np.abs(dd).mean(0)

lu = quantile_legs(ulcer, R); lp = quantile_legs(pain, R)
print("=" * 70, "\nBLUNT #5 — Ulcer / Pain index, cross-sectional (60d)\n" + "=" * 70)
print(f"basket {N} names, {T} days ({dts[1]}..{dts[-1]})\n")
print(f"  PROPOSED  short highest-Ulcer:        Sharpe {ann(lu['short_top'])[0]:+.2f}  maxDD {ann(lu['short_top'])[2]*100:.0f}%  <- backwards")
print(f"  FLIPPED   long  highest-Ulcer:        Sharpe {ann(lu['long_top'])[0]:+.2f}  CAGR {ann(lu['long_top'])[1]*100:+.1f}%")
print(f"    beta-neutral (minus basket mean):   Sharpe {ann(lu['long_top_neutral'])[0]:+.2f}  <- true selection edge")
print(f"  PROPOSED  short highest-Pain:         Sharpe {ann(lp['short_top'])[0]:+.2f}")
print(f"  FLIPPED   long  highest-Pain:         Sharpe {ann(lp['long_top'])[0]:+.2f}  (neutral {ann(lp['long_top_neutral'])[0]:+.2f})")
print("\nVERDICT: same short-side trap as #1 (downside-vol screens select recent")
print("losers; shorting them fights the bounce). But FLIPPED long it is the best of")
print("the trio: a real ~+0.46 beta-neutral reversal edge. Worth developing as a")
print("beta-neutral loser-bounce sleeve; Ulcer/Pain also double as risk-sizing inputs.")
