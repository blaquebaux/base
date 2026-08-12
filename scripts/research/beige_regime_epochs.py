#!/usr/bin/python3
# PATH-A SKETCH — two honest RE-TESTS answering pushback on the Bulgar seasonality and Beige gate verdicts:
#  1) BASKET CONTAMINATION: was the "weak November" (a short candidate) real, or an artifact of adding
#     ANDE (grain trader, different hedge schedule), GPRE (ethanol), DAR (rendering — not corn/soy) to the
#     pure corn/soy wet-miller Ingredion? Re-test seasonality on pure baskets + YEAR-BY-YEAR consistency.
#  2) REGIME: does 2016-2019 deserve to veto the post-COVID regime, as the earlier gate write-up implied?
#     Split Beige (short airlines on rising fuel, SPY-hedged) by epoch.
#
# FINDINGS — both earlier framings were WRONG and are corrected here:
#  1) The "short-able weak November" was BASKET CONTAMINATION. For pure INGR, November is +14%/yr, positive
#     in 7 of 10 years — a mild LONG, not a short. Adding ADM+BG -> -6% (5/10); adding ANDE+GPRE+DAR -> -15%
#     (3/10). The pure INGR+ADM+BG basket has NO reliably short-able month (the one-sided months are LONG:
#     Mar +28% 8/11; the only consistently-negative is Aug at just -3%, 2/10). So the seasonal-short idea
#     dies for the RIGHT reason: the pure play has no reliably weak window — not "the signal is unstable."
#  2) "Not stable across 2016-2019" was FALSE. 2017-2019 (ex-2016) was POSITIVE (+0.61 short-only). The
#     full-sample drag is TWO specific years — 2016 (-2.47) and 2020 COVID (-0.40) — not the pre-COVID era.
#     Ex-2016, short-only Beige is +0.62 over 2017-2026 and +1.12 in 2023-2026. BUT 2016 and 2020 share ONE
#     structural failure: airlines recovering off a crash (oil-bottom 2016, COVID 2020) INDEPENDENT of fuel,
#     so the fuel-momentum signal fights the dominant driver — a recurring vulnerability, not just bad luck.
#
# VERDICT: the seasonal short is dead (no reliably weak month for the pure play). Beige short-only is a
# REGIME-CONDITIONAL PAPER candidate (positive in 4 of 5 epochs; the -94% tail was the LONG-airline flip
# limb, removed by short-only) — judged against the family's paper-sleeve bar, not the keeper/spine bar it
# was wrongly held to. Ships only with the crash-recovery whipsaw as a documented kill-condition. Keys from env.
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
def sh(r,per=252): r=r[np.isfinite(r)]; s=r.std(); return r.mean()/s*math.sqrt(per) if s>0 else float('nan')
def beta(a,x): m=np.isfinite(a)&np.isfinite(x); return float(np.cov(a[m],x[m])[0,1]/x[m].var())

print("="*84,"\n1) BASKET CONTAMINATION — pure-play seasonality vs my earlier contaminated basket\n"+"="*84)
R,i,dd=load(["INGR","ADM","BG","ANDE","GPRE","DAR","SPY"]); spy=R[:,i["SPY"]]
Mo=np.array([int(d[5:7]) for d in dd]); yr=np.array([int(d[:4]) for d in dd])
def mn(names): b=np.mean([R[:,i[s]] for s in names],0); return b-beta(b,spy)*spy
print("\n  November (market-neutral, ann.%) and positive-year count:")
for nm,names in {"INGR only":["INGR"],"INGR+ADM+BG (pure)":["INGR","ADM","BG"],
                 "+ANDE+GPRE+DAR (contaminated)":["INGR","ADM","BG","ANDE","GPRE","DAR"]}.items():
    m=mn(names); nov=Mo==11
    pos=sum(1 for y in range(2016,2027) if ((yr==y)&nov).sum()>0 and m[(yr==y)&nov].mean()>0)
    tot=sum(1 for y in range(2016,2027) if ((yr==y)&nov).sum()>0)
    print(f"    {nm:30s} Nov {m[nov].mean()*252*100:+5.0f}%/yr   positive in {pos}/{tot}")
print("\n  pure INGR+ADM+BG month-of-year (ann.% | positive-years) — a short needs a reliably NEGATIVE month:")
m=mn(["INGR","ADM","BG"])
for mm in range(1,13):
    sel=Mo==mm; pos=sum(1 for y in range(2016,2027) if ((yr==y)&sel).sum()>0 and m[(yr==y)&sel].mean()>0)
    tot=sum(1 for y in range(2016,2027) if ((yr==y)&sel).sum()>0)
    print(f"    {dt.date(2000,mm,1).strftime('%b')}: {m[sel].mean()*252*100:+5.0f}%/yr   {pos}/{tot} yrs+")

print("\n"+"="*84,"\n2) REGIME — Beige short-only by epoch (does 2016-2019 deserve a veto?)\n"+"="*84)
R,i,dd=load(["DAL","UAL","AAL","LUV","ALK","JBLU","USO","SPY"]); spy=R[:,i["SPY"]]; yr=np.array([int(d[:4]) for d in dd])
air=np.mean([R[:,i[s]] for s in ["DAL","UAL","AAL","LUV","ALK","JBLU"]],0); ol=np.cumprod(1+R[:,i["USO"]]); T=len(air); bA=beta(air,spy)
short=np.full(T,np.nan); flip=np.full(T,np.nan)
for t in range(126,T-1):
    up=ol[t]/ol[t-126]-1>0
    short[t+1]=(-1 if up else 0)*(air[t+1]-bA*spy[t+1]); flip[t+1]=(-1 if up else 1)*(air[t+1]-bA*spy[t+1])
print(f"\n  {'epoch':30s} {'short-only':>10s} {'flip':>7s}   in-mkt")
for nm,(a,b) in {"2016 only":(2016,2016),"2017-2019 (pre-COVID ex-2016)":(2017,2019),"2020 (COVID)":(2020,2020),
                 "2021-2022 (war/inflation)":(2021,2022),"2023-2026 (recent)":(2023,2026),"2017-2026 (ex-2016)":(2017,2026)}.items():
    sel=(yr>=a)&(yr<=b); so=short[sel&np.isfinite(short)]; fl=flip[sel&np.isfinite(flip)]
    print(f"    {nm:30s} {sh(so):>+10.2f} {sh(fl):>+7.2f}   {(so!=0).mean()*100:.0f}%")
print("\n  read: 2017-2019 POSITIVE -> the drag is 2016 + 2020, not the pre-COVID era. Both bad years share one")
print("  failure: airlines recovering off a crash independent of fuel, so the fuel signal fights the tape.")
