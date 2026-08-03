#!/usr/bin/python3
# PATH-A SKETCH — a MORE CONVEX trend sleeve (funded convexity, no theta). Not validated.
# Baseline trend = sign(12mo)/vol. Variants: convex response (size by trend STRENGTH^2), multi-horizon
# (3/6/12mo agreement), and both. Measured on crisis capture + skew + drawdown, at spine and sleeve level.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
SP=["SPY","IEF","TLT","GLD","DBC","DBA"]; DATA={s:fetch(s) for s in SP}
DTS=sorted(set.intersection(*[set(DATA[s]) for s in SP]))
C=np.array([[DATA[s][d] for s in SP] for d in DTS],float); R=(C[1:]/C[:-1]-1.0); DTS=DTS[1:]
SVOL,CAP,HL,MOM,VS,COST=0.08,1.5,21,252,60,0.0002
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);T,N=Rm.shape;o=np.empty((T,N));v=Rm[0]**2
    for t in range(T):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2; o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
SV=ewma_vol(R,HL)

def trend_w(t,sig,variant):
    horizons=[252] if variant in ("base","cvx") else [63,126,252]
    strs=[]
    for k in horizons:
        kk=min(k,t+1); cum=np.prod(1+R[t-kk+1:t+1],axis=0)-1
        strs.append(cum/(sig*np.sqrt(252)+1e-12))          # vol-scaled trend "strength"
    strength=np.mean(strs,axis=0)
    if variant=="base": resp=np.sign(strength)                                   # current: sign only
    elif variant=="multi": resp=np.mean([np.sign(s) for s in strs],axis=0)       # horizon agreement in [-1,1]
    elif variant=="cvx": resp=np.sign(strength)*np.minimum(np.abs(strength),3.0)**2   # convex in strength
    elif variant=="multicvx":
        agree=np.mean([np.sign(s) for s in strs],axis=0); mag=np.minimum(np.abs(strength),3.0)**2
        resp=agree*mag
    raw=resp/np.maximum(sig,1e-12); g=np.abs(raw).sum()
    return raw/g if g>0 else np.zeros_like(raw)

def run(variant,bw=0.5):     # bw=0.5 full spine; bw=0 trend-only
    T=len(R); lam=1-2/(VS+1); b2=t2=0.0; pbw=ptw=pbook=np.zeros(len(SP)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        sig=SV[t]
        if n>0:
            rb=float(pbw@R[t]); rt=float(ptw@R[t])
            b2=rb**2 if n==1 else lam*b2+(1-lam)*rb**2; t2=rt**2 if n==1 else lam*t2+(1-lam)*rt**2
        iv=1/np.maximum(sig,1e-12); base_w=iv/iv.sum(); tw=trend_w(t,sig,variant)
        ex=lambda s2: CAP if (n==0 or s2<=1e-16) else min(CAP,SVOL/np.sqrt(s2*252))
        w=bw*ex(b2)*base_w+(1-bw)*ex(t2)*tw
        mkt=R[:t+1].mean(axis=1); ci=np.cumprod(1+mkt); w*=(0.5 if (ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(w@R[t+1])-COST*np.abs(w-pbook).sum()); idx.append(t+1)
        pbw,ptw,pbook,n=base_w,tw,w,n+1
    return np.array(pnl),[DTS[j] for j in idx]

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def monthly(p,dts):
    o={};[o.setdefault(dts[k][:7],[]).append(p[k]) for k in range(len(p))];return np.array([np.prod([1+r for r in v])-1 for v in o.values()])
def met(p,dts):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,p.std()*np.sqrt(252),(p.mean()/p.std()*np.sqrt(252) if p.std() else 0),(cum/np.maximum.accumulate(cum)-1).min(),skew(monthly(p,dts)),monthly(p,dts).min()
def crisis(p,dts,a,b):m=[k for k in range(len(p)) if a<=dts[k]<=b];return np.prod(1+p[np.array(m)])-1 if m else 0

V=[("base","baseline (sign, 12mo)"),("multi","multi-horizon (3/6/12mo)"),("cvx","convex response (str^2)"),("multicvx","multi + convex")]
print("FULL SPINE (base+trend blended 50/50):")
print(f"{'trend variant':<26}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew_m':>8}{'worstMo':>9}{'COVID':>8}{'2022':>7}")
print("-"*90)
for v,lab in V:
    p,dts=run(v,0.5); m=met(p,dts)
    print(f"{lab:<26}{m[0]*100:>7.1f}%{m[1]*100:>6.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>8.2f}{m[5]*100:>8.1f}%"
          f"{crisis(p,dts,'2020-02-19','2020-03-23')*100:>7.1f}%{crisis(p,dts,'2022-01-01','2022-10-31')*100:>6.1f}%")
print("\nTREND SLEEVE ALONE (base_weight=0) — the convexity source itself:")
print(f"{'trend variant':<26}{'CAGR':>8}{'Sharpe':>8}{'maxDD':>9}{'skew_m':>8}{'COVID':>8}{'2022':>7}")
print("-"*72)
for v,lab in V:
    p,dts=run(v,0.0); m=met(p,dts)
    print(f"{lab:<26}{m[0]*100:>7.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>8.2f}"
          f"{crisis(p,dts,'2020-02-19','2020-03-23')*100:>7.1f}%{crisis(p,dts,'2022-01-01','2022-10-31')*100:>6.1f}%")
