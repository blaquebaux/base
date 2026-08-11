#!/usr/bin/python3
# PATH-A SKETCH — MARKET TEMPERATURE / non-extensive (Tsallis) statistical mechanics.
# Econophysics models returns as a q-GAUSSIAN (Tsallis): a Gaussian generalized by the non-extensivity
# parameter q. q=1 is Gaussian (extensive); q>1 gives power-law fat tails (non-extensive). The
# SUPERSTATISTICS view (Beck-Cohen): the fat tails arise because the "temperature" (the variance) is
# itself a FLUCTUATING, rough quantity — returns are Gaussian conditional on a temperature that wanders.
# Estimate q from the excess kurtosis of a q-Gaussian:
#     kappa = 6(q-1)/(5-3q)   ->   q = (5*kappa + 6) / (3*kappa + 6)   (q -> 1 as kappa -> 0; -> 5/3 as kappa -> inf)
#
# TESTS (SPY + spine, 2016-2026, SIP daily):
#  1. q per asset from daily returns (q>1 = non-extensive, fat-tailed).
#  2. Aggregation "cooling": q at 1d / 5d / 21d horizons -> q should fall toward 1 (CLT / extensivity).
#  3. Superstatistics: standardize each return by its CONTEMPORANEOUS temperature (same-day Parkinson
#     range vol, which sees the day's own volatility incl. jumps). If fat tails are a temperature effect,
#     the standardized returns collapse toward Gaussian (q -> 1).
#
# FINDING: markets are non-extensive (daily q ~ 1.32-1.58); q cools toward 1 under aggregation (SPY
# 1.58 @1d -> 1.16 @21d); and dividing by the contemporaneous temperature collapses q toward 1 for most
# assets (SPY 1.58->1.00, GLD 1.53->1.18, DBC 1.45->1.24, IEF 1.41->1.18, DBA 1.32->1.00). Honest
# exception: TLT stays high (1.48->1.56) because bonds GAP overnight on macro/FOMC news — a jump the
# same-day high-low range can't see. Net: the fat tails are overwhelmingly a temperature-fluctuation
# (rough-vol) effect, with a residual from overnight jumps. "Market temperature" is the same rough-vol /
# GARCH state in thermodynamic dress; the tails (and the negentropy we harvest) are its footprint.
#
# RESULTS AS TESTED (2016-2026): daily q SPY 1.58 IEF 1.41 TLT 1.48 GLD 1.53 DBC 1.45 DBA 1.32;
#   aggregation SPY q 1.58/1.53/1.16 @ 1/5/21d; temperature-standardized q ~1.0-1.24 (TLT 1.56, gaps).
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
H_={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def bars(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H_),timeout=40)).get("bars",{}).get(s,[])
def exkurt(x): x=np.asarray(x,float); m=x.mean(); s=x.std(); return float(np.mean((x-m)**4)/s**4-3) if s>0 else 0.0
def tsallis_q(x):
    k=max(exkurt(x),0.0)                                 # q-Gaussian kurtosis is >=0 (leptokurtic)
    return (5*k+6)/(3*k+6)                               # invert kappa=6(q-1)/(5-3q); saturates at 5/3
SPINE=["SPY","IEF","TLT","GLD","DBC","DBA"]
B={s:bars(s) for s in SPINE}
def closes(s): return {x["t"][:10]:x["c"] for x in B[s]}
def parkvol(s): return {x["t"][:10]: math.sqrt(max((math.log(x["h"]/x["l"]))**2/(4*math.log(2)),1e-12))
                        for x in B[s] if x["h"]>0 and x["l"]>0 and x["h"]>=x["l"]}
C={s:closes(s) for s in SPINE}; ds=sorted(set.intersection(*[set(v) for v in C.values()]))
M=np.array([[C[s][d] for s in SPINE] for d in ds],float); R=np.log(M[1:]/M[:-1]); i={s:SPINE.index(s) for s in SPINE}
print("="*80,"\nMARKET TEMPERATURE — non-extensive (Tsallis q) statistics of returns\n"+"="*80)

print("\n1. TSALLIS q (from daily excess kurtosis; q=1 Gaussian, q>1 non-extensive fat tails):")
for s in SPINE:
    r=R[:,i[s]]; print(f"   {s:5s} excess-kurtosis {exkurt(r):6.1f}   ->  q = {tsallis_q(r):.3f}")

def agg(r,k): return np.array([r[j:j+k].sum() for j in range(0,len(r)-k+1,k)])   # non-overlapping k-day sums
print("\n2. AGGREGATION COOLING — q as returns are summed over longer horizons (SPY):")
spy=R[:,i["SPY"]]
for k in (1,5,21):
    print(f"   {k:>2}-day returns: excess-kurtosis {exkurt(agg(spy,k)):6.1f}   ->  q = {tsallis_q(agg(spy,k)):.3f}")
print("   -> q falls toward 1 as shocks add up (CLT): the non-extensivity is a SHORT-horizon effect.")

print("\n3. SUPERSTATISTICS — divide each return by its CONTEMPORANEOUS temperature (same-day Parkinson vol):")
print(f"   {'asset':5} {'q raw':>7} {'q temperature-standardized':>28}")
for s in SPINE:
    pv=parkvol(s); dd=[d for d in ds[1:] if d in pv]                      # align returns to same-day range vol
    rr=np.array([math.log(C[s][d]/C[s][ds[ds.index(d)-1]]) for d in dd]); tv=np.array([pv[d] for d in dd])
    z=rr/tv; z=z[np.isfinite(z)]
    print(f"   {s:5} {tsallis_q(R[:,i[s]]):>7.3f} {tsallis_q(z):>28.3f}")
print("   -> dividing by the day's own temperature collapses q toward 1: the fat tails are a")
print("      TEMPERATURE-FLUCTUATION (rough-vol) effect, not intrinsic to the conditional shock.")

print("\nVERDICT: markets are non-extensive (Tsallis q>1, q-Gaussian fat tails); q COOLS toward 1 under")
print("aggregation (CLT); and dividing by the contemporaneous 'temperature' (rough, fluctuating vol)")
print("recovers near-Gaussianity. Market temperature is a real fluctuating quantity — the same rough-vol /")
print("GARCH state in thermodynamic dress; the fat tails (and the negentropy we harvest) are its footprint.")
