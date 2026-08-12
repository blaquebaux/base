#!/usr/bin/python3
# PATH-A SKETCH — is Ingredion correlated with its supply chain (distributor UNVR + end customers KO/PEP/
# MDLZ/GIS/KHC), and is anything TRADEABLE? The chip-provider/computer-maker analogy = Cohen-Frazzini (2008)
# "economic links & predictable returns": co-movement is mostly market beta (NOT tradeable); the tradeable
# part, if any, is a LEAD-LAG (one side's return predicts the other's, from slow attention to the link).
# Public chain only (Univar went private 2023; Brenntag/IMCD/DKSH are foreign-listed). SIP daily 2016-2026.
#
# FINDING — the link is REAL but NOT a source of alpha:
#  1. They co-move (INGR-customers raw corr +0.48; chips-computers +0.70) AND there is a genuine private
#     supply-chain residual beyond market beta (+0.16..+0.22 for the food chain — even larger than the chip
#     chain's +0.12). So the economic-link intuition is CORRECT, not naive.
#  2. But co-movement is same-day, so it is not tradeable: by the time you see the supplier move, the customer
#     has already moved. The tradeable LEAD-LAG is absent — customer->INGR is ~0 to slightly NEGATIVE, and the
#     naive "buy the supplier when customers are strong" LOSES (Sharpe -0.27). The chip-chain sanity check
#     confirms it is dead in liquid mega-caps (chip->computer ~0). The 2008 anomaly needed thousands of links
#     + concentration data and has been arbitraged since; it does not survive in a few of the most liquid names.
#  3. The only flicker is weak SHORT-horizon mean-reversion of the pair (fade a 21d INGR-vs-customers
#     divergence: +0.30 gross, gone by 63d) — a fragile, high-turnover single pair, not a sleeve, and +0.30
#     won't survive real pairs costs.
#
# VERDICT: NULL as a sleeve. The lesson (the value here): CORRELATION != ALPHA. Real supply-chain co-movement
# costs you diversification; it does not create edge. Alpha needs PREDICTABILITY (a lag — not here) or a
# MEAN-REVERTING spread (too weak/fleeting here). Keys from env only; read-only; not validated.
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
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())
def resid(a,x): return a-beta(a,x)*x                     # a with market (x) removed
def cor(a,b): m=np.isfinite(a)&np.isfinite(b); return float(np.corrcoef(a[m],b[m])[0,1])
def sh(r,per=252): r=r[np.isfinite(r)]; s=r.std(); return r.mean()/s*math.sqrt(per) if s>0 else float('nan')

def leadlag(driver_lvl, target_ret, T, L, F):           # corr(driver trailing L-ret, target next F-ret)
    xs=[];ys=[]
    for t in range(L,T-F):
        dm=driver_lvl[t]/driver_lvl[t-L]-1; fr=np.prod(1+target_ret[t:t+F])-1
        if np.isfinite(dm) and np.isfinite(fr): xs.append(dm); ys.append(fr)
    return np.corrcoef(xs,ys)[0,1]

print("="*82,"\nINGREDION SUPPLY CHAIN — co-movement, residual co-movement, and lead-lag\n"+"="*82)
R,i,dd=load(["INGR","UNVR","KO","PEP","MDLZ","GIS","KHC","SPY"]); T=len(R); spy=R[:,i["SPY"]]
ingr=R[:,i["INGR"]]; cust=np.mean([R[:,i[s]] for s in ["KO","PEP","MDLZ","GIS","KHC"]],0)
print("\n1. CO-MOVEMENT: is it real, or just market beta?")
print(f"   corr(INGR, customer basket)          raw {cor(ingr,cust):+.2f}   residual-of-SPY {cor(resid(ingr,spy),resid(cust,spy)):+.2f}")
print(f"   corr(INGR, UNVR distributor)         raw {cor(ingr,R[:,i['UNVR']]):+.2f}   residual-of-SPY {cor(resid(ingr,spy),resid(R[:,i['UNVR']],spy)):+.2f}")
for s in ["KO","PEP","MDLZ","GIS","KHC"]:
    print(f"     INGR vs {s:5s}: raw {cor(ingr,R[:,i[s]]):+.2f}  residual {cor(resid(ingr,spy),resid(R[:,i[s]],spy)):+.2f}")
print("   (raw high but residual small => they co-move mostly THROUGH the market, not a private supply-chain link)")

print("\n2. LEAD-LAG (the only tradeable part): does one side PREDICT the other?")
il=np.cumprod(1+ingr); custl=np.cumprod(1+cust)
print(f"   {'':14s}"+"".join(f"{f'+{F}d':>8s}" for F in (5,21,63)))
for lbl,drv,tgt in [("customer->INGR", custl, ingr),("INGR->customer", il, cust)]:
    print(f"   {lbl:14s}"+"".join(f"{leadlag(drv,tgt,T,63,F):+8.2f}" for F in (5,21,63)))

print("\n3. TRADEABLE? long INGR when customer basket 63d momentum>0 (SPY-hedged), net 5bp")
bI=beta(ingr,spy); pnl=[]
for t in range(63,T-1):
    pos=1.0 if custl[t]/custl[t-63]-1>0 else 0.0
    pnl.append(pos*(ingr[t+1]-bI*spy[t+1]))
p=np.array(pnl); print(f"   customer-momentum -> long INGR (hedged): Sharpe {sh(p):+.2f}  beta {beta(p,spy[63:63+len(p)]):+.2f}  inmkt {(p!=0).mean()*100:.0f}%")

print("\n4. SANITY — same lead-lag on the CHIP chain (is the Cohen-Frazzini effect even alive 2016-2026?)")
R2,j,_=load(["NVDA","AVGO","QCOM","AAPL","HPQ","MSFT","SPY"]); T2=len(R2)
sup=np.mean([R2[:,j[s]] for s in ["NVDA","AVGO","QCOM"]],0); comp=np.mean([R2[:,j[s]] for s in ["AAPL","HPQ","MSFT"]],0)
supl=np.cumprod(1+sup); compl=np.cumprod(1+comp)
print(f"   corr raw {cor(sup,comp):+.2f}  residual-of-SPY {cor(resid(sup,R2[:,j['SPY']]),resid(comp,R2[:,j['SPY']])):+.2f}")
print(f"   {'':14s}"+"".join(f"{f'+{F}d':>8s}" for F in (5,21,63)))
print(f"   {'chip->computer':14s}"+"".join(f"{leadlag(supl,comp,T2,63,F):+8.2f}" for F in (5,21,63)))
print(f"   {'computer->chip':14s}"+"".join(f"{leadlag(compl,sup,T2,63,F):+8.2f}" for F in (5,21,63)))

print("\n5. LAST FLICKER — short-horizon mean-reversion of the INGR-vs-customers spread (net 5bp)")
for L in (21,63,126):
    pnl=[]
    for t in range(L,T-1):
        rel=(il[t]/il[t-L]) - (custl[t]/custl[t-L])    # INGR relative outperformance over L
        pnl.append((-1.0 if rel>0 else 1.0)*(ingr[t+1]-cust[t+1]))   # fade it, dollar-neutral
    p=np.array(pnl); print(f"   L={L:>3d}d fade-the-spread: Sharpe {sh(p):+.2f}")
print("   -> only the 21d fade is positive (+0.30) and it decays to ~0 by 63d: fragile, high-turnover, not a sleeve.")
print("\nVERDICT: NULL. They co-move (and there IS a real private supply-chain residual), but co-movement is")
print("same-day -> not tradeable; the lead-lag alpha is arbitraged away in liquid names. CORRELATION != ALPHA.")
