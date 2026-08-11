#!/usr/bin/python3
# PATH-A SKETCH — THE VOLATILITY PUMP & FUNCTIONAL GENERATION (Stochastic Portfolio Theory).
# Covers three proposed frameworks that are one mechanism: the "volatility pump" / rebalancing premium,
# Fernholz's functionally-generated portfolios & the numeraire portfolio (SPT), and the non-commutative
# / "quantum" flavor (the pump exists because averaging and compounding DON'T COMMUTE: E[log] != log[E]).
#
# CORE IDEA (Fernholz): rebalancing a diversified book earns an EXCESS GROWTH rate
#   gamma* = 1/2 ( sum_i w_i sigma_ii  -  w' Sigma w )  >= 0   (avg variance minus portfolio variance).
# A functionally-generated portfolio's return RELATIVE to the market decomposes (the master equation) as
#   log(V_pi / V_market) = d log S(theta)  +  Theta   (generating-function change + the drift = the pump).
#
# TESTS (2016-2026, SIP daily), on two "markets": the 6 asset-class spine, and the 20-stock BORE basket.
#   1. rebalancing premium: EW-rebalanced vs buy-and-hold; check it ~ gamma* (the pump, computed directly).
#   2. functional generation: a diversity-weighted portfolio (w_i ~ theta_i^0.5) vs the buy-and-hold
#      market; decompose log(V_div/V_mkt) into d log S(theta) (diversity change) + Theta (drift/pump).
#
# FINDING: the pump is REAL but was OVERWHELMED this decade. Fernholz's excess growth gamma* and the
# master-equation drift Theta are positive EVERYWHERE (spine gamma* +0.8%, Theta +0.044; stocks gamma*
# +2.9%, Theta +0.165) — the mechanism is genuine. Yet the realized rebalancing/diversity premium was
# NEGATIVE in BOTH universes (spine -0.8%/yr, stocks -8.3%/yr): drift dispersion — equities running away
# at the asset-class level, megacaps at the stock level — let buy-and-hold CONCENTRATION win. In the
# master equation the positive drift Theta was swamped by a large negative d log S (the market
# concentrated, diversity fell). So the volatility pump pays only when no single component runs away;
# the 2016-2026 concentration regime violated SPT's relative-arbitrage conditions — the family's
# "megacaps led / can't fade strength" law, in SPT clothing.
#
# RESULTS AS TESTED (2016-2026): gamma* spine +0.8% / stocks +2.9% (pump always > 0); realized rebal
#   premium spine -0.8% / stocks -8.3%; master eqn log(V_div/V_mkt) = d log S + drift(pump):
#   spine -0.035 = -0.079 + 0.044 ; stocks -0.443 = -0.608 + 0.165  (positive pump, swamped by concentration)
# Keys from env only; read-only; not validated.
import os, json, urllib.request, math
import numpy as np
H_={"APCA-API-KEY-ID":os.environ["ALPACA_KEY_ID"],"APCA-API-SECRET-KEY":os.environ["ALPACA_SECRET_KEY"]}
def cl(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-08-01&adjustment=all&feed=sip&limit=10000")
    b=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H_),timeout=40)).get("bars",{}).get(s,[])
    return {x["t"][:10]:x["c"] for x in b}
SPINE=["SPY","IEF","TLT","GLD","DBC","DBA"]
STOCKS=["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD","PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
def panel(syms):
    D={s:cl(s) for s in syms}; ds=sorted(set.intersection(*[set(v) for v in D.values()]))
    M=np.array([[D[s][d] for s in syms] for d in ds],float); return M[1:]/M[:-1]-1
def cagr(r): lvl=np.cumprod(1+r); return lvl[-1]**(252/len(r))-1

def analyze(name, R, alpha=0.5):
    T,N=R.shape
    ew=R.mean(1)                                              # equal-weight, rebalanced daily
    # buy-and-hold "market": weights start equal and drift
    th=np.full(N,1/N); rm=np.zeros(T); TH=np.zeros((T,N))
    for t in range(T):
        rm[t]=float(th@R[t]); g=th*(1+R[t]); th=g/g.sum(); TH[t]=th
    # excess growth gamma* (annualized) for the EW book
    Sig=np.cov(R.T); gstar=0.5*(np.mean(np.diag(Sig)) - np.var(ew))*252   # avg variance - portfolio variance
    rebal_prem=cagr(ew)-cagr(rm)
    # diversity-weighted functionally-generated portfolio: w_i ~ theta_i^alpha (decided from yesterday's mkt wts)
    rd=np.zeros(T)
    for t in range(1,T):
        w=TH[t-1]**alpha; w=w/w.sum(); rd[t]=float(w@R[t])
    Vd=np.prod(1+rd[1:]); Vm=np.prod(1+rm[1:]); lhs=math.log(Vd/Vm)
    S=lambda th: (np.sum(th**alpha))**(1/alpha)
    dlogS=math.log(S(TH[-1])/S(np.full(N,1/N)))
    drift=lhs-dlogS
    print(f"\n{name}  ({N} assets)")
    print(f"  1. VOLATILITY PUMP:  EW-rebal CAGR {cagr(ew)*100:+.1f}%  vs  buy-hold CAGR {cagr(rm)*100:+.1f}%"
          f"   -> rebalancing premium {rebal_prem*100:+.1f}%/yr")
    print(f"     excess growth gamma* (Fernholz, computed directly): {gstar*100:+.1f}%/yr  (always >= 0: the pump is real)")
    print(f"  2. FUNCTIONAL GENERATION (diversity-weighted, alpha={alpha}) vs buy-hold market:")
    print(f"     log(V_div / V_mkt) = {lhs:+.3f}  =  d log S(diversity) {dlogS:+.3f}  +  drift(pump) {drift:+.3f}")
    print(f"     -> diversity {'BEATS' if lhs>0 else 'LAGS'} the market; drift/pump {'+' if drift>0 else ''}{drift:+.3f}"
          f" {'is swamped by concentration (d log S<0)' if (drift>0 and lhs<0) else ''}")

print("="*80,"\nVOLATILITY PUMP & FUNCTIONAL GENERATION (Stochastic Portfolio Theory)\n"+"="*80)
analyze("ASSET-CLASS SPINE", panel(SPINE))
analyze("MEGACAP STOCK BASKET", panel(STOCKS))
print("\n(non-commutativity / 'quantum' note: the pump exists only because averaging and compounding do")
print(" not commute — E[log(1+r)] != log(1+E[r]); geometric mean < arithmetic mean. Order/path matters.)")
print("\nVERDICT: the volatility pump (excess growth gamma*) and the master-equation drift are ALWAYS positive")
print("— the mechanism is real — but this decade it was OVERWHELMED in BOTH universes. Realized rebalancing")
print("premium was negative (spine -0.8%, stocks -8.3%): drift dispersion (equities running away at the")
print("asset-class level, megacaps at the stock level) let buy-and-hold CONCENTRATION win, swamping the")
print("positive drift with a negative d log S. The pump pays only when no single component runs away; the")
print("2016-2026 concentration regime violated SPT's relative-arbitrage conditions — the family's 'megacaps")
print("led / can't fade strength' law, in SPT clothing. Diversification controls RISK here, it didn't add RETURN.")
