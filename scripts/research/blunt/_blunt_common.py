#!/usr/bin/python3
# =============================================================================
# _blunt_common.py — shared data/metrics helpers for the Blaque Baux Blunt sketches.
# Alpaca SIP daily bars; reads ALPACA_KEY_ID / ALPACA_SECRET_KEY from env. Read-only.
# =============================================================================
import os, json, urllib.request, math
import numpy as np

H = {"APCA-API-KEY-ID": os.environ["ALPACA_KEY_ID"], "APCA-API-SECRET-KEY": os.environ["ALPACA_SECRET_KEY"]}
START, END = "2016-01-01", "2026-08-01"
_cache = {}

# A liquid, sector-diversified S&P basket for the cross-sectional sketches.
# NOTE: current constituents => mild survivorship bias; results are directional.
BASKET = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","V","MA","UNH",
"HD","PG","XOM","JNJ","COST","WMT","BAC","KO","PEP","CVX","MRK","ABBV","CRM","ADBE",
"NFLX","AMD","INTC","QCOM","TXN","ORCL","CSCO","PFE","TMO","NKE","DIS","WFC","GS","MS",
"CAT","BA","GE","HON","LMT"]

def bars(s):
    if s in _cache: return _cache[s]
    u = (f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day"
         f"&start={START}&end={END}&adjustment=all&feed=sip&limit=10000")
    try:
        d = json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=40))
        _cache[s] = {b["t"][:10]: b for b in d.get("bars", {}).get(s, [])}
    except Exception:
        _cache[s] = {}
    return _cache[s]

def panel(syms, field="c"):
    D = {s: bars(s) for s in syms}; D = {s: v for s, v in D.items() if len(v) > 500}
    used = list(D); dates = sorted(set.intersection(*[set(D[s]) for s in used]))
    M = np.array([[D[s][d][field] for s in used] for d in dates], float)
    return used, dates, M

def ann(pnl):
    r = np.asarray(pnl, float); r = r[np.isfinite(r)]
    if len(r) < 30 or r.std() == 0: return (float('nan'),) * 3
    cum = np.cumprod(1 + r)
    return (r.mean() / r.std() * math.sqrt(252),
            cum[-1] ** (252 / len(r)) - 1,
            (cum / np.maximum.accumulate(cum) - 1).min())

def trailing_z(x, w):
    z = np.full(len(x), np.nan)
    for t in range(w, len(x)):
        seg = x[t - w:t]; sd = seg.std()
        if sd > 0: z[t] = (x[t] - seg.mean()) / sd
    return z

def quantile_legs(score, R, frac=0.2):
    """For a per-day score matrix (T,N) aligned to forward returns R (T,N),
       return dict of daily P&L series for the quantile legs, all sign-normalized
       as the *return earned*:
         long_bottom / long_top  : long that quantile (next-day)
         short_bottom/ short_top : short that quantile
         mkt                     : equal-weight all names (the 'beta')
       plus beta-neutral versions (leg - mkt)."""
    T, N = R.shape; k = max(1, int(N * frac))
    lb=[]; lt=[]; mk=[]
    for t in range(T - 1):
        s = score[t]; m = np.isfinite(s)
        if m.sum() < 2 * k:
            lb.append(np.nan); lt.append(np.nan); mk.append(np.nan); continue
        order = np.argsort(np.where(m, s, np.nan))
        bot = order[:k]; top = order[-k:]; fwd = R[t + 1]
        lb.append(np.nanmean(fwd[bot])); lt.append(np.nanmean(fwd[top])); mk.append(np.nanmean(fwd[m]))
    lb=np.array(lb); lt=np.array(lt); mk=np.array(mk)
    return dict(long_bottom=lb, long_top=lt, short_bottom=-lb, short_top=-lt, mkt=mk,
                long_bottom_neutral=lb-mk, long_top_neutral=lt-mk)

def load_basket():
    used, dts, C = panel(BASKET)
    R = C[1:] / C[:-1] - 1
    return used, dts, C, R
