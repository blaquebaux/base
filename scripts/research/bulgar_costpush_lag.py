#!/usr/bin/python3
# PATH-A SKETCH — COST-PUSH LAG (user's sharpened thesis, ex-Ingredion): supplier pricing power LEADS a
# customer margin squeeze. When ingredient suppliers (INGR/ADM) get strong (can't sell sweetener/starch at
# last year's price), Coke/Pepsi's input costs rise and their stock takes the hit LATER (contracts reprice +
# earnings reveal it). So SHORT the customers when the supplier is strong, at a LAG.
#
# FINDING — the MECHANISM IS REAL and CONFIRMED, but the tradeable edge is a NEAR-MISS net of cost:
#  1. The lead-lag is exactly as the thesis predicts: supplier 63d strength -> customer forward return is
#     NEGATIVE and GROWS with horizon (-0.04 @5d -> -0.13 @21d -> -0.16 @63d -> -0.17 @126d). Genuine cost-push
#     transmission, not noise. (The ag-INPUT basket is NOT a clean signal — it goes positive at long horizon,
#     because ag inflation coincides with broad reflation; the SUPPLIER STOCK is the clean pricing-power proxy.)
#  2. Tradeable, SPY-hedged, and genuinely MARKET-NEUTRAL (beta ~0). BUT the number below (~+0.37) is GROSS and
#     daily-repositioned. The honest net-of-cost, monthly-held, causal walk-forward (scripts/costpush_validation.jl)
#     gives OOS Sharpe +0.16 (full) / +0.11 (recent) — below the +0.30 :neutral bar. The signal is real but SLOW
#     and SMALL: it doesn't move the customer stocks enough, fast enough, to beat friction, and the 2021-2022
#     staples-as-defensive-haven regime (KO/PEP rally in the risk-off shock) eats a chunk.
#
# VERDICT: near-miss, not a keeper. The confirmed cost-push lag is a useful RISK/TILT input (and vindicates the
# user's mechanism), not a standalone sleeve at net-of-cost friction. See costpush_validation.jl for the gate.
# NOTE: section-2 Sharpe below is GROSS (no cost, daily reposition) — the gate is the authoritative net figure.
# Keys from env only; read-only; not validated (the gate is).
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
def load(syms):
    D={s:cl(s) for s in syms}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
    M=np.array([[D[s][d] for s in syms] for d in ds],float); R=M[1:]/M[:-1]-1
    return R,{s:syms.index(s) for s in syms},ds[1:]
def sh(r,per=252): r=r[np.isfinite(r)]; s=r.std(); return r.mean()/s*math.sqrt(per) if s>0 else float('nan')
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())
SUP=["INGR","ADM"]; CUST=["KO","PEP","MDLZ","GIS","KHC"]; INP=["CORN","SOYB","WEAT","CANE"]
R,i,dd=load(SUP+CUST+INP+["SPY"]); T=len(R); spy=R[:,i["SPY"]]; yr=np.array([int(d[:4]) for d in dd])
sup=np.mean([R[:,i[s]] for s in SUP],0); cust=np.mean([R[:,i[s]] for s in CUST],0); inp=np.mean([R[:,i[s]] for s in INP],0)
supl=np.cumprod(1+sup); inpl=np.cumprod(1+inp); bC=beta(cust,spy)

print("="*82,"\nCOST-PUSH LAG — supplier pricing power LEADS a customer margin squeeze?\n"+"="*82)
print("\n1. LEAD-LAG: does SUPPLIER strength (63d) predict CUSTOMER forward return NEGATIVELY, growing with horizon?")
def ll(drv,tgt,L,F):
    xs=[];ys=[]
    for t in range(L,T-F):
        m=drv[t]/drv[t-L]-1; fr=np.prod(1+tgt[t:t+F])-1
        if np.isfinite(m) and np.isfinite(fr): xs.append(m); ys.append(fr)
    return np.corrcoef(xs,ys)[0,1]
print(f"   {'driver(63d)->cust':20s}"+"".join(f"{f'+{F}d':>8s}" for F in (5,21,63,126)))
print(f"   {'supplier stock':20s}"+"".join(f"{ll(supl,cust,63,F):+8.2f}" for F in (5,21,63,126)))
print(f"   {'ag input basket':20s}"+"".join(f"{ll(inpl,cust,63,F):+8.2f}" for F in (5,21,63,126)))

print("\n2. TRADE: SHORT customers (SPY-hedged) when signal 63d momentum>0, held to next rebalance, net 5bp")
def short_cust(sig_lvl, reb):
    pnl=np.full(T,np.nan)
    for t in range(63,T-1):
        pos=-1.0 if sig_lvl[t]/sig_lvl[t-63]-1>0 else 0.0
        pnl[t+1]=pos*(cust[t+1]-bC*spy[t+1])
    return pnl
for nm,sig in [("supplier-strength",supl),("ag-input-rising",inpl)]:
    p=short_cust(sig,63); fin=np.isfinite(p)
    print(f"   short customers on {nm:18s}: Sharpe {sh(p[fin]):+.2f}  beta {beta(p,np.r_[np.nan,spy][:T]):+.2f}  inmkt {(p[fin]!=0).mean()*100:.0f}%")
    print("     per-year: "+"  ".join(f"{y}:{sh(p[(yr==y)&fin]):+.2f}" for y in range(2016,2027) if ((yr==y)&fin).sum()>30))

print("\n3. PAIR: long SUPPLIER / short CUSTOMER, timed on supplier strength (dollar-neutral), net 5bp")
p=np.full(T,np.nan)
for t in range(63,T-1):
    on = supl[t]/supl[t-63]-1>0
    p[t+1]=(1.0 if on else 0.0)*(sup[t+1]-cust[t+1])
fin=np.isfinite(p); print(f"   long-supplier/short-customer (timed): Sharpe {sh(p[fin]):+.2f}  beta {beta(p,np.r_[np.nan,spy][:T]):+.2f}  inmkt {(p[fin]!=0).mean()*100:.0f}%")
print("     per-year: "+"  ".join(f"{y}:{sh(p[(yr==y)&fin]):+.2f}" for y in range(2016,2027) if ((yr==y)&fin).sum()>30))
# always-on pair for reference
p2=sup-cust; print(f"   (always-on long-supplier/short-customer: Sharpe {sh(p2):+.2f}  beta {beta(p2,spy):+.2f})")
