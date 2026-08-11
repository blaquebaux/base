#!/usr/bin/python3
# PATH-A SKETCH — SALVAGE LAB: can the non-keepers be rescued by going LONG, COMBINING, or CONDITIONING?
# The family's nulls (brittle/bulk/bubble/basel/bio/emea/latam/blurred/backsliders/brute-force/block)
# failed as standalone systematic sleeves. This tests the three proposed rescue mechanisms honestly,
# net of cost, on 40 liquid large caps (2016-2026, SIP daily w/ OHLC).
#
# FINDINGS:
#  1. EVENT conditioning (earnings, proxied by big overnight GAPS): real but small, and LONG-ONLY.
#     After a big UP gap, names drift +2.56%/20d vs +1.83% unconditional (+0.73% excess = post-earnings
#     drift). But the long-short is DEAD (+0.11% net) because big DOWN-gappers BOUNCE (+2.05%, they do
#     not drift down) — the drawdown-bounce again. So earnings-events salvage into a weak long tilt, not
#     a stat-arb.
#  2. CALENDAR conditioning: real but marginal. Turn-of-month (+0.073%/day vs +0.057% rest) exists but a
#     TOM-only book (+0.59 Sharpe, 29% in-market) still trails buy&hold (+0.88); Monday (+0.094%) is the
#     strongest weekday, Thursday (+0.016%) the weakest — a modest "start-of-week" pulse.
#  3. GOING LONG the un-shortable: survives (fade the most-extended = ruin; ride it = +; the negative-test
#     law) but it is ~ beta/momentum (here survivorship-inflated), not new alpha.
#  4. COMBINING nulls: diversifies RISK, does not create RETURN — averaging a losing stream with a
#     zero-edge one gives a still-losing (lower-vol) stream; the mean is just the average of the parts.
#
# VERDICT: the nulls do NOT resurrect into standalone alpha. Going long recovers beta; combining reduces
# risk, not return. CONDITIONING is the only real lever — it surfaces genuine but SMALL, mostly long-only
# tilts (post-gap drift, turn-of-month, Monday) — the same "find the slice where it works" mechanism that
# rescued Bounce (gated to chop) and APAC (as relative strength). A null's residual value is as a
# conditional TILT or overlay, not a revived sleeve; the strong conditional salvages already happened.
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math, datetime as dt
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def bars(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
U=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG","XOM","JNJ",
"COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL","DIS","GS","MS","CAT","HON","LLY","ABBV","TMO","NKE"]
B={s:{x["t"][:10]:(x["o"],x["c"]) for x in bars(s)} for s in U}; SPY={x["t"][:10]:(x["o"],x["c"]) for x in bars("SPY")}
ds=sorted(set.intersection(*[set(v) for v in B.values()], set(SPY)))
O=np.array([[B[s][d][0] for s in U] for d in ds]); C=np.array([[B[s][d][1] for s in U] for d in ds])
spx=np.array([SPY[d][1] for d in ds]); T,N=C.shape; gap=O[1:]/C[:-1]-1
def sh(p): p=np.asarray(p); p=p[np.isfinite(p)]; return p.mean()/p.std()*math.sqrt(252) if p.std()>0 else float('nan')
print("="*80,"\nSALVAGE LAB — long / combine / condition the non-keepers\n"+"="*80)

print("\n1. EVENT CONDITIONING — drift after a big overnight GAP (earnings-surprise proxy), 20d fwd, net cost")
H20=20; cost=0.001; pos=[]; neg=[]; unc=[]
for t in range(1,T-H20):
    g=gap[t-1]; thi=np.nanpercentile(np.abs(gap[max(0,t-252):t]),90) if t>30 else 0.05
    fr=C[t+H20,:]/C[t,:]-1; up=g>=thi; dn=g<=-thi
    up.any() and pos.append(np.nanmean(fr[up])); dn.any() and neg.append(np.nanmean(fr[dn])); unc.append(np.nanmean(fr))
pos,neg,unc=map(np.array,(pos,neg,unc))
print(f"   after BIG UP gap : mean 20d fwd {np.nanmean(pos)*100:+.2f}%   (unconditional {np.nanmean(unc)*100:+.2f}%)  -> real drift, LONG only")
print(f"   after BIG DOWN gap: mean 20d fwd {np.nanmean(neg)*100:+.2f}%   (bounces up, not down -> the long-short is dead)")
print(f"   PEAD long-short (long up / short down) NET of cost: {((np.nanmean(pos)-np.nanmean(neg))-4*cost)*100:+.2f}% / 20d")

print("\n2. CALENDAR CONDITIONING — turn-of-month (TOM) and day-of-week on SPY")
r=spx[1:]/spx[:-1]-1; dd=[dt.date.fromisoformat(d) for d in ds[1:]]; tom=np.zeros(len(r),bool); month=[(d.year,d.month) for d in dd]; i=0
while i<len(r):
    j=i
    while j<len(r) and month[j]==month[i]: j+=1
    for k in range(i,j):
        (k-i<=2 or j-1-k<=2) and (tom.__setitem__(k,True))
    i=j
print(f"   TOM window (last3+first3): mean daily {r[tom].mean()*100:+.3f}%   vs rest {r[~tom].mean()*100:+.3f}%")
print(f"   TOM-only SPY (long in window, else flat): Sharpe {sh(np.where(tom,r,0)):+.2f}  vs buy&hold {sh(r):+.2f}  (in-market {tom.mean()*100:.0f}%)")
wd=np.array([d.weekday() for d in dd]); nm=["Mon","Tue","Wed","Thu","Fri"]
print("   day-of-week mean daily: "+"  ".join(f"{nm[w]} {r[wd==w].mean()*100:+.3f}%" for w in range(5)))

print("\n3. LONG (RIDE) vs SHORT (FADE) the most-extended — the 'go long instead' idea")
def strat(direction, look=20, hold=20, cost=0.001):
    pnl=[]
    for t in range(look,T-hold,hold):
        o=np.argsort(C[t]/C[t-look]-1); k=max(1,N//10); w=np.zeros(N); w[o[-k:]]=direction/k
        pnl.append(float(w@(C[t+hold]/C[t]-1))-2*cost*np.abs(w).sum())
    return np.array(pnl)
print(f"   long top-runup (ride) Sharpe {sh(strat(+1)):+.2f}   short top-runup (fade) {sh(strat(-1)):+.2f}   (long survives, fade is ruin — but long ~ beta, survivorship-inflated)")

print("\n4. COMBINING nulls — does averaging zero-edge streams create alpha?")
a=strat(-1); rng=np.random.default_rng(0); b=rng.normal(0,a.std(),len(a))
print(f"   losing fade {sh(a):+.2f}  +  zero-edge {sh(b):+.2f}  ->  combined {sh(0.5*a+0.5*b):+.2f}   (vol falls; the mean is just the average — no alpha created)")

print("\nVERDICT: nulls don't resurrect into standalone alpha. Long recovers BETA; combining reduces RISK,")
print("not return; CONDITIONING (events/calendar) surfaces real but small, mostly long-only tilts — the")
print("'find the slice where it works' mechanism that already rescued Bounce (chop) and APAC (RS). A")
print("null's residual value is a conditional TILT/overlay, not a revived sleeve.")
