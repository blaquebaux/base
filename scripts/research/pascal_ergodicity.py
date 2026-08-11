#!/usr/bin/python3
# PATH-A SKETCH — PASCAL'S WAGER / infinite-horizon utility with catastrophic risk (ergodicity econ).
# Pascal: a payoff with catastrophic magnitude dominates the decision regardless of its probability.
# In markets the catastrophe is RUIN (an absorbing -100%), and the infinite-horizon objective is the
# TIME-AVERAGE growth g(L) = E[log(1 + L r)], not the ensemble mean E[L r]. They diverge (ergodicity
# gap): leverage lifts the ensemble mean forever but drives the time-average through a Kelly peak to ruin.
#
# TESTS (SPY as the risky asset — it carries real fat-tail days incl. the 2020 crash; 2016-2026 SIP daily):
#  1. Ensemble mean vs time-average growth vs maxDD, by leverage L (the ergodicity gap + the Kelly peak).
#  2. Empirical fat-tailed optimal leverage L* vs a Gaussian with the same mean/vol (fat tails cap L*).
#  3. Pascal's catastrophe: inject ONE -30% day and watch L* collapse; report the leverage that a -50%
#     absorbing drawdown rules out on the actual path.
#  + the tame-book trap: the diversified spine book has NO catastrophe in-sample, so its naive time-average
#    Kelly runs off the top of the grid — precisely why an in-sample optimum is a Pascal trap.
#
# FINDING: the time-average optimum is finite, far below the ensemble (which never turns down). The
# subtle, honest part: the IN-SAMPLE fat-tail gap is small (SPY L* ~4.75 vs Gaussian ~5.0) — the sample
# under-represents the tail. The decisive cap is the catastrophe you must IMPUTE (Pascal): one -30% day
# drops L* to ~2.25, and a -50% absorbing barrier rules out leverage >= ~1.75x outright. The diversified
# spine book's naive Kelly runs off the grid (>=10x) ONLY because the sample holds no catastrophe — an
# in-sample optimum is itself the Pascal trap. Net: cap leverage and hedge the tail regardless of positive EV.
#
# RESULTS AS TESTED (2016-2026): SPY time-avg L* ~4.75 vs Gaussian ~5.0 (in-sample fat tails barely move
#   it); one imputed -30% day -> L* ~2.25 and a -50% barrier rules out >=1.75x; diversified spine naive
#   L* runs off the grid (>=10x) — no in-sample catastrophe to punish it.
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
H={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
SPINE=["SPY","IEF","TLT","GLD","DBC","DBA"]
D={s:cl(s) for s in SPINE}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
M=np.array([[D[s][d] for s in SPINE] for d in ds],float); Rall=M[1:]/M[:-1]-1
spy=Rall[:,0]; book=Rall.mean(1)                      # SPY (fat-tailed) and the EW diversified spine book
def gtime(r,L): return float(np.mean(np.log(np.clip(1+L*r,1e-9,None)))*252)   # time-average (log) growth, ann
def ens(r,L):   return float(np.mean(L*r)*252)                                 # ensemble (arithmetic) growth
def maxdd(r,L): lvl=np.cumprod(1+L*r); return float((lvl/np.maximum.accumulate(lvl)-1).min())
Ls=np.arange(0.0,10.01,0.25)
def bestL(r): g=[gtime(r,L) for L in Ls]; return Ls[int(np.argmax(g))], max(g)
print("="*80,"\nPASCAL'S WAGER — infinite-horizon (time-average) growth under catastrophic risk\n"+"="*80)

print("\n1. ENSEMBLE vs TIME-AVERAGE growth of SPY, by leverage L (worst 1-day: {:.0f}%):".format(spy.min()*100))
print(f"   {'L':>4} {'ensemble (ann)':>15} {'time-avg (ann)':>15} {'maxDD':>8}")
for L in (1,2,3,4,6,8):
    print(f"   {L:>4} {ens(spy,L)*100:>14.1f}% {gtime(spy,L)*100:>14.1f}% {maxdd(spy,L)*100:>7.0f}%")
print("   -> ensemble mean rises with L forever; the time-average peaks then collapses (the ergodicity gap).")

Le,ge=bestL(spy)
rng=np.random.default_rng(0); G=rng.normal(spy.mean(),spy.std(),size=400_000)
Lg=Ls[int(np.argmax([gtime(G,L) for L in Ls]))]
print("\n2. OPTIMAL (time-average) LEVERAGE — fat tails cap it below Gaussian-Kelly:")
print(f"   empirical SPY (real tails): L* = {Le:.2f}  (time-avg growth {ge*100:+.1f}%/yr)")
print(f"   Gaussian same mu,sigma    : L* = {Lg:.2f}  <- higher: the Gaussian never sees the crash days")

Lc=bestL(np.append(spy,-0.30))[0]
ruled=[L for L in Ls if maxdd(spy,L)<=-0.50]
print("\n3. PASCAL'S CATASTROPHE — add ONE -30% day (prob ~1/2600):")
print(f"   L* drops {Le:.2f} -> {Lc:.2f}  (a single tail day, at tiny probability, pulls safe leverage down)")
print(f"   a -50% absorbing drawdown rules out all leverage >= {min(ruled):.2f}x on the actual SPY path")

Lb=bestL(book)[0]
print("\n+  THE TAME-BOOK TRAP — the diversified spine book (worst 1-day {:.0f}%):".format(book.min()*100))
print(f"   naive in-sample time-average L* = {Lb:.2f}" + ("  (runs off the top of the grid)" if Lb>=Ls[-1] else ""))
print("   -> its Kelly looks huge ONLY because the sample holds no catastrophe: an in-sample optimum is a Pascal trap.")

print("\nVERDICT: the time-average optimum is finite, far below the ensemble mean (which never turns down).")
print(f"But the IN-SAMPLE fat-tail gap is small (SPY L* {Le:.1f} vs Gaussian {Lg:.1f}) — the sample under-represents")
print("the tail. The decisive cap is the catastrophe you must IMPUTE (Pascal): one -30% day drops L* to")
print(f"{Lc:.1f} and a -50% barrier rules out the upper range outright; the tame diversified book's huge naive")
print("Kelly (>=10x) is the trap itself. Cap leverage and hedge the tail regardless of positive EV (the ruin law).")
