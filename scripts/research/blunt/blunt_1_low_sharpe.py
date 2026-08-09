#!/usr/bin/python3
# =============================================================================
# blunt_1_low_sharpe.py — BLAQUE BAUX BLUNT #1.
#
# PROPOSED: each day, short the names with the lowest trailing Sharpe (assume a
#   low Sharpe = a fragile, high-stress name that keeps falling).
# FINDING:  backwards. Low-Sharpe names are recent LOSERS, and at a 1-day horizon
#   losers BOUNCE (short-term reversal). Shorting them steps in front of the bounce
#   (Sharpe ~-0.9, catastrophic drawdown). Per the "go long the backwards ones"
#   call, the sleeve is FLIPPED: go LONG the lowest-Sharpe names. That long leg is
#   positive gross, but the beta-neutral version (leg minus the equal-weight
#   basket) shows the bounce is small — most of the long-leg return is just market
#   beta, not selection alpha.
# Directional research; gross of financing/borrow. Read-only.
# =============================================================================
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _blunt_common import load_basket, quantile_legs, ann

used, dts, C, R = load_basket()
T, N = R.shape
W = 60
sharpe = np.full((T, N), np.nan)
for t in range(W, T):
    win = R[t - W:t]; mu = win.mean(0); sd = win.std(0)
    sharpe[t] = np.where(sd > 0, mu / sd, np.nan)

legs = quantile_legs(sharpe, R)
print("=" * 70, "\nBLUNT #1 — trailing-60d Sharpe, cross-sectional\n" + "=" * 70)
print(f"basket {N} names, {T} days ({dts[1]}..{dts[-1]})\n")
print(f"  PROPOSED  short lowest-Sharpe:        Sharpe {ann(legs['short_bottom'])[0]:+.2f}  maxDD {ann(legs['short_bottom'])[2]*100:.0f}%   <- backwards")
print(f"  FLIPPED   long  lowest-Sharpe:        Sharpe {ann(legs['long_bottom'])[0]:+.2f}  CAGR {ann(legs['long_bottom'])[1]*100:+.1f}%")
print(f"    beta-neutral (minus basket mean):   Sharpe {ann(legs['long_bottom_neutral'])[0]:+.2f}   <- the true selection edge")
print(f"  context   long  highest-Sharpe:       Sharpe {ann(legs['long_top'])[0]:+.2f}")
print(f"    beta-neutral (minus basket mean):   Sharpe {ann(legs['long_top_neutral'])[0]:+.2f}")
print("\nVERDICT: shorting low-Sharpe names is the short-term-reversal trap. Flipped")
print("to long, it makes money mostly via beta; the beta-neutral bounce is thin.")
print("Keep only as a mild contrarian tilt, not a standalone short.")
