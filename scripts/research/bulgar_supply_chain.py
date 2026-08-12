#!/usr/bin/python3
# PATH-A SKETCH — BULGAR: the food supply chain by pricing power, and whether "pricing power wins in
# inflation" is systematically tradeable. Domain thesis (ex-Ingredion): pricing power rises downstream
# (branded > specialty > commodity), so in input-cost inflation long branded / short commodity suppliers.
# Tiers: BRANDED (KO/PEP/GIS/K/MDLZ/HSY/CAG/CPB/KHC/MKC), SPECIALTY (IFF/INGR/FMC), COMMODITY
# (ADM/BG/TSN/DAR). Ag input cost proxied by DBA. SIP daily, 2016-2026.
#
# FINDING — the thesis is REVERSED by the mechanism (a genuine, domain-grounded insight):
#  1. The pricing-power gradient IS visible in the 2021-23 inflation episode (branded +18% vs commodity
#     -3% vs specialty -12%). But over the full decade the BEST tier was COMMODITY (+0.52 Sharpe / +10%
#     CAGR), not branded (+0.33/+4%); specialty was worst (+0.14/0%, beta 0.88 — squeezed both ways).
#  2. The long-branded / short-commodity spread LOSES (static Sharpe -0.18), and conditioning on ag
#     inflation makes it WORSE (-0.36): the spread earns -8%/yr in ag-RISING months vs +3%/yr when ag
#     falls — the OPPOSITE of the intuition.
#  3. WHY: the commodity processors are LONG the commodities they process (crush margins/revenues rise
#     when ag prices rise), while the branded companies are input-cost BUYERS (squeezed by rising inputs
#     until they can pass prices through, with a lag). So ag inflation HELPS the upstream processors and
#     HURTS the branded first — you cannot trade "long branded when input costs rise." The 2021-23 branded
#     outperformance was a specific demand-pull / supply-chain episode, not a repeatable DBA-conditioned signal.
#
# RESULTS AS TESTED (2016-2026): tier Sharpe/CAGR/2021-23: BRANDED +0.33/+4%/+18% | SPECIALTY
#   +0.14/0%/-12% | COMMODITY +0.52/+10%/-3%. Spread (long branded/short commodity): static -0.18,
#   gated-to-ag-rising -0.36; ag-rising -8%/yr vs ag-falling +3%/yr.
#
# VERDICT: NULL as a systematic sleeve — but a useful map. Pricing power is real in specific episodes,
# not a tradeable factor; and the honest, counter-intuitive edge is that the COMMODITY processors are
# the ag-inflation beneficiaries (they're long the commodity), not the branded. Keys from env; read-only.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
BRANDED=["KO","PEP","GIS","K","MDLZ","HSY","CAG","CPB","KHC","MKC"]; SPECIALTY=["IFF","INGR","FMC"]; COMMODITY=["ADM","BG","TSN","DAR"]
SY=BRANDED+SPECIALTY+COMMODITY+["DBA","SPY"]; D={s:cl(s) for s in SY}
ds=sorted(set.intersection(*[set(v) for v in D.values()])); M=np.array([[D[s][d] for s in SY] for d in ds],float)
R=M[1:]/M[:-1]-1; i={s:SY.index(s) for s in SY}; dd=ds[1:]; T=len(R); spy=R[:,i["SPY"]]
ew=lambda g: np.mean([R[:,i[s]] for s in g],0)
def met(r): r=r[np.isfinite(r)]; s=r.std(); lvl=np.cumprod(1+r); return (r.mean()/s*math.sqrt(252) if s>0 else float('nan'), lvl[-1]**(252/len(r))-1, (lvl/np.maximum.accumulate(lvl)-1).min())
def beta(r,sp): m=np.isfinite(r)&np.isfinite(sp); return float(np.cov(r[m],sp[m])[0,1]/sp[m].var()) if m.sum()>10 else 0.0
def win(r,lo,hi): m=[k for k,d in enumerate(dd) if lo<=d<=hi]; return float(np.prod(1+r[m])-1)
b,s,c=ew(BRANDED),ew(SPECIALTY),ew(COMMODITY)
print("="*82,"\nBULGAR — food supply chain by pricing power + input-cost inflation conditioning\n"+"="*82)
print("\n1. THE PRICING-POWER GRADIENT (does margin protection rise downstream?)")
print(f"  {'tier':26s} {'Sharpe':>7s} {'CAGR':>6s} {'maxDD':>7s} {'beta':>6s}  {'2021-23 inflation':>18s}")
for nm,r in [("BRANDED (KO/PEP/MDLZ..)",b),("SPECIALTY (IFF/INGR/FMC)",s),("COMMODITY (ADM/BG/TSN/DAR)",c),("SPY",spy),("DBA (ag input cost)",R[:,i['DBA']])]:
    m=met(r); print(f"  {nm:26s} {m[0]:+7.2f} {m[1]*100:+5.0f}% {m[2]*100:+6.0f}% {beta(r,spy):+6.2f}  {win(r,'2021-06-01','2023-06-01')*100:+17.0f}%")
sb,sc=b.std(),c.std(); spread=b-(sb/sc)*c
print("\n2. PRICING-POWER SPREAD (long BRANDED / short COMMODITY, vol-matched)")
print(f"  static: Sharpe {met(spread)[0]:+.2f}  maxDD {met(spread)[2]*100:+.0f}%  beta {beta(spread,spy):+.2f}  (market-neutral relative-value)")
print("\n3. CONDITION ON INPUT-COST (AG) INFLATION — DBA 63-day momentum as the signal")
dba=np.cumprod(1+R[:,i["DBA"]]); rising=np.array([1.0 if (t>=63 and dba[t]/dba[t-63]-1>0) else 0.0 for t in range(T)])
gated=rising[:-1]*spread[1:]; rotated=np.where(rising[:-1]>0,1,-1)*spread[1:]
print(f"  GATED (hold spread only when ag rising): Sharpe {met(gated)[0]:+.2f}   ROTATED (flip by ag): Sharpe {met(rotated)[0]:+.2f}")
print(f"  spread return: ag-RISING {np.nanmean(spread[1:][rising[:-1]>0])*252*100:+.0f}%/yr  vs  ag-FALLING {np.nanmean(spread[1:][rising[:-1]==0])*252*100:+.0f}%/yr")
print(f"  -> ag inflation HELPS commodity processors (they're long the commodity), HURTS branded first — thesis reversed")
print("\n4. THE TIER GRADIENT IS NOT MONOTONIC PRICING-POWER")
print(f"  long BRANDED / short SPECIALTY: Sharpe {met(b-(b.std()/s.std())*s)[0]:+.2f}   long SPECIALTY / short COMMODITY: Sharpe {met(s-(s.std()/c.std())*c)[0]:+.2f}")
print("\nVERDICT: NULL as a systematic sleeve. Pricing power shows up in specific episodes (2021-23), not as")
print("a tradeable factor; conditioning on ag inflation REVERSES it. The honest, counter-intuitive map:")
print("the COMMODITY processors (ADM/BG) are the ag-inflation beneficiaries — long the commodity — not the")
print("branded. A useful supply-chain map for sizing/hedging, not a standalone edge.")
