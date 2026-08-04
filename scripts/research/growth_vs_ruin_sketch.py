#!/usr/bin/python3
# PATH-A SKETCH — the growth-vs-ruin frontier. (A) Kelly-optimal leverage for the Spine at 3% vs 6.5%
# financing, from its REAL returns. (B) terminal-wealth distribution of a max-aggressive convex bet
# (VIXY, the reversed-curveball engine) via block-bootstrap Monte Carlo. Not validated.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
SP=["SPY","IEF","TLT","GLD","DBC","DBA"]; DATA={s:fetch(s) for s in SP+["VIXY"]}
D=sorted(set.intersection(*[set(DATA[s]) for s in SP+["VIXY"]]))
C=np.array([[DATA[s][d] for s in SP] for d in D],float); R=C[1:]/C[:-1]-1
vixy=np.array([DATA["VIXY"][d] for d in D],float); Rvix=vixy[1:]/vixy[:-1]-1
MOM,HL,VS,SVOL,CAP=252,21,60,0.08,1.5
def ewma_vol(Rm,hl):
    lam=0.5**(1/hl);T,N=Rm.shape;o=np.empty((T,N));v=Rm[0]**2
    for t in range(T):
        v=lam*v+(1-lam)*Rm[t]**2 if t else Rm[t]**2;o[t]=np.sqrt(np.maximum(v,1e-16))
    return o
def spine():
    T=len(R);SV=ewma_vol(R,HL);lam=1-2/(VS+1);b2=t2=0.;pbw=ptw=pbook=np.zeros(len(SP));n=0;pnl=[]
    for t in range(MOM,T-1):
        if n>0:
            rb=float(pbw@R[t]);rt=float(ptw@R[t]);b2=rb**2 if n==1 else lam*b2+(1-lam)*rb**2;t2=rt**2 if n==1 else lam*t2+(1-lam)*rt**2
        iv=1/np.maximum(SV[t],1e-12);bw=iv/iv.sum()
        s=np.sign(np.prod(1+R[t-MOM+1:t+1],axis=0)-1);raw=s/np.maximum(SV[t],1e-12);g=np.abs(raw).sum();tw=raw/g if g>0 else np.zeros(len(SP))
        ex=lambda x:CAP if(n==0 or x<=1e-16)else min(CAP,SVOL/np.sqrt(x*252))
        w=0.5*ex(b2)*bw+0.5*ex(t2)*tw
        mkt=R[:t+1].mean(axis=1);ci=np.cumprod(1+mkt);w*=(0.5 if(ci[-1]/ci.max()-1)<-0.08 else 1.0)
        pnl.append(float(w@R[t+1]));pbw,ptw,pbook,n=bw,tw,w,n+1
    return np.array(pnl)
sp=spine()
def metrics(r):
    cum=np.cumprod(1+r)
    if (1+r).min()<=0: return np.nan, -1.0  # ruin (a single ≥100% loss)
    return cum[-1]**(252/len(r))-1, (cum/np.maximum.accumulate(cum)-1).min()

print(f"Spine: CAGR {metrics(sp)[0]*100:.1f}%  vol {sp.std()*np.sqrt(252)*100:.1f}%  Sharpe {sp.mean()/sp.std()*np.sqrt(252):.2f}  maxDD {metrics(sp)[1]*100:.1f}%\n")
print("A) GROWTH vs LEVERAGE on the Spine (levered daily, financing the borrowed part):")
print(f"{'leverage':>9}{'CAGR @3%':>10}{'maxDD@3%':>10}{'CAGR @6.5%':>12}{'maxDD@6.5%':>11}")
print("-"*52)
best={0.03:(0,-9),0.065:(0,-9)}
for L in [0.5,1,1.5,2,3,4,5,6,8]:
    row=f"{L:>8.1f}x"
    for f in (0.03,0.065):
        rL=L*sp-(L-1)*f/252; cagr,dd=metrics(rL)
        if not np.isnan(cagr) and cagr>best[f][0]: best[f]=(cagr,L)
        row+=f"{cagr*100:>9.1f}%{dd*100:>9.0f}%" if f==0.03 else f"{cagr*100:>11.1f}%{dd*100:>10.0f}%"
    print(row)
print(f"\n  Kelly-optimal (max in-sample CAGR): {best[0.03][1]:.0f}x @3% financing  |  {best[0.065][1]:.0f}x @6.5% financing")
mu,sig=sp.mean()*252,sp.std()*np.sqrt(252)
print(f"  Gaussian Kelly (mu-f)/sig^2:        {(mu-0.03)/sig**2:.1f}x @3%       |  {(mu-0.065)/sig**2:.1f}x @6.5%")

print("\nB) TERMINAL WEALTH after 1yr (block-bootstrap MC, 5000 paths, start $1):")
def bootstrap(r, npaths=5000, horizon=252, block=21):
    rng=np.random.default_rng(7); out=np.empty(npaths)
    for i in range(npaths):
        idx=[];
        while len(idx)<horizon:
            s=rng.integers(0,len(r)-block); idx+=list(range(s,s+block))
        path=r[np.array(idx[:horizon])]
        out[i]=np.prod(1+np.maximum(path,-0.999))  # a ≥100% daily loss = wiped
    return out
def report(name,r):
    w=bootstrap(r);
    print(f"  {name:<26} median ${np.median(w):>6.2f}  mean ${w.mean():>7.2f}  P5 ${np.percentile(w,5):>5.2f}  P95 ${np.percentile(w,95):>7.2f}"
          f"  ruin(<$0.10) {100*(w<0.10).mean():>4.0f}%  >2x {100*(w>2).mean():>3.0f}%")
report("Spine (1x)", sp)
report("Spine (3x @6.5% fin)", 3*sp-2*0.065/252)
report("Max-aggressive (VIXY 100%)", Rvix[MOM:])
