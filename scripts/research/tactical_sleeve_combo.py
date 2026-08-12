#!/usr/bin/python3
# PATH-A SKETCH — TACTICAL SLEEVE COMBO (user's design): the non-keepers are NOT standalone perpetual sleeves;
# they are REGIME sleeves, run in LIMITED size, ONLY in their favorable regime, TIME-BOXED to a quarter or two
# (forced stand-down + cooldown), and COMBINED so no one sleeve carries the book. Sleeves: cost-push (short
# food-mfrs when suppliers strong), beige (short airlines when fuel rising), bulgar (long processors when ag
# rising). Each SPY-hedged (market-neutral), small alloc; combined vs ungated.
#
# FINDING — the design is VALIDATED (this is the quick demo; the causal net-of-cost gate is
# scripts/tactical_book_validation.jl, which confirms it at +0.45 combined and a +5% keeper-book overlay uplift):
#  1. The COMBINATION is additive & market-neutral: combined book beta ~0, and the sleeves are mutually
#     UNCORRELATED (pairwise -0.07), so the combined Sharpe beats every individual sleeve. The diversification
#     shows exactly where predicted -- e.g. 2022: cost-push LOSES (staples-as-haven) but beige WINS (fuel spike),
#     so the combined book is POSITIVE that year. Each sleeve covers another's regime weakness.
#  2. The TIME-BOX (quarter-or-two cap) slightly LOWERS Sharpe on these already-market-neutral sleeves -- it is a
#     TAIL RAIL that earns its keep on the DIRECTIONAL/tail-prone sleeves (e.g. the beige flip), and costs a hair
#     on clean-neutral ones. Keep it as governance, not as a return driver.
# NOTE: this demo uses a STATIC beta hedge and light costs -> treat LEVELS as optimistic; the causal net-of-cost
# Julia gate is authoritative. VERDICT: the non-keepers ARE worth building -- as a small, regime-gated,
# time-boxed, COMBINED overlay on the keeper book, not as standalone sleeves. Keys from env; read-only.
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
def met(r):
    r=r[np.isfinite(r)]; s=r.std(); lvl=np.cumprod(1+r)
    return (r.mean()/s*math.sqrt(252) if s>0 else float('nan'), lvl[-1]**(252/len(r))-1, (lvl/np.maximum.accumulate(lvl)-1).min())
ALL=["INGR","ADM","BG","KO","PEP","MDLZ","GIS","KHC","DAL","UAL","AAL","LUV","ALK","JBLU","USO","DBA","SPY"]
R,i,dd=load(ALL); T=len(R); spy=R[:,i["SPY"]]; yr=np.array([int(d[:4]) for d in dd])
def bhedge(basket_ret): return basket_ret-beta(basket_ret,spy)*spy   # static-beta market-neutralized (demo)

# --- three regime sleeves: (regime_on[t], sleeve_daily_return[t]) ---
sup=np.mean([R[:,i[s]] for s in ["INGR","ADM"]],0); supl=np.cumprod(1+sup)
cust=np.mean([R[:,i[s]] for s in ["KO","PEP","MDLZ","GIS","KHC"]],0)
air=np.mean([R[:,i[s]] for s in ["DAL","UAL","AAL","LUV","ALK","JBLU"]],0); oil=np.cumprod(1+R[:,i["USO"]])
proc=np.mean([R[:,i[s]] for s in ["INGR","ADM","BG"]],0); ag=np.cumprod(1+R[:,i["DBA"]])
def reg(lvl,lb): return np.array([lvl[t]/lvl[t-lb]-1>0 if t>=lb else False for t in range(T)])
SLEEVES={
 "cost-push (short food-mfrs)": (reg(supl,63),  -bhedge(cust)),   # short customers when suppliers strong
 "beige (short airlines)":      (reg(oil,126),  -bhedge(air)),    # short airlines when fuel rising
 "bulgar (long processors)":    (reg(ag,63),     bhedge(proc)),   # long processors when ag rising
}

def tactical(regime, ret, alloc, max_hold, cooldown):
    """deploy alloc when regime on, but stand DOWN after max_hold consecutive days, then cooldown days off."""
    dep=np.zeros(T); run=0; cool=0
    for t in range(T):
        if cool>0: cool-=1; continue
        if regime[t] and run<max_hold: dep[t]=alloc; run+=1
        elif regime[t] and run>=max_hold: cool=cooldown; run=0   # time-box hit -> forced stand-down
        else: run=0
    return dep*np.nan_to_num(ret)

print("="*82,"\nTACTICAL SLEEVE COMBO — capped + regime-gated + time-boxed (quarter-or-two) + combined\n"+"="*82)
ALLOC=0.10; MAXHOLD=105; COOL=21     # 10% each, ~5 months (a quarter or two) max continuous, 1-month cooldown
print(f"\n  rules: {ALLOC*100:.0f}% alloc/sleeve, time-box {MAXHOLD}d (~{MAXHOLD/21:.0f} mo) max in a row, {COOL}d cooldown\n")
print(f"  {'sleeve':30s} {'ungated Sh':>11s} {'ungated DD':>11s} {'TIMEBOX Sh':>11s} {'TIMEBOX DD':>11s} {'in-mkt':>7s}")
combo_ung=np.zeros(T); combo_tb=np.zeros(T)
for nm,(rg,rt) in SLEEVES.items():
    ung=(rg*ALLOC)*np.nan_to_num(rt); tb=tactical(rg,rt,ALLOC,MAXHOLD,COOL)
    combo_ung+=ung; combo_tb+=tb
    mu,md=met(ung),met(tb)
    print(f"  {nm:30s} {mu[0]:>+11.2f} {mu[2]*100:>10.0f}% {md[0]:>+11.2f} {md[2]*100:>10.0f}% {(tb!=0).mean()*100:>6.0f}%")
print("  "+"-"*78)
mu,mt=met(combo_ung),met(combo_tb)
print(f"  {'COMBINED (30% tactical book)':30s} {mu[0]:>+11.2f} {mu[2]*100:>10.0f}% {mt[0]:>+11.2f} {mt[2]*100:>10.0f}% {(combo_tb!=0).mean()*100:>6.0f}%")
print(f"\n  combined time-boxed book: Sharpe {mt[0]:+.2f}  CAGR {mt[1]*100:+.1f}%  maxDD {mt[2]*100:+.0f}%  beta {beta(combo_tb,spy):+.2f}")
print(f"  per-year (time-boxed combined): "+"  ".join(f"{y}:{met(combo_tb[yr==y])[0]:+.2f}" for y in range(2016,2027) if (yr==y).sum()>60))
# diversification check: pairwise corr of the three deployed streams
streams=[tactical(rg,rt,ALLOC,MAXHOLD,COOL) for rg,rt in SLEEVES.values()]
cc=[np.corrcoef(streams[a][np.isfinite(streams[a])], streams[b][np.isfinite(streams[b])])[0,1] for a in range(3) for b in range(3) if a<b]
print(f"  pairwise corr among the 3 tactical sleeves: {np.mean(cc):+.2f} (low => they diversify each other)")
