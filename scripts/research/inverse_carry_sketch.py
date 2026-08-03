#!/usr/bin/python3
# PATH-A SKETCH — the INVERSE carry sleeve (short high-carry / long low-carry = pay the premium, get
# crash protection) as a second convex tail hedge alongside VIXY. Does short-credit/duration catch the
# rate/credit crises (2022) that VIXY's vol-spike hedge misses? Not validated.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s,adj):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment={adj}&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
CARRY=["SPY","IEF","TLT","LQD","HYG","EMB","GLD"]
ALL={s:fetch(s,"all") for s in CARRY+["BIL","VIXY"]}; SPL={s:fetch(s,"split") for s in CARRY}
D=sorted(set.intersection(*[set(ALL[s]) for s in CARRY+["BIL","VIXY"]], *[set(SPL[s]) for s in CARRY]))
Ca=np.array([[ALL[s][d] for s in CARRY] for d in D],float); Cs=np.array([[SPL[s][d] for s in CARRY] for d in D],float)
Rc=(Ca[1:]/Ca[:-1]-1.0); DTS=D[1:]; MOM,HL,VS,SVOL,CAP=252,21,60,0.08,1.5
vixy=np.array([ALL["VIXY"][d] for d in D],float); bil=np.array([ALL["BIL"][d] for d in D],float)
Rv=vixy[1:]/vixy[:-1]-1; Rb=bil[1:]/bil[:-1]-1; T=len(Rc)
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);TT,N=Rm.shape;o=np.empty((TT,N));v=Rm[0]**2
    for t in range(TT):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
SV=ewma_vol(Rc,HL)
CY=np.zeros((T,len(CARRY)))
for t in range(MOM,T):
    for j in range(len(CARRY)): CY[t,j]=(Ca[t+1,j]/Ca[t+1-MOM,j]-1)-(Cs[t+1,j]/Cs[t+1-MOM,j]-1)
def carry_pnl():
    lam=1-2/(VS+1); s2=0.0; pv=np.zeros(len(CARRY)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        if n>0:
            r=float(pv@Rc[t]); s2=r**2 if n==1 else lam*s2+(1-lam)*r**2
        z=CY[t]-CY[t].mean(); raw=z/np.maximum(SV[t],1e-12); g=np.abs(raw).sum(); w=raw/g if g>0 else np.zeros(len(CARRY))
        ex=CAP if (n==0 or s2<=1e-16) else min(CAP,SVOL/np.sqrt(s2*252))
        pnl.append(float((ex*w)@Rc[t+1])); idx.append(t+1); pv=w; n+=1
    return np.array(pnl),idx
cp,idx=carry_pnl(); dts=[DTS[j] for j in idx]
vix=np.array([Rv[j] for j in idx]); bl=np.array([Rb[j] for j in idx])
inv=-cp                                        # inverse carry = short high-carry / long low-carry
def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def met(p):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,(cum/np.maximum.accumulate(cum)-1).min(),skew(p)
def crisis(p,a,b):m=[k for k in range(len(p)) if a<=dts[k]<=b];return np.prod(1+p[np.array(m)])-1 if m else 0
def corr(a,b): return float(np.corrcoef(a,b)[0,1])

print(f"window {dts[0]}..{dts[-1]}   corr(inverse-carry, VIXY) = {corr(inv,vix):+.2f}\n")
print(f"{'portfolio':<34}{'CAGR':>8}{'maxDD':>9}{'skew':>7}{'Volmag18':>10}{'COVID':>8}{'2022':>8}")
print("-"*84)
combo = 0.5*vix + 0.5*inv                      # two-hedge convex engine (vol-spike + credit/rate)
rows=[
 ("carry (long premium)",cp),
 ("INVERSE carry (short premium)",inv),
 ("VIXY (vol-spike hedge)",vix),
 ("bills 90 / VIXY 10",0.9*bl+0.1*vix),
 ("bills 90 / inverse-carry 10",0.9*bl+0.1*inv),
 ("bills 90 / (VIXY+invCarry) 10",0.9*bl+0.1*combo),
 ("bills 80 / (VIXY+invCarry) 20",0.8*bl+0.2*combo),
]
for lab,p in rows:
    m=met(p)
    print(f"{lab:<34}{m[0]*100:>7.0f}%{m[1]*100:>8.0f}%{m[2]:>7.2f}"
          f"{crisis(p,'2018-02-01','2018-02-28')*100:>9.0f}%{crisis(p,'2020-02-19','2020-03-23')*100:>7.0f}%{crisis(p,'2022-01-01','2022-10-31')*100:>7.0f}%")
