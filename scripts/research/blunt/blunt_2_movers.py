#!/usr/bin/python3
# =============================================================================
# blunt_2_movers.py — BLAQUE BAUX BLUNT #2.
#
# PROPOSED: piggyback the "market movers" board — go LONG today's biggest gainers
#   and SHORT today's biggest losers, expecting the move to continue tomorrow.
# FINDING:  backwards at the daily horizon. Stocks mean-REVERT day to day
#   (Lehmann / Lo-MacKinlay short-term reversal), so buying winners and shorting
#   losers (momentum) loses; the contrarian book (long losers) is the positive
#   side. Per "go long the backwards ones", the sleeve is FLIPPED to long the
#   bottom movers. Both the momentum and contrarian edges are tiny gross and do
#   not survive daily-rebalance costs.
# RESULTS AS TESTED (45-name basket, 1-day horizon, 2016-2026, gross of costs):
#   long winners / short losers  (proposed momentum)   Sharpe -0.14   <- fails
#   long losers  / short winners (contrarian)          Sharpe +0.14
#   long the losers, long-only   (flipped)             Sharpe +0.97   CAGR +23.5%
#     beta-neutral (minus basket)                       Sharpe +0.24   <- small real bounce
#   5-day formation: momentum -0.07 | contrarian +0.07
# Both the reversal edge and its inverse are tiny and would not survive daily
# rebalance costs on a ~90-name L/S book. Point-in-time; may need modification
# later. Documented so the test and both directions are on the record.
# Directional research; gross of costs. Read-only.
# =============================================================================
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _blunt_common import load_basket, quantile_legs, ann

used, dts, C, R = load_basket()
T, N = R.shape
legs = quantile_legs(R, R)                    # score = today's return; leg earns next-day
mom_ls = legs['long_top'] - legs['long_bottom']     # long winners / short losers (proposed)
con_ls = legs['long_bottom'] - legs['long_top']     # long losers  / short winners (contrarian)

print("=" * 70, "\nBLUNT #2 — piggyback the movers (1-day horizon)\n" + "=" * 70)
print(f"basket {N} names, {T} days ({dts[1]}..{dts[-1]})\n")
print(f"  PROPOSED  long winners / short losers (momentum): Sharpe {ann(mom_ls)[0]:+.2f}   <- backwards")
print(f"  OPPOSITE  long losers  / short winners (contrarn): Sharpe {ann(con_ls)[0]:+.2f}")
print(f"  FLIPPED   long the losers (long-only):            Sharpe {ann(legs['long_bottom'])[0]:+.2f}  CAGR {ann(legs['long_bottom'])[1]*100:+.1f}%")
print(f"    beta-neutral (minus basket mean):               Sharpe {ann(legs['long_bottom_neutral'])[0]:+.2f}   <- true bounce edge")
print("\nVERDICT: the movers board is a REVERSAL signal, not a continuation one — the")
print("proposed momentum book loses. The contrarian/flipped edge is real but tiny,")
print("and daily-rebalance costs on a 90-name L/S book eat it. Not tradeable as-is.")
