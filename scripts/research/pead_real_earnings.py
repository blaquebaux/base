#!/usr/bin/python3
# PATH-A SKETCH — REAL-EARNINGS PEAD: does post-earnings drift survive on the ACTUAL surprise?
# The salvage_lab tested earnings via an overnight-GAP proxy and the long-short came out dead (+0.11%/20d)
# — because a big gap conflates the surprise with the drawdown-BOUNCE of down-gappers. This redoes it on
# the REAL earnings surprise (yfinance EPS actual vs estimate) + correct AMC/BMO timing (enter only after
# the reaction is priced). 40 liquid large caps, 2016-2026, SIP daily (adjusted). Net of cost.
#
# FINDING: on the real surprise the drift is MONOTONIC and tradeable — bigger surprise -> bigger drift.
#   long-short (top-third − bottom-third surprise), net: +0.79%/20d, +1.51%/60d; long-only top-third
#   +6.78%/60d vs +5.28% unconditional (+1.51% excess). Sorting on the announcement REACTION (the
#   gap-proxy analog) is much weaker (+0.50%), confirming why the pure-gap version looked dead: the
#   real surprise separates the signal from the down-reaction bounce. So the earnings-CONDITIONING
#   salvage genuinely works — a real, small, mostly long-only earnings-drift tilt (the cleanest rescue
#   of a null: Bio's event-driven remit becomes a systematic post-earnings-drift overlay). Caveat: large
#   caps only (PEAD is stronger in smaller caps); ~1.5%/60d is a modest tilt, not a spine-grade sleeve.
#
# RESULTS AS TESTED (2016-2026, 1669 events, 40 names):
#   surprise%-sort 20d fwd: bottom +1.09% | top +2.28% (uncond +1.68%) -> LS net +0.79%
#   surprise%-sort 60d fwd: bottom +4.87% | top +6.78% (uncond +5.28%) -> LS net +1.51%
#   reaction-sort (gap analog) LS net: 20d +0.50% | 60d +0.51%   (weaker — the gap proxy was too noisy)
#
# DEPENDENCY: yfinance (earnings dates + surprise). ~2-4 min (40 rate-limited calls). Keys from env only.
import os, json, urllib.request, math, bisect, warnings
import numpy as np
warnings.filterwarnings("ignore")
import yfinance as yf
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def closes(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2015-06-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
U=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG","XOM","JNJ",
"COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL","DIS","GS","MS","CAT","HON","LLY","ABBV","TMO","NKE"]
COST=0.001; ev=[]; nfail=0
for s in U:
    try:
        px=closes(s); ds=sorted(px); arr=[px[d] for d in ds]
        ed=yf.Ticker(s).get_earnings_dates(limit=60).dropna(subset=["Surprise(%)"])
    except Exception:
        nfail+=1; continue
    for ts,row in ed.iterrows():
        d=ts.date().isoformat()
        if d<"2016-01-01" or d>"2026-06-01": continue
        amc=ts.hour>=16
        ridx=bisect.bisect_right(ds,d) if amc else bisect.bisect_left(ds,d)   # first traded day after the reaction
        if ridx<1 or ridx+60>=len(ds): continue
        ev.append((float(row["Surprise(%)"]), arr[ridx]/arr[ridx-1]-1, arr[ridx+20]/arr[ridx]-1, arr[ridx+60]/arr[ridx]-1))
E=np.array(ev); sup,rea,f20,f60=E[:,0],E[:,1],E[:,2],E[:,3]
print("="*80,"\nREAL-EARNINGS PEAD — drift after the actual earnings surprise\n"+"="*80)
print(f"\n  {len(E)} earnings events across {len(U)-nfail} names (2016-2026), enter after the reaction is priced")
def terc(key,f,lbl):
    lo,hi=np.percentile(key,[33,67]); L=f[key<=lo]; Hh=f[key>=hi]; M=f[(key>lo)&(key<hi)]
    print(f"    by {lbl:16s}: bottom-third {L.mean()*100:+.2f}%  mid {M.mean()*100:+.2f}%  top-third {Hh.mean()*100:+.2f}%   (uncond {f.mean()*100:+.2f}%)")
    return Hh.mean(),L.mean()
print("\n1. SORT ON ACTUAL SURPRISE% — forward 20d / 60d drift:")
h20,l20=terc(sup,f20,"surprise% (20d)"); h60,l60=terc(sup,f60,"surprise% (60d)")
print(f"    PEAD long-short (top-third − bottom-third) NET of cost: 20d {((h20-l20)-4*COST)*100:+.2f}%   60d {((h60-l60)-4*COST)*100:+.2f}%")
print("\n2. SORT ON THE ANNOUNCEMENT REACTION (the gap-proxy analog):")
rh20,rl20=terc(rea,f20,"reaction (20d)"); rh60,rl60=terc(rea,f60,"reaction (60d)")
print(f"    long-short NET of cost: 20d {((rh20-rl20)-4*COST)*100:+.2f}%   60d {((rh60-rl60)-4*COST)*100:+.2f}%")
print("\nVERDICT: on the REAL surprise, PEAD is monotonic and tradeable (LS +0.79%/20d, +1.51%/60d net) —")
print("the earnings-conditioning salvage works where the gap proxy (+0.11%) could not. A genuine but small,")
print("mostly long-only earnings-drift tilt (Bio's event remit, systematized). Large-cap only; not spine-grade.")
