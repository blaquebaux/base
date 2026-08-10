#!/usr/bin/python3
# PATH-A SKETCH — NEGATIVE TEST of the law "you can't systematically SHORT momentum-driven strength."
# The one-sided claim invites its inverse: if shorting strength fails, does going LONG it succeed —
# and if so, is that real alpha or just beta? Tested two ways: broad single names (survivorship-tilted)
# and 9 sector ETFs (survivorship-FREE), 2016-2026, 126d rank / 21d rebal / 5bp, quintile books.
#
# FINDINGS:
#  1. The asymmetry is real and robust. SHORTING strength is ruin in BOTH universes (single names
#     Sharpe -1.33, maxDD -96%; sectors -0.70, -88%). The LONG side simply survives. So yes — long
#     is the survivable side; the law is one-directional, exactly as stated.
#  2. But "long strength" is NOT winner-selection alpha. Survivorship-FREE (sectors), long-winners is
#     just beta (beta 0.95, alpha +0.8%/yr ~ 0) and actually LAGS equal-weight (+0.66 vs +0.82) and
#     SPY (+0.90). The single-name "+13%/yr alpha" is survivorship: ranking 40 known survivors by
#     momentum front-loads the ones that kept winning. And LONG-losers is positive too (+0.94 / +0.48)
#     -- because the market's drift is up, being long ANYTHING beats shorting. Direction (long vs
#     short) dominates selection (winners vs losers).
#  3. The durable, real edge from "strength" is TREND as convexity, not the cross-section: a
#     time-series trend overlay (hold each name only while its own trend is up) cuts single-name
#     drawdown -34% -> -30% at similar Sharpe -- the family's "convexity is free (trend)" law.
#
# REFINED LAW: you can't short momentum-driven strength (it's ruin); you CAN be long it and survive,
# but that is the equity risk premium, not selection alpha -- survivorship-free, long-strength is just
# beta and even lags equal-weight. Ride strength as TREND convexity; size momentum as a beta tilt,
# never pay up for winner-picking as if it were alpha.
#
# RESULTS AS TESTED (2016-2026, Sharpe / CAGR / maxDD):
#   SINGLE NAMES:  LONG-winners +1.29/+30%/-36% | SHORT-winners -1.33/-28%/-96% | LONG-losers +0.94/+21%/-40%
#                  EW-hold +1.21/+20%/-34% | SPY +0.90/+15%/-34% | long-strength beta +1.00 alpha +13.2%/yr (survivorship)
#                  TREND overlay +1.17/+19%/-30%
#   SECTOR ETFs:   LONG-winners +0.66/+14%/-31% | SHORT-winners -0.70/-18%/-88% | LONG-losers +0.48/+9%/-66%
#                  EW-hold +0.82/+13%/-37% | SPY +0.90/+15%/-34% | long-strength beta +0.95 alpha +0.8%/yr (~0, just beta)
#                  TREND overlay +0.66/+10%/-36%
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
NAMES=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","JPM","BAC","GS","XOM","CVX","COP","JNJ","PFE","MRK","LLY",
"PG","KO","WMT","COST","HD","MCD","CAT","BA","GE","LMT","NEE","DUK","SO","AMT","FCX","NEM","GOLD","T","VZ","DIS","UNH","V","MA"]
SECT=["XLK","XLF","XLE","XLV","XLI","XLY","XLP","XLU","XLB"]
L=126
def panel(syms):
    D={s:fetch(s) for s in syms+["SPY"]}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
    M=np.array([[D[s][d] for s in syms] for d in ds],float); spy=np.array([D["SPY"][d] for d in ds]); return M,spy
def met(r):
    r=r[np.isfinite(r)]; sd=r.std(); sh=r.mean()/sd*math.sqrt(252) if sd>0 else float('nan')
    lvl=np.cumprod(1+r); dd=(lvl/np.maximum.accumulate(lvl)-1).min(); return sh,lvl[-1]**(252/len(r))-1,dd
def strat(M,side,look=L,reb=21,cost=5.0,q=0.2):
    R=M[1:]/M[:-1]-1; T,N=R.shape; k=max(1,int(N*q)); wp=np.zeros(N); pnl=[]; c=cost/1e4
    for t in range(look,T-1):
        if (t-look)%reb==0:
            o=np.argsort(M[t]/M[t-look]-1); w=np.zeros(N)
            if side=="long_top": w[o[-k:]]=1/k
            elif side=="short_top": w[o[-k:]]=-1/k
            elif side=="long_bottom": w[o[:k]]=1/k
        else: w=wp
        pnl.append(float(np.nansum(w*R[t+1]))-np.abs(w-wp).sum()*c); wp=w
    return np.array(pnl)
def trend_overlay(M,look=200,cost=5.0):
    R=M[1:]/M[:-1]-1; T,N=R.shape; wp=np.zeros(N); pnl=[]; c=cost/1e4
    for t in range(look,T-1):
        up=(M[t]/M[t-look]-1)>0; w=up/max(1,up.sum())
        pnl.append(float(np.nansum(w*R[t+1]))-np.abs(w-wp).sum()*c); wp=w
    return np.array(pnl)
for label,syms in [("SINGLE NAMES (survivorship-tilted)",NAMES),("SECTOR ETFs (survivorship-free)",SECT)]:
    M,spy=panel(syms); R=M[1:]/M[:-1]-1; sr=spy[1:]/spy[:-1]-1
    print("="*82,f"\n{label}\n"+"="*82)
    rows=[("LONG strongest (ride winners)",met(strat(M,"long_top"))),
          ("SHORT strongest (fade winners)",met(strat(M,"short_top"))),
          ("LONG weakest (buy losers)",met(strat(M,"long_bottom"))),
          ("EW hold (own everything)",met(R[L:].mean(1))),("SPY (benchmark)",met(sr[L:]))]
    print(f"  {'construction':30s} {'Sharpe':>7s} {'CAGR':>7s} {'maxDD':>7s}")
    for nm,(sh,cg,dd) in rows:
        tag="   <- the law: fails" if nm.startswith("SHORT") else ""
        print(f"  {nm:30s} {sh:+7.2f} {cg*100:+6.0f}% {dd*100:+6.0f}%{tag}")
    def ab(pnl):
        x=sr[L+1:L+1+len(pnl)]; n=min(len(x),len(pnl)); x,y=x[:n],pnl[:n]
        beta=np.cov(x,y,ddof=1)[0,1]/np.var(x,ddof=1); return beta,(y.mean()-beta*x.mean())*252,np.corrcoef(x,y)[0,1]
    bw=ab(R[L+1:].mean(1)); bL=ab(strat(M,"long_top"))
    print(f"  -> sanity EW-hold vs SPY: beta {bw[0]:+.2f} (corr {bw[2]:+.2f}) — ~1 as expected")
    print(f"  -> LONG-strength vs SPY:  beta {bL[0]:+.2f}  alpha {bL[1]*100:+.1f}%/yr  corr {bL[2]:+.2f}  (real edge, or leveraged beta?)")
    tr=met(trend_overlay(M)); print(f"  TREND overlay (long-if-own-trend-up, else cash): Sharpe {tr[0]:+.2f}  CAGR {tr[1]*100:+.0f}%  maxDD {tr[2]*100:+.0f}%")
print("\nVERDICT: shorting strength is ruin (both universes); long survives — but survivorship-free that")
print("is just beta (long-winners lags equal-weight), and being long LOSERS also profits. Direction beats")
print("selection. The tradeable residue of 'strength' is TREND convexity, not winner-picking alpha.")
