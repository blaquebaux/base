#!/usr/bin/python3
# PATH-A SKETCH — Spine + a VOL-AWARE tail overlay (carry the VIXY hedge when vol is CHEAP, shed it
# when vol is dear). Judged on drawdown-reduction and skew, NOT Sharpe. Plus: the reversed barbell
# viewed MONTHLY vs quarterly. Not validated strategies.
import os, json, urllib.request
import numpy as np

K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]
H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day"
       f"&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40))
    return {b["t"][:10]:b["c"] for b in d.get("bars",{}).get(s,[])}

SPINE=["SPY","IEF","TLT","GLD","DBC","DBA"]; EXTRA=["VIXY","BIL"]
SY=SPINE+EXTRA; DATA={s:fetch(s) for s in SY}
DTS=sorted(set.intersection(*[set(DATA[s]) for s in SY]))
C=np.array([[DATA[s][d] for s in SY] for d in DTS],float)
R=(C[1:]/C[:-1]-1.0); DTS=DTS[1:]; IX={s:i for i,s in enumerate(SY)}
SVOL,CAP,HL,MOM,VS,COST=0.08,1.5,21,252,60,0.0002

def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);T,N=Rm.shape;o=np.empty((T,N));v=Rm[0]**2
    for t in range(T):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2; o[t]=np.sqrt(np.maximum(v,1e-16))
    return o

def spine():   # faithful single +DBA spine → (pnl, date-index aligned)
    col=[IX[s] for s in SPINE]; Rs=R[:,col]; T=len(Rs); sv=ewma_vol(Rs,HL); lam=1-2/(VS+1)
    b2=t2=0.0; pbw=ptw=pbook=np.zeros(len(col)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        if n>0:
            rb=float(pbw@Rs[t]); rt=float(ptw@Rs[t])
            b2=rb**2 if n==1 else lam*b2+(1-lam)*rb**2; t2=rt**2 if n==1 else lam*t2+(1-lam)*rt**2
        iv=1/np.maximum(sv[t],1e-12); bw=iv/iv.sum()
        raw=np.sign(np.prod(1+Rs[t-MOM+1:t+1],axis=0)-1)/np.maximum(sv[t],1e-12); g=np.abs(raw).sum()
        tw=raw/g if g>0 else np.zeros(len(col))
        ex=lambda s2: CAP if (n==0 or s2<=1e-16) else min(CAP,SVOL/np.sqrt(s2*252))
        w=0.5*ex(b2)*bw+0.5*ex(t2)*tw
        mkt=Rs[:t+1].mean(axis=1); ci=np.cumprod(1+mkt); w*=(0.5 if (ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(w@Rs[t+1])-COST*np.abs(w-pbook).sum()); idx.append(t+1)
        pbw,ptw,pbook,n=bw,tw,w,n+1
    return np.array(pnl),np.array(idx)

# vol-cheapness signal: SPY 21d realized vol, percentile within trailing year (low pct = cheap)
spy=R[:,IX["SPY"]]; T=len(spy); rv=np.full(T,np.nan)
for j in range(20,T): rv[j]=spy[j-20:j+1].std()*np.sqrt(252)
pct=np.full(T,0.5)
for j in range(272,T):
    w=rv[j-251:j+1]; pct[j]=np.mean(w<=rv[j])
HMIN,HMAX=0.01,0.12
hedge=HMIN+(HMAX-HMIN)*(1-pct)      # cheap vol → big hedge; dear vol → small

sp,idx=spine(); vixy=R[:,IX["VIXY"]]
dts=[DTS[j] for j in idx]
port_spine=sp
port_const=np.array([0.95*sp[k]+0.05*vixy[idx[k]] for k in range(len(sp))])
port_vaw  =np.array([(1-hedge[idx[k]])*sp[k]+hedge[idx[k]]*vixy[idx[k]] for k in range(len(sp))])
avg_h=np.mean([hedge[j] for j in idx])

def skew(x): x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def monthly(p):
    o={};[o.setdefault(dts[k][:7],[]).append(p[k]) for k in range(len(p))]
    return np.array([np.prod([1+r for r in v])-1 for v in o.values()])
def met(p):
    cum=np.cumprod(1+p);cagr=cum[-1]**(252/len(p))-1;dd=(cum/np.maximum.accumulate(cum)-1).min()
    return cagr,p.std()*np.sqrt(252),(p.mean()/p.std()*np.sqrt(252) if p.std() else 0),dd,skew(monthly(p)),monthly(p).min()
def crisis(p,a,b): m=[k for k in range(len(p)) if a<=dts[k]<=b]; return np.prod(1+p[np.array(m)])-1 if m else 0

print(f"Spine overlay window {dts[0]}..{dts[-1]}  ({len(sp)} days)   avg vol-aware hedge = {avg_h*100:.1f}%\n")
print(f"{'portfolio':<26}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew_m':>8}{'worstMo':>9}{'COVID':>8}{'2022':>7}")
print("-"*90)
for name,p in [("Spine (no hedge)",port_spine),("Spine + const 5% VIXY",port_const),("Spine + VOL-AWARE hedge",port_vaw)]:
    m=met(p); print(f"{name:<26}{m[0]*100:>7.1f}%{m[1]*100:>6.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>8.2f}{m[5]*100:>8.1f}%"
                     f"{crisis(p,'2020-02-19','2020-03-23')*100:>7.1f}%{crisis(p,'2022-01-01','2022-10-31')*100:>6.1f}%")

# ---- Task 2: the curveball viewed MONTHLY vs quarterly ----
print("\n=== Reversed barbell (10/90 BIL/VIXY): does viewing it MONTHLY help? ===")
def rev_dist(freq):
    idx2=[IX["BIL"],IX["VIXY"]]; w=np.array([0.1,0.9]); V=1;sub=w*V;port=[]
    def pk(d): return d[:7] if freq=="M" else f"{d[:4]}Q{(int(d[5:7])-1)//3}"
    for t in range(len(DTS)):
        sub=sub*(1+R[t][idx2]);nV=sub.sum();port.append(nV/V-1);V=nV
        if t+1<len(DTS) and pk(DTS[t+1])!=pk(DTS[t]): sub=w*V
    port=np.array(port); o={}
    for t,d in enumerate(DTS): o.setdefault(pk(d),[]).append(port[t])
    per=np.array([np.prod([1+r for r in v])-1 for v in o.values()])
    cum=np.cumprod(1+port)
    return per,cum[-1]**(252/len(port))-1,(cum/np.maximum.accumulate(cum)-1).min()
for freq,lab in [("M","MONTHLY"),("Q","quarterly")]:
    per,cagr,dd=rev_dist(freq)
    print(f"  {lab:9} reset: periods={len(per):3}  %positive={100*(per>0).mean():4.0f}%  median={np.median(per)*100:+6.1f}%  "
          f"mean={per.mean()*100:+6.1f}%  skew={skew(per):+.2f}  best={per.max()*100:+.0f}%  worst={per.min()*100:+.0f}%  "
          f"[compounded CAGR {cagr*100:.0f}%, maxDD {dd*100:.0f}%]")
