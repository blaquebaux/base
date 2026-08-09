#!/usr/bin/python3
# =============================================================================
# blunt_6_intraweek.py — BLAQUE BAUX BLUNT #6.
#
# PROPOSED: go long from the start of the week (Sun night / Mon open) through
#   Wednesday ~midday, then SHORT from Wednesday ~midday into Friday's close.
#
# TESTED TWO WAYS:
#   (a) daily-close approximation (fast, Wed-close as the pivot): Sharpe +0.34..+0.84,
#       but the book runs net-long so much of that is just equity beta.
#   (b) the REAL intraday version (hourly SIP bars, Wed ~noon pivot, 396 weeks
#       2019-2026, net ~1bp/side) — the honest test:
#
#     index   proposed long-first/short-second     benchmark: just hold Mon->Fri
#     SPY     Sharpe +0.55  CAGR +7.6%  DD -26%     Sharpe +1.03  CAGR +16.3%
#     QQQ     Sharpe +0.72  CAGR +13.2% DD -39%     Sharpe +1.06  CAGR +21.3%
#     DIA     Sharpe +0.50  CAGR +6.6%  DD -25%     Sharpe +0.87  CAGR +12.9%
#
#     leg A Mon->Wed-noon: +23..+37 bp/wk (strong)
#     leg B Wed-noon->Fri: +4.6..+6.5 bp/wk (weaker but still POSITIVE)
#
# FINDING: the proposed strategy is DOMINATED by simply holding the week — worse
#   Sharpe, worse return, deeper drawdown, on every index. The reason is the same
#   trap as #1/#2/#5: leg B still has a POSITIVE drift, so SHORTING the back half
#   of the week fights the equity risk premium. The real signal is only that the
#   first half is stronger than the second — a long-only *tilt* at best (heavier
#   early week, lighter/flat late week), never a short, and even the tilt has to
#   clear the high bar of just staying long. Verdict: monitored curiosity, not a
#   sleeve; NOT a promotion candidate.
#
# This sketch runs the real intraday test (fetches hourly bars — slower, ~1-2 min).
# Reads ALPACA_KEY_ID / ALPACA_SECRET_KEY from env. Read-only.
# =============================================================================
import os, sys, json, urllib.request, math, datetime as dt
from collections import defaultdict
import numpy as np

H = {"APCA-API-KEY-ID": os.environ["ALPACA_KEY_ID"], "APCA-API-SECRET-KEY": os.environ["ALPACA_SECRET_KEY"]}
START, END = "2019-01-01", "2026-08-01"
COST = 1.0 / 1e4       # 1 bp/side (liquid index ETF)

def fetch_hourly(sym):
    out = []; tok = None
    while True:
        u = (f"https://data.alpaca.markets/v2/stocks/bars?symbols={sym}&timeframe=1Hour"
             f"&start={START}&end={END}&adjustment=all&feed=sip&limit=10000")
        if tok: u += f"&page_token={tok}"
        d = json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=60))
        out += d.get("bars", {}).get(sym, [])
        tok = d.get("next_page_token")
        if not tok: break
    return out

def et(ts):   # RFC3339 UTC -> ET-ish (fixed -4; only the hour bucket for the noon pivot matters)
    z = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return z.astimezone(dt.timezone(dt.timedelta(hours=-4)))

def daymap(bars):
    byday = defaultdict(list)
    for b in bars:
        e = et(b["t"])
        if 9 <= e.hour <= 16: byday[e.date()].append((e.hour, e.minute, b["o"], b["c"]))
    D = {}
    for day, rows in byday.items():
        rows.sort()
        noon = next((o for h, m, o, c in rows if h >= 12), rows[-1][3])
        D[day] = dict(open=rows[0][2], close=rows[-1][3], noon=noon)
    return D

def weeks(D):
    W = defaultdict(list)
    for day in sorted(D): W[day.isocalendar()[:2]].append(day)
    return W

def ann_w(r):
    r = np.asarray(r, float); r = r[np.isfinite(r)]
    if len(r) < 10 or r.std() == 0: return (float('nan'),) * 3
    cum = np.cumprod(1 + r)
    return (r.mean() / r.std() * math.sqrt(52), cum[-1] ** (52 / len(r)) - 1,
            (cum / np.maximum.accumulate(cum) - 1).min())

def run(sym):
    D = daymap(fetch_hourly(sym)); W = weeks(D)
    ls = []; longonly = []; A = []; B = []
    for wk, days in sorted(W.items()):
        if len(days) < 3: continue
        first, last = days[0], days[-1]
        wed = [d for d in days if d.weekday() == 2]
        piv = wed[0] if wed else days[len(days) // 2]
        e, p, x = D[first]["open"], D[piv]["noon"], D[last]["close"]
        if not (e and p and x): continue
        r1 = p / e - 1; r2 = (p - x) / p                 # long first half; short second half
        ls.append((1 + r1) * (1 + r2) - 1 - 4 * COST)    # 4 units turnover/wk (enter, flip, exit)
        longonly.append(x / e - 1 - 2 * COST)
        A.append(r1); B.append(x / p - 1)
    s, c, d = ann_w(ls); s2, c2, _ = ann_w(longonly)
    print(f"\n{sym}: {len(ls)} weeks")
    print(f"  PROPOSED long-first/short-second (NET): Sharpe {s:+.2f}  CAGR {c*100:+.1f}%  maxDD {d*100:.0f}%")
    print(f"  BENCHMARK just hold Mon->Fri (NET):     Sharpe {s2:+.2f}  CAGR {c2*100:+.1f}%   <- dominates")
    print(f"  leg A Mon->Wed-noon avg {np.mean(A)*1e4:+.1f}bp | leg B Wed-noon->Fri avg {np.mean(B)*1e4:+.1f}bp (positive; proposal shorts it)")

if __name__ == "__main__":
    print("=" * 70, "\nBLUNT #6 — intraweek seasonality (REAL intraday test)\n" + "=" * 70)
    for s in ["SPY", "QQQ", "DIA"]:
        run(s)
    print("\nVERDICT: rejected as proposed. Shorting the back half fights a positive")
    print("drift, so the strategy loses to simply holding the week. First-half strength")
    print("is real but only supports a LONG tilt, not a short. Monitor; do not promote.")
