#!/usr/bin/python3
# PATH-A SKETCH — multi-horizon trend  ×  split-universe (funded convexity × breadth). Not validated.
# base = 6 risk-premium ETFs (long-only inverse-vol); trend = 9 shortable CTA markets, sized either
# by sign(12mo) [baseline] or multi-horizon 3/6/12mo agreement [convex]. 2x2 to see if the wins stack.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
BASE6=["SPY","IEF","TLT","GLD","DBC","DBA"]
TREND9=["SPY","IEF","TLT","GLD","DBA","DBB","SLV","UUP","FXY"]
UNION=sorted(set(BASE6)|set(TREND9))
DATA={s:fetch(s) for s in UNION}
DTS=sorted(set.intersection(*[set(DATA[s]) for s in UNION]))
C=np.array([[DATA[s][d] for s in UNION] for d in DTS],float); R=(C[1:]/C[:-1]-1.0); DTS=DTS[1:]
IX={s:i for i,s in enumerate(UNION)}
SVOL,CAP,HL,MOM,VS,COST=0.08,1.5,21,252,60,0.0002
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);T,N=Rm.shape;o=np.empty((T,N));v=Rm[0]**2
    for t in range(T):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
SV=ewma_vol(R,HL)

def backtest(base_syms,trend_syms,variant,bw=0.5):
    bc=[IX[s] for s in base_syms]; tc=[IX[s] for s in trend_syms]; T=len(R); lam=1-2/(VS+1)
    b2=t2=0.0; pbw=np.zeros(len(bc)); ptw=np.zeros(len(tc)); pbook=np.zeros(len(UNION)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        if n>0:
            rb=float(pbw@R[t,bc]); rt=float(ptw@R[t,tc])
            b2=rb**2 if n==1 else lam*b2+(1-lam)*rb**2; t2=rt**2 if n==1 else lam*t2+(1-lam)*rt**2
        ivb=1/np.maximum(SV[t,bc],1e-12); base_w=ivb/ivb.sum()
        sigt=SV[t,tc]
        if variant=="sign":
            resp=np.sign(np.prod(1+R[t-MOM+1:t+1][:,tc],axis=0)-1)
        else:  # multi-horizon 3/6/12mo agreement
            resp=np.mean([np.sign(np.prod(1+R[t-min(k,t+1)+1:t+1][:,tc],axis=0)-1) for k in (63,126,252)],axis=0)
        raw=resp/np.maximum(sigt,1e-12); g=np.abs(raw).sum(); trend_w=raw/g if g>0 else np.zeros(len(tc))
        ex=lambda s2: CAP if (n==0 or s2<=1e-16) else min(CAP,SVOL/np.sqrt(s2*252))
        book=np.zeros(len(UNION)); book[bc]+=bw*ex(b2)*base_w; book[tc]+=(1-bw)*ex(t2)*trend_w
        mkt=R[:t+1][:,bc].mean(axis=1); ci=np.cumprod(1+mkt); book*=(0.5 if (ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(book@R[t+1])-COST*np.abs(book-pbook).sum()); idx.append(t+1)
        pbw,ptw,pbook,n=base_w,trend_w,book,n+1
    return np.array(pnl),[DTS[j] for j in idx]

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def monthly(p,dts):
    o={};[o.setdefault(dts[k][:7],[]).append(p[k]) for k in range(len(p))];return np.array([np.prod([1+r for r in v])-1 for v in o.values()])
def met(p,dts):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,p.std()*np.sqrt(252),(p.mean()/p.std()*np.sqrt(252) if p.std() else 0),(cum/np.maximum.accumulate(cum)-1).min(),skew(monthly(p,dts)),monthly(p,dts).min()
def crisis(p,dts,a,b):m=[k for k in range(len(p)) if a<=dts[k]<=b];return np.prod(1+p[np.array(m)])-1 if m else 0

CFG=[("Single +DBA (sign)",BASE6,BASE6,"sign"),
     ("Multi-horizon only (6-asset)",BASE6,BASE6,"multi"),
     ("Split-universe (sign)",BASE6,TREND9,"sign"),
     ("Split × multi-horizon",BASE6,TREND9,"multi")]
print(f"window {DTS[MOM+1]}..{DTS[-1]}\n")
print(f"{'configuration':<30}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew_m':>8}{'worstMo':>9}{'COVID':>8}{'2022':>7}")
print("-"*93)
for lab,b,tr,v in CFG:
    p,dts=backtest(b,tr,v); m=met(p,dts)
    print(f"{lab:<30}{m[0]*100:>7.1f}%{m[1]*100:>6.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>8.2f}{m[5]*100:>8.1f}%"
          f"{crisis(p,dts,'2020-02-19','2020-03-23')*100:>7.1f}%{crisis(p,dts,'2022-01-01','2022-10-31')*100:>6.1f}%")
