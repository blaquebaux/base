#!/usr/bin/python3
# PATH-A SKETCH — a CARRY sleeve added to base+trend (the "Holy Grail" test: is carry a genuinely
# UNCORRELATED return stream that lifts risk-adjusted return?). Not validated.
# Carry proxy = trailing-12mo income yield (total-return minus price-return adjustment), used only on
# assets where income ≈ carry (bonds/credit/equity/gold; commodities excluded — their income is
# collateral bill yield, not roll carry). Cross-sectional long high-carry / short low-carry.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s,adj):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment={adj}&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
BASE=["SPY","IEF","TLT","GLD","DBC","DBA"]                 # base + trend universe
CARRY=["SPY","IEF","TLT","LQD","HYG","EMB","GLD"]          # carry universe (income ≈ carry)
UNION=sorted(set(BASE)|set(CARRY))
ALL={s:fetch(s,"all") for s in UNION}; SPL={s:fetch(s,"split") for s in UNION}
D=sorted(set.intersection(*[set(ALL[s]) for s in UNION], *[set(SPL[s]) for s in UNION]))
Ca=np.array([[ALL[s][d] for s in UNION] for d in D],float)
Cs=np.array([[SPL[s][d] for s in UNION] for d in D],float)
R=(Ca[1:]/Ca[:-1]-1.0); DTS=D[1:]; IX={s:i for i,s in enumerate(UNION)}
T=len(R); bcol=[IX[s] for s in BASE]; ccol=[IX[s] for s in CARRY]
MOM,HL,VS,SVOL,CAP,COST=252,21,60,0.08,1.5,0.0002
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);TT,N=Rm.shape;o=np.empty((TT,N));v=Rm[0]**2
    for t in range(TT):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
SV=ewma_vol(R,HL)
# carry signal: trailing-252d income yield per carry asset (total-ret minus price-ret), aligned to R rows
CY=np.full((T,len(ccol)),0.0)
for t in range(MOM,T):
    for j,s in enumerate(CARRY):
        i=IX[s]
        tr=Ca[t+1,i]/Ca[t+1-MOM,i]-1; pr=Cs[t+1,i]/Cs[t+1-MOM,i]-1
        CY[t,j]=tr-pr

def sleeves(t):
    sigb=SV[t,bcol]; ivb=1/np.maximum(sigb,1e-12); base_w=ivb/ivb.sum()
    resp=np.mean([np.sign(np.prod(1+R[t-min(k,t+1)+1:t+1][:,bcol],axis=0)-1) for k in (63,126,252)],axis=0)
    raw=resp/np.maximum(sigb,1e-12); g=np.abs(raw).sum(); trend_w=raw/g if g>0 else np.zeros(len(bcol))
    sigc=SV[t,ccol]; z=CY[t]-CY[t].mean(); rawc=z/np.maximum(sigc,1e-12); gc=np.abs(rawc).sum()
    carry_w=rawc/gc if gc>0 else np.zeros(len(ccol))
    return base_w,trend_w,carry_w

def backtest(bwt):   # bwt: dict among {'base','trend','carry'} -> blend weight
    lam=1-2/(VS+1); s2={'base':0.,'trend':0.,'carry':0.}; pv={'base':np.zeros(len(bcol)),'trend':np.zeros(len(bcol)),'carry':np.zeros(len(ccol))}
    pbook=np.zeros(len(UNION)); n=0; pnl=[]; idx=[]
    for t in range(MOM,T-1):
        if n>0:
            for k,col in (('base',bcol),('trend',bcol),('carry',ccol)):
                rk=float(pv[k]@R[t,col]); s2[k]=rk**2 if n==1 else lam*s2[k]+(1-lam)*rk**2
        bw,tw,cw=sleeves(t); w={'base':bw,'trend':tw,'carry':cw}
        ex=lambda x: CAP if (n==0 or x<=1e-16) else min(CAP,SVOL/np.sqrt(x*252))
        book=np.zeros(len(UNION))
        for k,col in (('base',bcol),('trend',bcol),('carry',ccol)):
            if bwt.get(k,0)!=0: book[col]+=bwt[k]*ex(s2[k])*w[k]
        mkt=R[:t+1][:,bcol].mean(axis=1); ci=np.cumprod(1+mkt); book*=(0.5 if (ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(book@R[t+1])-COST*np.abs(book-pbook).sum()); idx.append(t+1)
        pv={'base':bw,'trend':tw,'carry':cw}; pbook=book; n+=1
    return np.array(pnl),[DTS[j] for j in idx]

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def met(p):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,p.std()*np.sqrt(252),(p.mean()/p.std()*np.sqrt(252) if p.std() else 0),(cum/np.maximum.accumulate(cum)-1).min(),skew(p)

print(f"window {DTS[MOM+1]}..{DTS[-1]}   union {UNION}\n")
b,_=backtest({'base':1}); tr,_=backtest({'trend':1}); cy,_=backtest({'carry':1})
print("STANDALONE SLEEVES:")
print(f"{'sleeve':<10}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew':>7}")
for nm,p in (("base",b),("trend",tr),("carry",cy)):
    m=met(p); print(f"{nm:<10}{m[0]*100:>7.1f}%{m[1]*100:>6.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>7.2f}")
C=np.corrcoef(np.vstack([b,tr,cy]))
print(f"\nSLEEVE P&L CORRELATIONS (the Holy-Grail test — lower is better):")
print(f"           base   trend   carry")
for i,nm in enumerate(("base","trend","carry")):
    print(f"  {nm:<7}" + "".join(f"{C[i,j]:>7.2f}" for j in range(3)))

print(f"\nBLENDED SPINE:")
print(f"{'configuration':<26}{'CAGR':>8}{'vol':>7}{'Sharpe':>8}{'maxDD':>9}{'skew':>7}")
for nm,bwt in (("base+trend (50/50)",{'base':.5,'trend':.5}),
               ("base+trend+carry (1/3)",{'base':1/3,'trend':1/3,'carry':1/3}),
               ("base+trend+carry (.4/.3/.3)",{'base':.4,'trend':.3,'carry':.3})):
    p,_=backtest(bwt); m=met(p)
    print(f"{nm:<26}{m[0]*100:>7.1f}%{m[1]*100:>6.1f}%{m[2]:>8.2f}{m[3]*100:>8.1f}%{m[4]:>7.2f}")
