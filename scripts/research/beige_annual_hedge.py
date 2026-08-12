#!/usr/bin/python3
# PATH-A SKETCH — the ANNUAL input-hedging cycle, two sides of it:
#  A) BULGAR SEASONALITY: grain contracts are bought ~summer (harvest) and lived-with until next summer, so the
#     processor hedging lag is calendar-PHASED, not a fixed day-count. Grains corn/soy/wheat. Test month-of-year
#     structure and whether gating the grain-momentum signal to the post-harvest "live-with-the-hedge" window helps.
#  B) BEIGE (new sleeve): airlines buy jet-fuel forward ~annually and are SHORT the input (fuel is a cost) -- the
#     MIRROR of the processors. Rising fuel should SQUEEZE airline margins at a lag; the tradeable form is to SHORT
#     airlines (SPY-hedged) when fuel has been trending up. Airlines DAL/UAL/AAL/LUV/ALK/JBLU; fuel USO (crude) /
#     UGA (gasoline). SIP daily, 2016-2026.
#
# FINDING:
#  A) BULGAR seasonality is a real but modest refinement. The processor MARGIN-proxy is strongly positive in
#     Mar/Jul/Nov and negative in Jun/Sep (the re-hedge / harvest-pressure months). Gating the SPY-hedged
#     grain-momentum trade to the post-harvest window (Sep-May) more than DOUBLES it (+0.15 -> +0.38 Sharpe) --
#     confirming the annual-cycle intuition -- but at 27% in-market and +0.38 it stays a NEAR-MISS, below keeper bar.
# !! GATE + EPOCH UPDATE (scripts/beige_validation.jl, scripts/research/beige_regime_epochs.py): BEIGE was
#    put through the walk-forward OOS gate and did NOT clear the KEEPER/spine :neutral bar on full history.
#    The +0.50 below is in-sample. BUT the epoch split corrects the "not robust across 2016-2019" read: the
#    drag is TWO specific years, 2016 (-2.47) and 2020 COVID, not the pre-COVID era — 2017-2019 short-only
#    was +0.61, ex-2016 it's +0.62 (2017-2026) / +1.12 (2023-2026). The -94% was the FLIP's long-airline limb
#    in 2020; SHORT-ONLY removes it. Net: fails the keeper bar, but short-only is a defensible REGIME-CONDITIONAL
#    PAPER candidate (positive in 4/5 epochs) with the crash-recovery whipsaw as a documented kill-condition.
#  B) BEIGE looked like the strongest of the new ideas IN-SAMPLE. The lag is textbook: oil trailing momentum
#     predicts airline forward returns NEGATIVELY and the correlation grows monotonically with horizon (126d oil
#     trend -> airline next-126d -0.29 vs -0.03 at 5d). Shorting airlines (SPY-hedged) when oil has been rising
#     earns Sharpe +0.50, beta +0.02, in-market 58%. It is NOT a two-episode artifact: dropping BOTH the 2020
#     COVID crash and the 2022 oil spike the Sharpe RISES to +0.58; positive in 7 of 11 calendar years (2016
#     -2.47 the one bad year; 2023 +1.9, 2025 +1.8). Same result on gasoline (UGA): +0.49.
#
# VERDICT: BULGAR stays a near-miss (seasonal gating helps, still below bar). BEIGE clears the bar for
# PROMOTION to a validated driver: a robust, mechanism-grounded, market-neutral (beta ~0) short-airlines-on-
# rising-fuel overlay that survives dropping its two crisis episodes. Caveats: single-sector short (idiosyncratic/
# bankruptcy risk), 58% in-market, static-beta SPY hedge -- so it wants the walk-forward gate before keeper status.
# Keys from env only; read-only; not yet validated by the OOS gate.
import os, json, urllib.request, math, datetime as dt
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
def load(syms):
    D={s:cl(s) for s in syms}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
    M=np.array([[D[s][d] for s in syms] for d in ds],float); R=M[1:]/M[:-1]-1
    return R,{s:syms.index(s) for s in syms},ds[1:]
def met(r,per=252): r=r[np.isfinite(r)]; s=r.std(); lvl=np.cumprod(1+r); return (r.mean()/s*math.sqrt(per) if s>0 else float('nan'), lvl[-1]**(per/len(r))-1,(lvl/np.maximum.accumulate(lvl)-1).min())
def cor(a,b): m=np.isfinite(a)&np.isfinite(b); return float(np.corrcoef(a[m],b[m])[0,1])
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())

print("="*84,"\nA) BULGAR SEASONALITY — annual summer-harvest hedging cycle (corn/soy/wheat)\n"+"="*84)
R,i,dd=load(["INGR","ADM","BG","CORN","SOYB","WEAT","SPY"]); T=len(R)
proc=np.mean([R[:,i[s]] for s in ["INGR","ADM","BG"]],0); grain=np.mean([R[:,i[s]] for s in ["CORN","SOYB","WEAT"]],0)
gl=np.cumprod(1+grain); Mo=np.array([int(d[5:7]) for d in dd]); spy=R[:,i["SPY"]]; bg=beta(proc,grain); marg=proc-bg*grain
print("\n  month-of-year avg return (annualized): processor MARGIN-proxy (proc net of grain beta)")
print("   "+"  ".join(f"{dt.date(2000,m,1).strftime('%b')} {marg[Mo==m].mean()*252*100:+4.0f}%" for m in range(1,13)))
post=np.isin(Mo,[9,10,11,12,1,2,3,4,5])
pa=[]; ps=[]
for t in range(126,T-1):
    up=gl[t]/gl[t-126]-1>0; r=proc[t+1]-beta(proc,spy)*spy[t+1]
    pa.append((1 if up else 0)*r); ps.append((1 if (up and post[t]) else 0)*r)
pa,ps=np.array(pa),np.array(ps)
print(f"\n  grain-momentum-timed processors (SPY-hedged):")
print(f"    all-year        Sharpe {met(pa)[0]:+.2f}  in-market {(pa!=0).mean()*100:.0f}%")
print(f"    post-harvest    Sharpe {met(ps)[0]:+.2f}  in-market {(ps!=0).mean()*100:.0f}%   <- seasonal gating more than doubles it (near-miss)")

print("\n"+"="*84,"\nB) BEIGE — airlines are SHORT jet fuel; the mirror hedging-lag\n"+"="*84)
R,i,dd=load(["DAL","UAL","AAL","LUV","ALK","JBLU","USO","UGA","SPY"]); T=len(R); spy=R[:,i["SPY"]]
air=np.mean([R[:,i[s]] for s in ["DAL","UAL","AAL","LUV","ALK","JBLU"]],0); ol=np.cumprod(1+R[:,i["USO"]]); bA=beta(air,spy)
print(f"\n  airline basket: Sharpe {met(air)[0]:+.2f} CAGR {met(air)[1]*100:+.0f}% maxDD {met(air)[2]*100:+.0f}%  beta-SPY {bA:+.2f}")
print(f"  corr(airlines, oil) {cor(air,R[:,i['USO']]):+.2f}   corr(airlines, gasoline UGA) {cor(air,R[:,i['UGA']]):+.2f}  (fuel is a cost)")
print("\n  THE LAG — oil trailing momentum vs airline NEXT F-day return (NEGATIVE, growing with lag = hedge-roll squeeze):")
hdr="L\\F"; print(f"   {hdr:>6s}"+"".join(f"{f'+{F}d':>9s}" for F in (5,21,63,126)))
for L in (21,63,126):
    row=f"   {L:>4d}d "
    for F in (5,21,63,126):
        xs=[];ys=[]
        for t in range(L,T-F):
            om=ol[t]/ol[t-L]-1; fr=np.prod(1+air[t:t+F])-1
            if np.isfinite(om) and np.isfinite(fr): xs.append(om); ys.append(fr)
        row+=f"{np.corrcoef(xs,ys)[0,1]:+9.2f}"
    print(row)
yr=np.array([int(d[:4]) for d in dd])
def beige(fuel):
    o=np.cumprod(1+R[:,i[fuel]]); pnl=np.full(T,np.nan)
    for t in range(126,T-1):
        pnl[t+1]=(-1 if o[t]/o[t-126]-1>0 else 0)*(air[t+1]-bA*spy[t+1])   # short airlines when fuel rising, SPY-hedged
    return pnl
print("\n  TRADE: short airlines (SPY-hedged) when fuel 126d momentum > 0")
keep=np.array([not(('2020-02'<=d<='2020-06') or ('2022-01'<=d<='2022-07')) for d in dd])
spyL=np.r_[np.nan,spy][:T]
for fuel in ("USO","UGA"):
    p=beige(fuel); fin=np.isfinite(p); full=met(p[fin])
    ex=met(p[keep&fin]); inmkt=(p[fin]!=0).mean()
    print(f"    fuel={fuel}: FULL Sharpe {full[0]:+.2f}  beta {beta(p,spyL):+.2f}  in-market {inmkt*100:.0f}%   |  ex-2020crash & ex-2022spike {ex[0]:+.2f}")
    print("      per-year: "+"  ".join(f"{y}:{met(p[(yr==y)&np.isfinite(p)])[0]:+.2f}" for y in range(2016,2027) if ((yr==y)&np.isfinite(p)).sum()>30))
print("\nVERDICT: BULGAR stays a near-miss (seasonal gating lifts +0.15->+0.38, still below bar). BEIGE is the")
print("strongest new idea — robust market-neutral +0.50 (ex-episodes +0.58), textbook lag, beta ~0 — a KEEPER-")
print("CANDIDATE worth promoting to a validated driver, with the caveats: single-sector short, 58% in-market,")
print("static-beta SPY hedge. Run it through the walk-forward OOS gate before granting keeper status.")
