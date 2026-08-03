#!/usr/bin/python3
# PATH-A SKETCH — Taleb barbell with a long-vol convex proxy. NOT a validated strategy.
# Safe sleeve = BIL (T-bills). Convex sleeve = VIXY (short-term VIX futures; its calm-market
# bleed is the option-theta analog). Classic 90/10 vs the reversed 10/90 "curveball".
# Barbells optimize CONVEXITY / anti-ruin, not Sharpe — so we report skew, tails, crisis capture.
import os, json, urllib.request
import numpy as np

K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]
H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}

def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day"
       f"&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40))
    return {b["t"][:10]:b["c"] for b in d.get("bars",{}).get(s,[])}

SY=["BIL","VIXY","UVXY","SPY"]
DATA={s:fetch(s) for s in SY}
DATES=sorted(set.intersection(*[set(DATA[s]) for s in SY]))
C=np.array([[DATA[s][d] for s in SY] for d in DATES],float)
R=(C[1:]/C[:-1]-1.0); DTS=DATES[1:]              # daily returns aligned to DTS
IX={s:i for i,s in enumerate(SY)}
print(f"window {DTS[0]}..{DTS[-1]}  ({len(DTS)} days)\n")

def pkey(d,freq): return d[:7] if freq=="M" else f"{d[:4]}Q{(int(d[5:7])-1)//3}"

def sim(weights, freq="M"):
    # weights: dict sym->w (sum=1). Rebalance to target at each period boundary.
    idx=[IX[s] for s in weights]; w=np.array([weights[s] for s in weights],float)
    V=1.0; sub=w*V; port=[]
    for t in range(len(DTS)):
        sub=sub*(1+R[t][idx]); nV=sub.sum(); port.append(nV/V-1); V=nV
        if t+1<len(DTS) and pkey(DTS[t+1],freq)!=pkey(DTS[t],freq): sub=w*V
    return np.array(port)

def skew(x):
    x=np.asarray(x); m=x.mean(); s=x.std()
    return float(((x-m)**3).mean()/s**3) if s>0 else 0.0

def monthly(port):
    out={};
    for t,d in enumerate(DTS): out.setdefault(d[:7],[]).append(port[t])
    return np.array([np.prod([1+r for r in v])-1 for v in out.values()])

def quarterly(port):
    out={}
    for t,d in enumerate(DTS): out.setdefault(pkey(d,"Q"),[]).append(port[t])
    return np.array([np.prod([1+r for r in v])-1 for v in out.values()])

def metrics(port):
    cum=np.cumprod(1+port); cagr=cum[-1]**(252/len(port))-1
    vol=port.std()*np.sqrt(252); sh=port.mean()/port.std()*np.sqrt(252) if port.std() else 0
    dd=(cum/np.maximum.accumulate(cum)-1).min()
    mo=monthly(port)
    return cagr,vol,sh,dd,skew(port),skew(mo),mo.max(),mo.min()

CFG={
 "Safe 100% (BIL)":          ({"BIL":1.0},"M"),
 "Middle 100% (SPY)":        ({"SPY":1.0},"M"),
 "Barbell 90/10 (VIXY)":     ({"BIL":0.9,"VIXY":0.1},"M"),
 "Barbell 90/10 (UVXY)":     ({"BIL":0.9,"UVXY":0.1},"M"),
 "Growth+hedge 90/10 SPY/VIXY":({"SPY":0.9,"VIXY":0.1},"M"),
 "REVERSED 10/90 (VIXY)":    ({"BIL":0.1,"VIXY":0.9},"M"),
}
print(f"{'portfolio':<26}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew_d':>8}{'skew_m':>8}{'bestMo':>8}{'worstMo':>9}")
print("-"*91)
ports={}
for name,(w,f) in CFG.items():
    p=sim(w,f); ports[name]=p; m=metrics(p)
    print(f"{name:<26}{m[0]*100:>7.1f}%{m[1]*100:>6.0f}%{m[2]:>8.2f}{m[3]*100:>8.0f}%{m[4]:>8.2f}{m[5]:>8.2f}{m[6]*100:>7.0f}%{m[7]*100:>8.0f}%")

# crisis capture (cumulative return over each window)
WIN={"Volmageddon Feb18":("2018-02-01","2018-02-28"),"Q4-2018":("2018-10-01","2018-12-31"),
     "COVID crash":("2020-02-19","2020-03-23"),"2022 bear":("2022-01-01","2022-10-31")}
print("\nCrisis capture (cumulative return in window):")
print(f"{'portfolio':<26}" + "".join(f"{k:>19}" for k in WIN))
for name in CFG:
    row=""
    for k,(a,b) in WIN.items():
        m=[i for i,d in enumerate(DTS) if a<=d<=b]; cr=np.prod(1+ports[name][m])-1 if m else 0
        row+=f"{cr*100:>18.0f}%"
    print(f"{name:<26}{row}")

# the curveball, as a QUARTERLY bet — reversed barbell rebalanced quarterly
print("\n=== REVERSED barbell (10/90 BIL/VIXY) as a QUARTERLY strategy (rebalance quarterly) ===")
pr=sim({"BIL":0.1,"VIXY":0.9},"Q"); q=quarterly(pr)
print(f"quarters: {len(q)}   positive: {(q>0).mean()*100:.0f}%   median: {np.median(q)*100:+.1f}%   "
      f"mean: {q.mean()*100:+.1f}%   skew: {skew(q):+.2f}")
print(f"best quarter: {q.max()*100:+.0f}%   worst quarter: {q.min()*100:+.0f}%")
mq=metrics(pr); print(f"buy-and-hold-compounded: CAGR {mq[0]*100:.0f}%  maxDD {mq[3]*100:.0f}%  (long-term compounding vs quarterly reset)")
