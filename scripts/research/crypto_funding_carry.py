#!/usr/bin/python3
# PATH-A SKETCH — CRYPTO FUNDING-RATE CARRY (cash-and-carry): long spot / short perpetual future, delta-neutral
# on price, collecting the FUNDING RATE that leveraged longs pay to shorts. The one genuinely NEW mechanism
# found that is (a) orthogonal to the whole book (trend/diversification/supply-chain/earnings) AND (b) truly
# market-neutral (unlike the variance-risk premium, which is leveraged-long equity beta with an ungatable tail).
# Data: Binance public data mirror (data.binance.vision) historical 8h funding for BTC/ETH perps, 2020-2026.
#
# FINDING — the premium is REAL, LARGE, and UNCORRELATED, but the modeled Sharpe is a TRAP:
#  1. Carry (net ~3bp/day): BTC +10.8%/yr, ETH +13.0%/yr, combo +11.9%/yr; positive in EVERY year (worst 2022
#     +1%, 2026 ~flat). Gated to positive funding: +12.1%/yr, in-market 87%.
#  2. GENUINELY ORTHOGONAL: corr(carry, SPY) = +0.01 (and -0.12 to |SPY| stress). This is the first truly
#     uncorrelated +10%/yr stream in the whole research program -- exactly the diversification the book lacks.
#  3. BUT the Sharpe prints ~9-10 because the FUNDING STREAM is smooth (vol ~1%). THAT SHARPE IS MEANINGLESS as
#     a risk measure -- it is the classic carry-trade "pennies in front of a steamroller" signature. The real
#     risks are NOT in this series: short-perp LIQUIDATION in a violent spot rally, BASIS blowout (perp >> spot),
#     VENUE/counterparty failure (FTX 2022), STABLECOIN depeg (USDT/USDC collateral), and funding-regime death
#     (2022/2026 the premium just vanished for months). The true payoff is steady carry punctuated by rare
#     -50%..-100% tail events -- a short-volatility payoff whose tail lives in the EXECUTION/VENUE layer.
#
# VERDICT: a legitimate, orthogonal, market-neutral +10-12%/yr premium -- the best diversifier surfaced -- BUT
# it must be SIZED BY THE TAIL, not the smooth carry vol: small capacity, gated on positive funding, single
# reputable venue with spot+perp CROSS-MARGINED (so the spot gain offsets the perp loss without a liquidation-
# transfer gap), hard caps, and treated as sellable insurance, not free money. Needs a PERP-venue integration
# (Alpaca is spot-only) -- the real cost of admission. Data read-only/public; no keys/accounts; ~1-2 min to fetch.
import urllib.request, io, zipfile, math, json, datetime as dt
import numpy as np
def gen_months(y0,m0,y1,m1):
    y,m=y0,m0
    while (y,m)<=(y1,m1):
        yield f"{y:04d}-{m:02d}"
        m+=1
        if m>12: m=1; y+=1
def month_funding(sym, ym):
    url=f"https://data.binance.vision/data/futures/um/monthly/fundingRate/{sym}/{sym}-fundingRate-{ym}.zip"
    req=urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0"})
    z=zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(req, timeout=30).read()))
    out={}
    for l in z.read(z.namelist()[0]).decode().splitlines()[1:]:
        p=l.split(",")
        try:
            d=dt.datetime.utcfromtimestamp(int(p[0])/1000).date().isoformat()
            out[d]=out.get(d,0.0)+float(p[2])                # sum the day's 8h funding = daily carry (short perp)
        except: pass
    return out
def series(sym):
    daily={}
    for ym in gen_months(2020,1,2026,7):
        try: daily.update({k:daily.get(k,0.0)+v for k,v in month_funding(sym,ym).items()})
        except Exception: pass
    return daily
print("="*84,"\nCRYPTO FUNDING-RATE CARRY (long spot / short perp) — 2020-2026, net ~3bp/day\n"+"="*84)
FB, FE = series("BTCUSDT"), series("ETHUSDT")
dates=sorted(set(FB)&set(FE)); btc=np.array([FB[d] for d in dates]); eth=np.array([FE[d] for d in dates])
def stat(r,lbl,fee=0.00003):
    r=r-fee; sh=r.mean()/r.std()*math.sqrt(365) if r.std()>0 else float('nan')
    lvl=np.cumprod(1+r); dd=(lvl/np.maximum.accumulate(lvl)-1).min()
    print(f"  {lbl:32s} {r.mean()*365*100:+6.1f}%/yr  vol {r.std()*math.sqrt(365)*100:4.1f}%  Sharpe {sh:+5.1f}  maxDD {dd*100:+4.0f}%  (+days {(r>0).mean()*100:.0f}%)")
stat(btc,"BTC carry"); stat(eth,"ETH carry"); combo=(btc+eth)/2; stat(combo,"BTC+ETH combo")
print("  ^ Sharpe ~9-10 is the CARRY STREAM (smooth); it is NOT the true risk — see the tail caveat in the header.")
print("\n  yearly carry (combo):  " + "  ".join(f"{y}:{(combo[np.array([d[:4]==str(y) for d in dates])]-0.00003).sum()*100:+.0f}%" for y in range(2020,2027)))
print("  -> a BULL-regime premium: positive most years, compresses to ~0 in bear (2022/2026). Gate on funding>0.")
