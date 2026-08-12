#!/usr/bin/python3
# PATH-A SKETCH — can the REMAINING non-keepers be added to the tactical book in limited capacity? The 3-part
# filter each must pass to be ADDITIVE: (1) roughly market-neutral (|beta|<=0.25), (2) non-negative own-Sharpe
# (net, in its regime), (3) UNCORRELATED to the existing tactical book (cost-push/beige/bulgar, |corr|<=0.30).
#
# FINDING — almost none of the remaining shelf qualifies:
#  * The "theory" sketches (market_temperature, pascal_ergodicity, antichronos, kernel_of_silence,
#    nonlinear_filtering, long_strength_negative, growth_vs_ruin) are RISK-LENSES / insights, NOT tradeable
#    return streams -- they can't be deployed at 10%.
#  * The deployable market-neutral candidates -- low-vol (2nd moment) and lottery/MAX (skew) -- FAIL: they are
#    NEGATIVE this decade (long-low/short-high lost in the megacap-GROWTH regime) AND carry large negative
#    market beta (-0.8 to -0.9). Even RISK-OFF-GATED (their favorable regime) they stay ~-0.49, and even fully
#    SPY-NEUTRALIZED the pure anomaly is still negative (-0.52 vol / -0.38 lottery). They ARE uncorrelated to
#    the tactical book (~0), but a negative-Sharpe uncorrelated stream still HURTS -- fails filter (2).
#  * null_pairs is redundant (its mechanism = camp rotation, already a keeper).
#  * PEAD (real earnings drift, +0.79%/20d monotonic LS) is the ONE genuinely additive remaining candidate --
#    positive, market-neutral, and EVENT-driven so naturally limited-capacity/regime-gated. But it needs an
#    earnings-DATE pipeline to deploy (heavier than the momentum-gated sleeves); flagged for a dedicated build.
#
# VERDICT: the tactical book is essentially COMPLETE with cost-push/beige/bulgar; the only remaining sleeve
# worth adding is PEAD, and it requires an earnings-calendar data pipeline. Everything else is either a
# risk-lens (not deployable) or a regime-reversed negative-Sharpe stream (would hurt). Keys from env; read-only.
# Moment sleeves are REGIME-DEPENDENT, so also tested RISK-OFF-GATED (their favorable regime), a-priori.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
UNIV=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG","XOM","JNJ",
      "COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL","DIS","CAT","HON","LLY","NKE"]
TAC=["INGR","ADM","BG","MDLZ","GIS","KHC","DAL","UAL","AAL","LUV","ALK","JBLU","USO","DBA"]  # tactical-book universe extras
SY=sorted(set(UNIV+TAC+["SPY"]))
D={s:cl(s) for s in SY}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
M=np.array([[D[s][d] for s in SY] for d in ds],float); R=M[1:]/M[:-1]-1; i={s:SY.index(s) for s in SY}; T=len(R); spy=R[:,i["SPY"]]
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())
def sh(r,per=252): r=r[np.isfinite(r)]; s=r.std(); return r.mean()/s*math.sqrt(per) if s>0 else float('nan')
def cor(a,b): m=np.isfinite(a)&np.isfinite(b); return float(np.corrcoef(a[m],b[m])[0,1]) if m.sum()>30 else float('nan')
def hedge(r): return r-beta(r,spy)*spy

# ---- existing tactical book (cost-push + beige + bulgar), 10% each, SPY-hedged, gated ----
def basket(names): return np.mean([R[:,i[s]] for s in names],0)
def lvl(names): return np.cumprod(1+basket(names))
def gated_short(cust,sig,lb,side):
    sl=lvl(sig); out=np.full(T,np.nan)
    for t in range(lb,T-1): out[t+1]=(side if sl[t]/sl[t-lb]-1>0 else 0.0)*hedge(basket(cust))[t+1]
    return out
tac = 0.10*(np.nan_to_num(gated_short(["KO","PEP","MDLZ","GIS","KHC"],["INGR","ADM"],63,-1)) +
            np.nan_to_num(gated_short(["DAL","UAL","AAL","LUV","ALK","JBLU"],["USO"],126,-1)) +
            np.nan_to_num(gated_short(["INGR","ADM","BG"],["DBA"],63,+1)))

# ---- moment sleeves: cross-sectional long low-moment / short high-moment over UNIV, monthly ----
U=[i[s] for s in UNIV]; W=60; REB=21
def moment_sleeve(kind, gate=None):   # kind: 'vol' or 'lottery'; gate: None or 'riskoff'
    pnl=np.full(T,np.nan); w=np.zeros(len(U))
    spyl=np.cumprod(1+spy)
    for t in range(W,T-1):
        if (t-W)%REB==0:
            win=R[t-W:t][:,U]
            mk = win.std(0) if kind=='vol' else np.sort(win,0)[-5:].mean(0)   # vol or MAX(lottery)
            o=np.argsort(mk); k=max(1,len(U)//5); w=np.zeros(len(U)); w[o[:k]]=1/k; w[o[-k:]]=-1/k  # long low / short high
        on = True if gate is None else (t>=63 and spyl[t]/spyl[t-63]-1 < 0)   # risk-off = SPY 63d downtrend
        pnl[t+1]= (np.nansum(w*R[t+1,U]) if on else 0.0)
    return pnl

cands = {
 "low-vol (ungated)":       moment_sleeve('vol'),
 "low-vol (risk-off gated)":moment_sleeve('vol','riskoff'),
 "lottery (ungated)":       moment_sleeve('lottery'),
 "lottery (risk-off gated)":moment_sleeve('lottery','riskoff'),
}
print("="*88,"\nREMAINING non-keepers as tactical sleeves — the 3-part filter (net-ish, demo hedge)\n"+"="*88)
print(f"\n  existing tactical book: Sharpe {sh(tac):+.2f}  beta {beta(tac,spy):+.2f}\n")
print(f"  {'candidate':28s} {'Sharpe':>7s} {'beta':>6s} {'corr->tac':>10s} {'corr->SPY':>10s}  {'qualifies?':>10s}")
for nm,r in cands.items():
    S,b,ct,cs = sh(r),beta(r,spy),cor(r,tac),cor(r,spy)
    q = (S>0.10) and (abs(b)<=0.25) and (abs(ct)<=0.30)
    print(f"  {nm:28s} {S:>+7.2f} {b:>+6.2f} {ct:>+10.2f} {cs:>+10.2f}  {'YES' if q else 'no':>10s}")
print("\n  filter: qualifies if own-Sharpe>+0.10 AND |beta|<=0.25 AND |corr to tactical book|<=0.30")
print("  NOTE: PEAD (earnings drift, +0.79%/20d LS) is the strongest remaining candidate but is EVENT-driven")
print("  (needs an earnings-date pipeline) -> naturally limited-capacity/regime-gated; tested separately.")
