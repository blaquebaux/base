#!/usr/bin/python3
# PATH-A SKETCH — NULL PAIRS: can the un-salvageable nulls be rescued by pairing them LONG one / SHORT
# another? The idea (a long-short SPREAD nets out the common beta and isolates the RELATIVE bet) is
# sound — and it is exactly the brown/blue camp-rotation KEEPER (long one camp / short the other,
# value-vs-growth, rotated ~+0.85). This tests whether it works for the REMAINING nulls, proxied by
# liquid ETFs: bulk=ITA, bubble=SMH, basel=KBE, bio=XBI, emea=VGK, latam=ILF. Vol-matched spreads,
# static and trend-rotated (rotate long onto the stronger 126d trend), net of cost, 2016-2026.
#
# FINDING: pairing reduces beta (the spreads are ~market-neutral, β ~0 — as intended) but does NOT
# manufacture alpha for these nulls.
#  - The STATIC spreads look good (long bubble/SMH − anything = +0.58..0.70 Sharpe) but that is
#    HINDSIGHT: SMH (AI/semis) was the decade's winner, so "always long the eventual winner" is not a
#    tradeable ex-ante edge — it is a permanent bet on the name that happened to win.
#  - The causally-tradeable ROTATED spreads (rotate by relative momentum, no hindsight) are ~0 — best
#    +0.13, most NEGATIVE (-0.2 to -0.36): relative momentum between these undifferentiated sector/region
#    betas whipsaws. You cannot pair your way to alpha from two exposures that share the same factor.
#  - It works ONLY when the pair straddles a REAL, persistent, trend-able factor axis (value vs growth =
#    brown/blue camp rotation, +0.85). The remaining nulls don't sit on such an axis, so their spreads
#    are hindsight-static or noise-when-rotated.
#
# RESULTS AS TESTED (2016-2026): best static +0.70 (bubble−bio, hindsight); best ROTATED +0.13
#   (bubble−emea, β -0.06); most rotated pairs negative; single best null long-only +1.06 (SMH, hindsight).
#
# VERDICT: the mechanism is sound and already realized (camp rotation) — but a long-short of two
# undifferentiated betas is market-neutral NOISE, not alpha. Beta is lost as expected; alpha is not
# gained. Pairing helps only across a genuine factor, which the family already harvests. Keys from env.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
NULL={"bulk(defense)":"ITA","bubble(AI/semis)":"SMH","basel(banks)":"KBE","bio(biotech)":"XBI",
      "emea(europe)":"VGK","latam(LatAm)":"ILF"}
syms=list(NULL.values())+["SPY"]; D={s:cl(s) for s in syms}
ds=sorted(set.intersection(*[set(v) for v in D.values()])); M=np.array([[D[s][d] for s in syms] for d in ds],float)
R=M[1:]/M[:-1]-1; i={s:syms.index(s) for s in syms}; T=len(R); spy=R[:,i["SPY"]]
def sh(x): x=x[np.isfinite(x)]; return x.mean()/x.std()*math.sqrt(252) if x.std()>0 else float('nan')
def beta(x, sp): m=np.isfinite(x)&np.isfinite(sp); return float(np.cov(x[m],sp[m])[0,1]/sp[m].var()) if m.sum()>10 else 0.0
names=list(NULL); tick=list(NULL.values()); LOOK=126
sig={t: R[:,i[t]].std() for t in tick}
leg=lambda a,b: R[:,i[a]] - (sig[a]/sig[b])*R[:,i[b]]        # long a, short b (vol-matched, real units)
print("="*82,"\nNULL PAIRS — long one un-salvageable null / short another (vol-matched spread)\n"+"="*82)
def rotated(a,b,look=LOOK,reb=21,cost=2.0):
    la=np.cumprod(1+R[:,i[a]]); lb=np.cumprod(1+R[:,i[b]]); sp=leg(a,b); s=0.0; pnl=[]; c=cost/1e4
    for t in range(look,T-1):
        (t-look)%reb==0 and (s:=1.0 if (la[t]/la[t-look]-1)>=(lb[t]/lb[t-look]-1) else -1.0)
        pnl.append(s*sp[t+1] - (2*c if (t-look)%reb==0 else 0.0))
    return np.array(pnl)
rows=[]
for x in range(len(tick)):
    for y in range(x+1,len(tick)):
        a,b=tick[x],tick[y]; st=leg(a,b); ro=rotated(a,b); sp_ro=spy[LOOK+1:LOOK+1+len(ro)]
        rows.append((f"{names[x].split('(')[0]}−{names[y].split('(')[0]}", sh(st), beta(st,spy), sh(ro), beta(ro,sp_ro)))
rows.sort(key=lambda r:-abs(r[1]))
print(f"\n  {'pair (long − short)':22s} {'static Sh':>10s} {'β':>6s}   {'rotated Sh':>11s} {'β':>6s}")
for nm,ss,sb,rs,rb in rows: print(f"  {nm:22s} {ss:+10.2f} {sb:+6.2f}   {rs:+11.2f} {rb:+6.2f}")
best=max(rows,key=lambda r:r[3])
print(f"\n  best static (long − short): {rows[0][0]} {rows[0][1]:+.2f}  — but HINDSIGHT (long the decade's winner)")
print(f"  best ROTATED (causal, tradeable): {best[0]} {best[3]:+.2f}  β {best[4]:+.2f}  — ~0; most pairs negative")
print(f"  single best null on its own (long-only): {max(sh(R[:,i[t]]) for t in tick):+.2f}  (SMH, β~1, also hindsight)")
print("\nVERDICT: pairing reduces BETA (spreads ~market-neutral) but does NOT gain ALPHA for these nulls —")
print("static spreads are hindsight (long the eventual winner), rotated spreads are ~0/negative. A long-short")
print("of two undifferentiated betas is market-neutral NOISE. It pays only across a REAL factor axis (value")
print("vs growth = the brown/blue camp-rotation keeper, +0.85), which the family already harvests.")
