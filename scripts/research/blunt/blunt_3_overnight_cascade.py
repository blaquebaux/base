#!/usr/bin/python3
# =============================================================================
# blunt_3_overnight_cascade.py — BLAQUE BAUX BLUNT #3.
#
# PROPOSED: Asian-session moves lead Europe and the US; a chip bellwether jumping
#   overnight should cascade to US semis the next day (supply-chain read-through).
# FINDING:  the cascade is priced INSTANTLY, so there is nothing to trade the next
#   day. Overnight gaps do not predict the same-day US session (corr ~0); a Taiwan
#   Semi (TSM) overnight gap co-moves with US semis SAME day only (tiny corr), and
#   its NEXT-day correlation to SMH/NVDA is ~0/negative. Same law we found in the
#   correlation study: cross-name read-through is in the price the same day.
# NB: Alpaca lists US ETFs that trade in US hours, so a true Asian-hours index
#   signal is not directly testable here; the overnight-gap and TSM-ADR channels
#   are the tradeable proxies, and both say "already priced."
# Read-only.
# =============================================================================
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _blunt_common import bars, panel, ann

def oc(sym):
    b = bars(sym); ds = sorted(b)
    o = np.array([b[d]["o"] for d in ds], float); c = np.array([b[d]["c"] for d in ds], float)
    return ds[1:], o[1:] / c[:-1] - 1, c[1:] / o[1:] - 1     # dates, overnight, intraday

print("=" * 70, "\nBLUNT #3 — overnight / Asia / chip-supply cascade\n" + "=" * 70)
for sym in ["SPY", "QQQ"]:
    ds, ov, intr = oc(sym)
    print(f"  {sym}: corr(overnight gap, same-day intraday) {np.corrcoef(ov, intr)[0,1]:+.3f} | "
          f"follow-the-gap intraday Sharpe {ann(np.sign(ov)*intr)[0]:+.2f}")
# TSM overnight gap -> SOXX same-day intraday
dT, ovT, _ = oc("TSM"); dX, _, iX = oc("SOXX")
it = {d: k for k, d in enumerate(dT)}; ix = {d: k for k, d in enumerate(dX)}
common = sorted(set(dT) & set(dX))
a = np.array([ovT[it[d]] for d in common]); b = np.array([iX[ix[d]] for d in common])
print(f"  TSM overnight gap -> SOXX same-day intraday: corr {np.corrcoef(a,b)[0,1]:+.3f} (tiny)")
# next-day cascade
u, dts, M = panel(["TSM", "SMH", "NVDA"]); r = M[1:] / M[:-1] - 1; i = {s: u.index(s) for s in u}
for nm in ["SMH", "NVDA"]:
    print(f"  TSM today -> {nm} NEXT day: corr {np.corrcoef(r[:-1,i['TSM']], r[1:,i[nm]])[0,1]:+.3f}  (~0 => priced in)")
print("\nVERDICT: rejected. The cascade is real but instantaneous; there is no")
print("next-day edge to harvest. Correlation here is a RISK fact, not alpha.")
