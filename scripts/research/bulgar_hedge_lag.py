#!/usr/bin/python3
# PATH-A SKETCH — BULGAR (narrowed): the corn/soy INGREDIENT PROCESSORS (Ingredion & the like — INGR/ADM/BG),
# the layer that buys grain and sells corn syrup/starch/oil to the food manufacturers, and the FUTURES-HEDGING
# LAG mechanism. Ex-Ingredion thesis: processors buy corn/soy FORWARD, so the grain's effect on their MARGIN
# (and stock) should appear at a LAG — old cheap hedges roll off, margin re-prices, and they bake the increase
# into the NEXT hedge. That predicts (a) they are LONG the grain, and (b) grain MOMENTUM should PREDICT forward
# processor returns with a delay whose strength grows with horizon (the hedge-roll signature). Grain = CORN+SOYB
# ETFs; the goods they supply = BRANDED food (KO/PEP/GIS/K/MDLZ). SIP daily, 2016-2026.
#
# FINDING — the mechanism is REAL and directionally CONFIRMED (unlike the reversed tier-gradient in
# bulgar_supply_chain.py), but the tradeable edge is WEAK — a near-miss, not a keeper:
#  1. They ARE (mildly) long the grain: corr(processors, grain) +0.16, beta-to-grain +0.22, corr-DBA +0.21.
#  2. THE HEDGING LAG IS VISIBLE: grain trailing momentum POSITIVELY predicts forward processor returns, and
#     the correlation GROWS with the lag/horizon (126d grain trend -> processor next-126d corr +0.15 vs +0.03
#     at 5d) — exactly the hedge-roll delay signature, not a contemporaneous co-move.
#  3. TRADING IT: buying processors after grain has been rising is consistently POSITIVE (Sharpe up to +0.25 at
#     L=126/F=21) and shorting-grain-momentum is consistently NEGATIVE — the SIGN is right in every cell.
#  4. BUT the raw basket's +0.42 Sharpe is ENTIRELY MARKET BETA (0.69): SPY-hedge it and always-long goes to
#     -0.14 (no standalone alpha). The only market-neutral edge is the grain-momentum-TIMED version — best is
#     long-processors / short-BRANDED (the pass-through spread) timed on grain momentum: Sharpe +0.25, beta 0.00,
#     but in-market only 38% of the time and still -36% maxDD.
#
# VERDICT: NEAR-MISS null. Narrowing to the corn/soy processors + the hedging lag turned the branded thesis
# from REVERSED (bulgar_supply_chain.py) into DIRECTIONALLY CORRECT: they're long the crush margin, grain
# momentum leads them, and long-processor/short-branded is the right expression. But at +0.25 market-neutral
# Sharpe, 38% in-market, -36% DD it is below keeper bar as a standalone sleeve — the honest edge is a weak,
# conditional overlay, and the raw basket is pure beta. Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
PROC=["INGR","ADM","BG"]                      # corn/soy wet-milling & oilseed crush — buy grain forward, sell ingredients
GRAIN=["CORN","SOYB"]                         # the inputs they hedge
BRAND=["KO","PEP","GIS","K","MDLZ"]           # the branded manufacturers they supply
SY=PROC+GRAIN+BRAND+["DBA","SPY"]; D={s:cl(s) for s in SY}
ds=sorted(set.intersection(*[set(v) for v in D.values()])); M=np.array([[D[s][d] for s in SY] for d in ds],float)
R=M[1:]/M[:-1]-1; i={s:SY.index(s) for s in SY}; T=len(R); spy=R[:,i["SPY"]]
proc=np.mean([R[:,i[s]] for s in PROC],0); brand=np.mean([R[:,i[s]] for s in BRAND],0)
grain=np.mean([R[:,i[s]] for s in GRAIN],0); gl=np.cumprod(1+grain)
def met(r,per=252): r=r[np.isfinite(r)]; s=r.std(); lvl=np.cumprod(1+r); return (r.mean()/s*math.sqrt(per) if s>0 else float('nan'), lvl[-1]**(per/len(r))-1,(lvl/np.maximum.accumulate(lvl)-1).min())
def cor(a,b): m=np.isfinite(a)&np.isfinite(b); return float(np.corrcoef(a[m],b[m])[0,1])
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())
print("="*84,"\nBULGAR (narrowed) — corn/soy ingredient processors (INGR/ADM/BG) & the futures-HEDGING lag\n"+"="*84)

print("\n1. ARE THEY LONG THE GRAIN? (contemporaneous)")
m=met(proc); print(f"  processor basket: Sharpe {m[0]:+.2f} CAGR {m[1]*100:+.0f}% maxDD {m[2]*100:+.0f}%  beta-SPY {beta(proc,spy):+.2f}")
print(f"  corr(processors, grain) {cor(proc,grain):+.2f}   beta-to-grain {beta(proc,grain):+.2f}   corr(processors, DBA) {cor(proc,R[:,i['DBA']]):+.2f}")

print("\n2. THE HEDGING LAG — grain MOMENTUM (trailing L days) vs processor NEXT F-day return (the core test)")
hdr="L\\F"; print(f"   {hdr:>6s}"+"".join(f"{f'+{F}d':>9s}" for F in (5,21,63,126))+"   (corr grows with lag = hedge-roll)")
for L in (21,63,126):
    row=f"   {L:>4d}d "
    for F in (5,21,63,126):
        xs=[];ys=[]
        for t in range(L,T-F):
            gm=gl[t]/gl[t-L]-1; fr=np.prod(1+proc[t:t+F])-1
            if np.isfinite(gm) and np.isfinite(fr): xs.append(gm); ys.append(fr)
        row+=f"{np.corrcoef(xs,ys)[0,1]:+9.2f}"
    print(row)

print("\n3. TRADE THE LAG — long vs short processors on grain momentum, held F days (net 5bp)")
cost=5/1e4
for L in (63,126):
    for F in (21,63):
        a=[];b=[]; t=L
        while t<T-1:
            gm=gl[t]/gl[t-L]-1; hz=min(F,T-1-t); r=float(np.prod(1+proc[t:t+hz])-1)
            a.append((1 if gm>0 else -1)*r-2*cost); b.append((-1 if gm>0 else 1)*r-2*cost); t+=F
        a=np.array(a); b=np.array(b); per=252/F
        sa=a.mean()/a.std()*math.sqrt(per) if a.std()>0 else float('nan'); sb=b.mean()/b.std()*math.sqrt(per) if b.std()>0 else float('nan')
        print(f"  L={L:>3d}d F={F:>2d}d:  long-grain-momentum Sharpe {sa:+.2f}  |  short-grain-momentum Sharpe {sb:+.2f}  (n={len(a)})")

print("\n4. IS THERE A MARKET-NEUTRAL SLEEVE? (the raw basket is mostly beta) — daily hold, causal")
bP=beta(proc,spy)
def build(hedge=None, timed=True, L=126):
    pnl=[]
    for t in range(L,T-1):
        pos=1.0 if (gl[t]/gl[t-L]-1>0 or not timed) else 0.0; r=proc[t+1]
        if hedge=="spy": r=r-bP*spy[t+1]
        if hedge=="brand": r=r-(proc[:t].std()/brand[:t].std() if t>30 else 1.0)*brand[t+1]
        pnl.append(pos*r)
    return np.array(pnl)
for lbl,h,tm in [("processors raw (long always)",None,False),("processors SPY-hedged (long always)","spy",False),
                 ("processors SPY-hedged, grain-mom timed","spy",True),("long proc/short BRANDED (pass-through)","brand",False),
                 ("long proc/short BRANDED, grain-mom timed","brand",True)]:
    p=build(h,tm); s=met(p); print(f"  {lbl:42s} Sharpe {s[0]:+.2f}  CAGR {s[1]*100:+4.0f}%  maxDD {s[2]*100:+4.0f}%  beta {beta(p,spy[126:126+len(p)]):+.2f}  inmkt {(p!=0).mean()*100:.0f}%")

print("\nVERDICT: NEAR-MISS null. The hedging-lag mechanism is REAL — they're long the grain, grain momentum leads")
print("their forward returns with a delay that grows with horizon (hedge-roll signature), and long-processor/")
print("short-branded timed on grain momentum is the right, sign-correct expression. But at +0.25 market-neutral")
print("Sharpe (38% in-market, -36% DD) it is below keeper bar; the raw basket's +0.42 is pure market beta. The")
print("narrowing fixed the DIRECTION (vs the reversed tier-gradient) but the edge is a weak conditional overlay.")
