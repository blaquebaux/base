#!/usr/bin/python3
# =============================================================================
# blunt_6_intraweek.py — BLAQUE BAUX BLUNT #6.
#
# PROPOSED: go long from Sunday night through Wednesday midday, then short from
#   Wednesday midday into Friday's close (an intraweek seasonality tilt).
# FINDING:  a real weekday asymmetry exists — Thursday and Friday are materially
#   weaker than Mon-Wed (most pronounced in QQQ). Long-first-half / short-second-
#   half prints a positive Sharpe, BUT the book runs net-long (+1 for three days,
#   -1 for two), so a chunk of that Sharpe is just equity beta, and 10 legs/week
#   gets chewed by costs. Verdict: a monitored timing overlay, not a standalone.
# NB: daily bars only, so the Wednesday-midday pivot is approximated by Wed close.
#   A true intraday version needs minute bars (a separate test).
# Read-only.
# =============================================================================
import os, sys, datetime as dt, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _blunt_common import bars, ann

lbl = ["Mon", "Tue", "Wed", "Thu", "Fri"]
print("=" * 70, "\nBLUNT #6 — intraweek seasonality\n" + "=" * 70)
for sym in ["SPY", "DIA", "QQQ"]:
    b = bars(sym); ds = sorted(b); c = np.array([b[d]["c"] for d in ds], float)
    r = c[1:] / c[:-1] - 1; ds = ds[1:]
    wd = np.array([dt.date.fromisoformat(d).weekday() for d in ds])
    means = "  ".join(f"{lbl[i]} {r[wd==i].mean()*1e4:+.1f}" for i in range(5))
    pos = np.where(np.isin(wd, [0, 1, 2]), 1.0, -1.0)     # long first half, short second half
    s, cg, dd = ann(pos * r)
    print(f"  {sym}: weekday avg (bp) {means}")
    print(f"        long-first/short-second: Sharpe {s:+.2f}  CAGR {cg*100:+.1f}%  maxDD {dd*100:.0f}%  (partly beta)")
print("\nVERDICT: marginal. The Thu/Fri weakness is genuine, but the tilt is net-long")
print("and cost-heavy. Monitor as an overlay; retest the real intraday pivot on")
print("minute bars before trusting it.")
