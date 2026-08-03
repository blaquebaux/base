#!/usr/bin/python3
# PATH-A SKETCH — does CARRY change the CURVEBALL? Carry (negative-skew, earns premium, crashes) is
# the mirror of the curveball (positive-skew, bleeds premium, explodes). Test a barbell whose EARNING
# sleeve is carry instead of bills, paired with the convex engine (VIXY). Not validated.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s,adj):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment={adj}&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
CARRY=["SPY","IEF","TLT","LQD","HYG","EMB","GLD"]; EXTRA=["BIL","VIXY"]
ALL={s:fetch(s,"all") for s in CARRY+EXTRA}; SPL={s:fetch(s,"split") for s in CARRY}
D=sorted(set.intersection(*[set(ALL[s]) for s in CARRY+EXTRA], *[set(SPL[s]) for s in CARRY]))
Ca=np.array([[ALL[s][d] for s in CARRY] for d in D],float); Cs=np.array([[SPL[s][d] for s in CARRY] for d in D],float)
Rc=(Ca[1:]/Ca[:-1]-1.0); DTS=D[1:]; MOM,HL,VS,SVOL,CAP=252,21,60,0.08,1.5
vixy=np.array([ALL["VIXY"][d] for d in D],float); bil=np.array([ALL["BIL"][d] for d in D],float)
Rv=vixy[1:]/vixy[:-1]-1; Rb=bil[1:]/bil[:-1]-1
T=len(Rc)
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);TT,N=Rm.shape;o=np.empty((TT,N));v=Rm[0]**2
    for t in range(TT):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
SV=ewma_vol(Rc,HL)
CY=np.zeros((T,len(CARRY)))
for t in range(MOM,T):
    for j in range(len(CARRY)):
        CY[t,j]=(Ca[t+1,j]/Ca[t+1-MOM,j]-1)-(Cs[t+1,j]/Cs[t+1-MOM,j]-1)
# standalone carry sleeve P&L (vol-targeted), aligned to dts
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
vix=np.array([Rv[j] for j in idx]); bl=np.array([Rb[j] for j in idx])   # aligned convex + safe returns

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def monthly(p):
    o={};[o.setdefault(dts[k][:7],[]).append(p[k]) for k in range(len(p))];return np.array([np.prod([1+r for r in v])-1 for v in o.values()])
def met(p):
    cum=np.cumprod(1+p);mo=monthly(p)
    return cum[-1]**(252/len(p))-1,(cum/np.maximum.accumulate(cum)-1).min(),skew(mo),100*(mo>0).mean(),np.median(mo)
def crisis(p,a,b):m=[k for k in range(len(p)) if a<=dts[k]<=b];return np.prod(1+p[np.array(m)])-1 if m else 0

def blend(safe, wsafe):     # wsafe in safe sleeve, (1-wsafe) in VIXY (the convex engine)
    return wsafe*safe + (1-wsafe)*vix

print(f"window {dts[0]}..{dts[-1]}\n")
print(f"{'portfolio (earning / convex)':<30}{'CAGR':>8}{'maxDD':>9}{'skew':>7}{'%posMo':>8}{'medMo':>8}{'COVID':>9}{'2022':>8}")
print("-"*88)
rows=[
 ("carry sleeve alone",cp,None),
 ("VIXY alone (the engine)",vix,None),
 ("classic: 90% bills / 10% VIXY", blend(bl,0.90),None),
 ("carry-funded: 90% carry / 10% VIXY", blend(cp,0.90),None),
 ("carry-funded: 80% carry / 20% VIXY", blend(cp,0.80),None),
 ("carry-funded: 70% carry / 30% VIXY", blend(cp,0.70),None),
]
for lab,p,_ in rows:
    m=met(p)
    print(f"{lab:<30}{m[0]*100:>7.0f}%{m[1]*100:>8.0f}%{m[2]:>7.2f}{m[3]:>7.0f}%{m[4]*100:>7.1f}%"
          f"{crisis(p,'2020-02-19','2020-03-23')*100:>8.0f}%{crisis(p,'2022-01-01','2022-10-31')*100:>7.0f}%")
