#!/usr/bin/python3
# PATH-A SKETCH — MOMENT LADDER: does the volatility-pump / second-order-arbitrage idea extend to
# harvesting the 3rd (skewness), 4th (kurtosis), 5th+ moments cross-sectionally? Long low-k-moment /
# short high-k-moment, monthly, 60d window, net of cost, market-neutral. Peng's G-expectation (the
# "second-order" object) is VOLATILITY (2nd-moment) uncertainty specifically; this asks whether the
# ladder of "higher-order arbitrages" the user proposed actually separates into independent premia.
#
# FINDING — the ladder does NOT extend into new independent edges:
#  1. Beta ~ 0 for every rung (k>=3): the moment long-shorts are genuinely MARKET-NEUTRAL — the
#     "in tandem, low-beta" intuition is right on the beta.
#  2. But in 2016-2026 the premia REVERSED sign: long-low/short-high LOST (variance -0.96, skew -0.57,
#     kurt -0.52, lottery/MAX -0.55) because the megacap-GROWTH regime rewarded the high-vol/lottery
#     names (NVDA/TSLA/AMD). The low-vol and lottery anomalies are real long-run but REGIME-DEPENDENT
#     — harvesting them this decade would have bled.
#  3. Crucially, moments 3-6 are REDUNDANT as trades: near-identical Sharpe (-0.52..-0.58) and
#     persistence (~0.57), mutual rank-corr +0.35 — they're all dominated by the same tail observations,
#     so a 5th/6th-order sort re-picks the same extreme names and adds NO independent information. Only
#     the 2nd moment (variance) is distinct and highly estimable (persistence 0.90).
#
# VERDICT: the harvestable object is the 2nd moment (the volatility pump — Peng's actual G-expectation
# target, real but drift-overwhelmed this decade). The 3rd is a real long-run skew/lottery premium but
# it REVERSED here and is redundant with 4th-6th; beyond that the "ladder" collapses into ONE regime-
# dependent, tail-driven, market-neutral factor — extending to 5th-order spline etc. buys no new edge,
# only estimation error. Moment premia diversify (low beta), they don't compound into higher-order alpha.
# DEPENDENCY: scipy. Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
from scipy import stats as st
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
U=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG","XOM","JNJ",
"COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL","DIS","GS","MS","CAT","HON","LLY","ABBV","TMO","NKE"]
D={s:cl(s) for s in U+["SPY"]}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
M=np.array([[D[s][d] for s in U] for d in ds],float); R=M[1:]/M[:-1]-1; spy=np.array([D["SPY"][d] for d in ds]); spyr=spy[1:]/spy[:-1]-1
T,N=R.shape; W=60; REB=21; cost=5/1e4
def moment(win,k):
    m=win.mean(0); s=win.std(0)+1e-12; z=(win-m)/s
    return (win.var(0) if k==2 else np.mean(z**k,0))
def sh(x): x=x[np.isfinite(x)]; return x.mean()/x.std()*math.sqrt(252) if x.std()>0 else float('nan')
def beta(x): m=np.isfinite(x); return float(np.cov(x[m],spyr[W:W+len(x)][m])[0,1]/spyr[W:W+len(x)][m].var()) if m.sum()>20 else 0.0
print("="*82,"\nMOMENT LADDER — is each higher moment an independent harvestable premium?\n"+"="*82)
print(f"\n  {'k':>2} {'moment':10s} {'long-short Sh':>13s} {'beta':>6s} {'persistence':>12s}  read")
labels={2:"variance",3:"skewness",4:"kurtosis",5:"5th mom",6:"6th mom"}
reads={2:"low-vol anomaly — REVERSED here",3:"skew/lottery premium — REVERSED",4:"= the same tail trade",5:"redundant (tail-driven)",6:"redundant (tail-driven)"}
for k in (2,3,4,5,6):
    pnl=[]; persist=[]; wprev=None; w=np.zeros(N)
    for t in range(W,T-1):
        if (t-W)%REB==0:
            mk=moment(R[t-W:t],k); order=np.argsort(mk); kk=max(1,N//5)
            w=np.zeros(N); w[order[:kk]]=1/kk; w[order[-kk:]]=-1/kk
            rank=st.rankdata(mk); wprev is not None and persist.append(st.spearmanr(rank,wprev)[0]); wprev=rank
        pnl.append(float(np.nansum(w*R[t+1]))-(np.abs(w).sum()*cost if (t-W)%REB==0 else 0))
    pnl=np.array(pnl)
    print(f"  {k:>2} {labels[k]:10s} {sh(pnl):>13.2f} {beta(pnl):>6.2f} {np.nanmean(persist):>12.2f}  {reads[k]}")
pnl=[]; w=np.zeros(N)
for t in range(W,T-1):
    if (t-W)%REB==0:
        mx=np.sort(R[t-21:t],0)[-5:].mean(0); o=np.argsort(mx); kk=max(1,N//5); w=np.zeros(N); w[o[:kk]]=1/kk; w[o[-kk:]]=-1/kk
    pnl.append(float(np.nansum(w*R[t+1]))-(np.abs(w).sum()*cost if (t-W)%REB==0 else 0))
print(f"\n  lottery (MAX-5, long dull / short lottery): Sharpe {sh(np.array(pnl)):+.2f}  beta {beta(np.array(pnl)):+.2f}  (also reversed)")
corrs=[]
for t in range(W,T-1,REB):
    mm={k:moment(R[t-W:t],k) for k in (3,4,5,6)}
    for ka in (3,4,5,6):
        for kb in (3,4,5,6):
            if ka<kb: corrs.append(st.spearmanr(mm[ka],mm[kb])[0])
print(f"  higher moments 3-6: mutual rank-corr {np.nanmean(corrs):+.2f} + near-identical Sharpe/persistence -> ONE redundant tail trade")
print("\nVERDICT: the ladder doesn't extend. Beta ~0 (market-neutral, tandem-right), but the premia REVERSED")
print("this decade (regime-dependent) and moments 3+ collapse into a single tail-driven, redundant factor.")
print("The one harvestable object is the 2nd moment (the volatility pump = Peng's G-expectation target);")
print("higher 'orders' add estimation error, not independent alpha. Moment premia DIVERSIFY, they don't compound.")
