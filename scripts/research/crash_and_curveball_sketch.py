#!/usr/bin/python3
# PATH-A SKETCH — (A) can a FASTER / break-out trend catch the sharp COVID-style crash the
# 3-12mo sleeve misses?  (B) can vol-gating or spike-harvesting rescue the curveball from ruin?
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
SP6=["SPY","IEF","TLT","GLD","DBC","DBA"]; SY=SP6+["BIL","VIXY"]
DATA={s:fetch(s) for s in SY}
D=sorted(set.intersection(*[set(DATA[s]) for s in SY]))
C=np.array([[DATA[s][d] for s in SY] for d in D],float); R=(C[1:]/C[:-1]-1.0); DTS=D[1:]; IX={s:i for i,s in enumerate(SY)}
SVOL,CAP,HL,MOM,VS,COST=0.08,1.5,21,252,60,0.0002
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);T,N=Rm.shape;o=np.empty((T,N));v=Rm[0]**2
    for t in range(T):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
sp6c=[IX[s] for s in SP6]; SV=ewma_vol(R[:,sp6c],HL)
P=C[:,sp6c]                                   # spine prices for the break rule
rmin20=np.full_like(P,np.nan)                 # trailing 20-day low (prices)
for t in range(P.shape[0]): rmin20[t]=P[max(0,t-19):t+1].min(axis=0)

def spine(variant):
    Rs=R[:,sp6c]; T=len(Rs); lam=1-2/(VS+1); b2=t2=0.0
    pbw=ptw=pbook=np.zeros(len(SP6)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        sig=SV[t]
        if n>0:
            rb=float(pbw@Rs[t]); rt=float(ptw@Rs[t])
            b2=rb**2 if n==1 else lam*b2+(1-lam)*rb**2; t2=rt**2 if n==1 else lam*t2+(1-lam)*rt**2
        iv=1/np.maximum(sig,1e-12); bw=iv/iv.sum()
        if variant=="base": resp=np.sign(np.prod(1+Rs[t-251:t+1],axis=0)-1)
        elif variant=="multi": resp=np.mean([np.sign(np.prod(1+Rs[t-min(k,t+1)+1:t+1],axis=0)-1) for k in (63,126,252)],axis=0)
        elif variant=="multifast": resp=np.mean([np.sign(np.prod(1+Rs[t-min(k,t+1)+1:t+1],axis=0)-1) for k in (21,63,126,252)],axis=0)
        elif variant=="break":
            resp=np.mean([np.sign(np.prod(1+Rs[t-min(k,t+1)+1:t+1],axis=0)-1) for k in (63,126,252)],axis=0)
            broke=P[t+1]<=rmin20[t+1]+1e-12      # new 20-day low today → force short
            resp=np.where(broke,-1.0,resp)
        raw=resp/np.maximum(sig,1e-12); g=np.abs(raw).sum(); tw=raw/g if g>0 else np.zeros(len(SP6))
        ex=lambda s2: CAP if (n==0 or s2<=1e-16) else min(CAP,SVOL/np.sqrt(s2*252))
        w=0.5*ex(b2)*bw+0.5*ex(t2)*tw
        mkt=Rs[:t+1].mean(axis=1); ci=np.cumprod(1+mkt); w*=(0.5 if (ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(w@Rs[t+1])-COST*np.abs(w-pbook).sum()); idx.append(t+1)
        pbw,ptw,pbook,n=bw,tw,w,n+1
    return np.array(pnl),[DTS[j] for j in idx]

# vol percentile for curveball gating
spy=R[:,IX["SPY"]]; T=len(spy); rv=np.full(T,np.nan)
for j in range(20,T): rv[j]=spy[j-20:j+1].std()*np.sqrt(252)
pct=np.full(T,0.5)
for j in range(272,T): pct[j]=np.mean(rv[j-251:j+1]<=rv[j])

def curveball(mode):
    bil=IX["BIL"]; vix=IX["VIXY"]; T=len(R); w=np.array([0.1,0.9]); V=1.0; sub=w*V; port=[]
    for t in range(T):
        # decide target for the day
        if mode=="always": tgt=w
        elif mode=="volgate": tgt=w if pct[t]<0.33 else np.array([1.0,0.0])     # only deploy when vol cheap
        elif mode=="harvest":
            spike = t>=5 and (C[t+1,vix]/C[t-4,vix]-1)>0.30                       # VIXY +30% over 5d → lock in
            tgt=np.array([1.0,0.0]) if spike else w
        sub=np.array([tgt[0],tgt[1]])*sub.sum()                                  # rebalance to target daily
        sub=sub*(1+R[t][[bil,vix]]); nV=sub.sum(); port.append(nV/V-1); V=nV
    return np.array(port)

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def monthly(p,dts):
    o={};[o.setdefault(dts[k][:7],[]).append(p[k]) for k in range(len(p))];return np.array([np.prod([1+r for r in v])-1 for v in o.values()])
def met(p,dts):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,(p.mean()/p.std()*np.sqrt(252) if p.std() else 0),(cum/np.maximum.accumulate(cum)-1).min(),skew(monthly(p,dts)),monthly(p,dts).min()
def crisis(p,dts,a,b):m=[k for k in range(len(p)) if a<=dts[k]<=b];return np.prod(1+p[np.array(m)])-1 if m else 0

print("A) TREND SLEEVE variants — can a faster/break trend catch the SHARP crash? (full spine)")
print(f"{'variant':<26}{'CAGR':>8}{'Sharpe':>8}{'maxDD':>9}{'skew_m':>8}{'worstMo':>9}{'COVID':>8}{'2022':>7}")
print("-"*84)
for v,lab in [("base","baseline sign 12mo"),("multi","multi 3/6/12mo"),("multifast","multi + 1mo (fast)"),("break","multi + 20d-low break→short")]:
    p,dts=spine(v); m=met(p,dts)
    print(f"{lab:<26}{m[0]*100:>7.1f}%{m[1]:>8.2f}{m[2]*100:>8.1f}%{m[3]:>8.2f}{m[4]*100:>8.1f}%"
          f"{crisis(p,dts,'2020-02-19','2020-03-23')*100:>7.1f}%{crisis(p,dts,'2022-01-01','2022-10-31')*100:>6.1f}%")

print("\nB) CURVEBALL rescue attempts (reversed 10/90 BIL/VIXY) — can a rule beat ruin?")
print(f"{'mode':<26}{'CAGR':>8}{'maxDD':>9}{'skew_m':>8}{'%posMo':>8}{'medMo':>8}{'COVID':>9}")
print("-"*77)
for mode,lab in [("always","always-on"),("volgate","deploy only when vol cheap"),("harvest","sell into 5d spikes")]:
    p=curveball(mode); dts=DTS; mo=monthly(p,dts); m=met(p,dts)
    print(f"{lab:<26}{m[0]*100:>7.0f}%{m[2]*100:>8.0f}%{m[3]:>8.2f}{100*(mo>0).mean():>7.0f}%{np.median(mo)*100:>7.1f}%"
          f"{crisis(p,dts,'2020-02-19','2020-03-23')*100:>8.0f}%")
