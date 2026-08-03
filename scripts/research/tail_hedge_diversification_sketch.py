#!/usr/bin/python3
# PATH-A SKETCH — a DIVERSIFIED tail hedge across disaster TYPES, sized as one budgeted sliver.
# Four convex/regime hedges: VIXY (vol spike), short-HYG (credit crisis), short-TLT (rate shock),
# long-DBC (inflation). Each vol-targeted to a common 10% then equal-weighted. Does the blend catch
# every crisis type at a lower calm-market bleed than any single hedge? Not validated.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
SY=["VIXY","HYG","TLT","DBC","BIL"]; DATA={s:fetch(s) for s in SY}
D=sorted(set.intersection(*[set(DATA[s]) for s in SY]))
C=np.array([[DATA[s][d] for s in SY] for d in D],float); R=C[1:]/C[:-1]-1; DTS=D[1:]; IX={s:i for i,s in enumerate(SY)}
# the four disaster hedges (as return series)
hedges={"VIXY (vol spike)":R[:,IX["VIXY"]], "short-HYG (credit)":-R[:,IX["HYG"]],
        "short-TLT (rate)":-R[:,IX["TLT"]], "long-DBC (inflation)":R[:,IX["DBC"]]}
bil=R[:,IX["BIL"]]; T=len(R)
def voltarget(x, target=0.10, win=60, cap=3.0):  # scale each hedge to ~common vol so equal-weight = equal-risk
    out=np.zeros_like(x)
    for t in range(len(x)):
        lo=max(0,t-win); v=x[lo:t+1].std()*np.sqrt(252) if t>5 else target
        out[t]=min(cap, target/max(v,1e-6))*x[t]
    return out
scaled={k:voltarget(v) for k,v in hedges.items()}
sleeve=np.mean(np.vstack(list(scaled.values())),axis=0)   # diversified tail sleeve (equal-risk blend)

def skew(x):x=np.asarray(x);m=x.mean();s=x.std();return float(((x-m)**3).mean()/s**3) if s>0 else 0
def met(p):
    cum=np.cumprod(1+p);return cum[-1]**(252/len(p))-1,(cum/np.maximum.accumulate(cum)-1).min(),skew(p)
def cap_(p,a,b):m=[t for t,d in enumerate(DTS) if a<=d<=b];return np.prod(1+p[np.array(m)])-1 if m else 0
WIN={"Volmag18":("2018-02-01","2018-02-28"),"Q4-18":("2018-10-01","2018-12-31"),
     "COVID":("2020-02-19","2020-03-23"),"2022":("2022-01-01","2022-10-31")}

print("EACH HEDGE (vol-targeted) — which disaster does it catch? [CAGR = the calm-market bleed]")
print(f"{'hedge':<22}{'CAGR':>7}{'skew':>7}" + "".join(f"{k:>10}" for k in WIN))
print("-"*84)
for k,v in scaled.items():
    m=met(v); print(f"{k:<22}{m[0]*100:>6.0f}%{m[2]:>7.2f}" + "".join(f"{cap_(v,*WIN[w])*100:>9.0f}%" for w in WIN))
m=met(sleeve); print(f"{'DIVERSIFIED sleeve':<22}{m[0]*100:>6.0f}%{m[2]:>7.2f}" + "".join(f"{cap_(sleeve,*WIN[w])*100:>9.0f}%" for w in WIN))

print("\nHEDGE CORRELATIONS (deflation cluster vs inflation cluster):")
labs=list(hedges); M=np.corrcoef(np.vstack(list(hedges.values())))
print("           " + "".join(f"{l.split()[0][:8]:>9}" for l in labs))
for i,l in enumerate(labs):
    print(f"  {l.split()[0][:8]:<9}"+"".join(f"{M[i,j]:>9.2f}" for j in range(len(labs))))

print("\nBUDGETED BARBELL (bills + a 10% tail sliver):")
print(f"{'portfolio':<28}{'CAGR':>7}{'maxDD':>8}{'skew':>7}" + "".join(f"{k:>9}" for k in WIN))
print("-"*84)
for lab,p in [("bills 90 / VIXY 10", 0.9*bil+0.1*scaled["VIXY (vol spike)"]),
              ("bills 90 / diversified 10", 0.9*bil+0.1*sleeve),
              ("bills 80 / diversified 20", 0.8*bil+0.2*sleeve)]:
    m=met(p); print(f"{lab:<28}{m[0]*100:>6.1f}%{m[1]*100:>7.0f}%{m[2]:>7.2f}" + "".join(f"{cap_(p,*WIN[w])*100:>8.0f}%" for w in WIN))
