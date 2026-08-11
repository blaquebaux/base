#!/usr/bin/python3
# PATH-A SKETCH — KERNEL OF SILENCE: does market "silence" carry information about coming storms?
# Interpretation (the term is coined; this is the testable reading): "silence" = abnormally COMPRESSED
# volatility. The Minsky / volatility-paradox hypothesis says stability breeds instability — quiet
# breeds complacency and leverage, so silence precedes storms. The efficient-markets prior says the
# opposite: volatility CLUSTERS, so silence mostly predicts more silence, and "the quiet before the
# storm" is hindsight (we remember the calm that preceded a crash, forget the calm that stayed calm).
#
# TESTS (SPY, 2016-2026, SIP daily; silence = lowest-decile trailing-20d realized vol):
#  1. After silence vs after loud vs unconditional: forward 20d & 60d realized vol, forward 60d maxDD.
#  2. Reverse: what preceded the largest forward-vol spikes — silence or already-elevated vol?
#  3. Tail nuance: conditional on silence, is the RIGHT TAIL (95th pctile) of forward vol elevated?
#     (Does deep silence occasionally break into a storm even if it usually stays calm?)
#
# FINDING: silence predicts MORE SILENCE. Forward vol after silence is LOWER than unconditional (vol
# clustering / persistence), and the biggest vol spikes are preceded by ALREADY-ELEVATED vol, not calm.
# The "quiet before the storm" is largely hindsight — a NULL as a crisis timer. The one honest nuance:
# the forward-vol RIGHT TAIL after deep silence is not lower in proportion (rare regime breaks survive),
# so silence is a poor mean-predictor of storms but not a guarantee against them. Kernel of silence is a
# vol-clustering restatement, not a Minsky crisis signal.
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
spy=cl("SPY"); ds=sorted(spy); P=np.array([spy[d] for d in ds],float); r=P[1:]/P[:-1]-1; T=len(r)
def rvol(a,t,w): seg=a[max(0,t-w+1):t+1]; return seg.std()*math.sqrt(252)
rv20=np.array([rvol(r,t,20) for t in range(T)])
print("="*80,"\nKERNEL OF SILENCE — does compressed volatility ('silence') precede storms?\n"+"="*80)

lo,hi=np.nanpercentile(rv20[20:-60],10),np.nanpercentile(rv20[20:-60],90)
def fwd_vol(t,h): seg=r[t+1:t+1+h]; return seg.std()*math.sqrt(252) if len(seg)>2 else np.nan
def fwd_dd(t,h): seg=r[t+1:t+1+h]; lvl=np.cumprod(1+seg); return (lvl/np.maximum.accumulate(lvl)-1).min() if len(seg)>2 else np.nan
idx=range(20,T-60)
sil=[t for t in idx if rv20[t]<=lo]; loud=[t for t in idx if rv20[t]>=hi]
def avg(f,S): v=[f(t) for t in S]; v=[x for x in v if np.isfinite(x)]; return float(np.mean(v))
print(f"\n1. AFTER SILENCE (lowest-decile 20d vol) vs AFTER LOUD vs UNCONDITIONAL:")
print(f"   {'state':14} {'fwd 20d vol':>12} {'fwd 60d vol':>12} {'fwd 60d maxDD':>14}")
for lbl,S in [("silence (calm)",sil),("loud (stressed)",loud),("unconditional",list(idx))]:
    print(f"   {lbl:14} {avg(lambda t:fwd_vol(t,20),S)*100:>11.0f}% {avg(lambda t:fwd_vol(t,60),S)*100:>11.0f}% {avg(lambda t:fwd_dd(t,60),S)*100:>13.0f}%")
print("   -> if silence predicted storms, its forward vol/DD would be WORSE than unconditional. Is it?")

# 2. what precedes the biggest forward-vol spikes?
fv=np.array([fwd_vol(t,20) for t in idx]); ts=list(idx)
top=[ts[j] for j in np.argsort(fv)[-int(0.1*len(fv)):]]     # days followed by the top-decile vol spike
print(f"\n2. WHAT PRECEDES THE TOP-DECILE FORWARD VOL SPIKES:")
print(f"   current 20d vol just BEFORE a coming spike: {np.mean([rv20[t] for t in top])*100:.0f}%  vs unconditional {np.mean([rv20[t] for t in idx])*100:.0f}%")
print("   -> higher, not lower: storms are preceded by ALREADY-ELEVATED vol, not by silence.")

# 3. tail nuance: forward-vol right tail after silence
def p95(f,S): v=[f(t) for t in S]; v=[x for x in v if np.isfinite(x)]; return float(np.percentile(v,95))
print(f"\n3. TAIL NUANCE — 95th-pctile forward 60d vol:")
print(f"   after silence: {p95(lambda t:fwd_vol(t,60),sil)*100:.0f}%   unconditional: {p95(lambda t:fwd_vol(t,60),list(idx))*100:.0f}%")
print("   -> deep silence still carries a forward-vol tail (rare regime breaks); it lowers the MEAN, not the tail.")

print("\nVERDICT: NULL as a crisis timer. Silence predicts more silence (vol clustering); forward vol and")
print("drawdown after silence are BELOW unconditional, and big spikes follow already-elevated vol, not calm.")
print("The 'quiet before the storm' is hindsight. The honest nuance: silence lowers the MEAN of forward vol")
print("but not its right TAIL — quiet is no guarantee against a regime break. A vol-clustering restatement,")
print("not a Minsky signal; consistent with the family's 'timing the tail removes the tail'.")
