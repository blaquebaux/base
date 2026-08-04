#!/usr/bin/python3
# PATH-A SKETCH — pairs / relative-value mean-reversion. Does the spread between tightly-correlated
# names revert profitably NET OF COSTS? Threshold strategy on the z-score of the log-price spread
# (60d), enter |z|>2 (short rich / long cheap), exit |z|<0.5. Not validated.
import os, json, urllib.request
import numpy as np
K=os.environ["ALPACA_KEY_ID"]; S=os.environ["ALPACA_SECRET_KEY"]; H={"APCA-API-KEY-ID":K,"APCA-API-SECRET-KEY":S}
def fetch(s):
    u=(f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day&start=2016-01-01&end=2026-07-31&adjustment=all&feed=sip&limit=10000")
    return {b["t"][:10]:b["c"] for b in json.load(urllib.request.urlopen(urllib.request.Request(u,headers=H),timeout=40)).get("bars",{}).get(s,[])}
PAIRS=[("KO","PEP"),("XOM","CVX"),("HD","LOW"),("V","MA"),("SMH","XLK"),("XLV","IHF"),("GLD","SLV")]
SY=sorted({s for p in PAIRS for s in p}); D={s:fetch(s) for s in SY}
COST=0.0002   # 2 bps per leg per side
def series(a,b):
    d=sorted(set(D[a])&set(D[b])); pa=np.array([D[a][x] for x in d]); pb=np.array([D[b][x] for x in d]); return d,pa,pb
def zscore(s,win=60):
    z=np.full(len(s),0.0)
    for t in range(win,len(s)):
        w=s[t-win:t]; m=w.mean(); sd=w.std(); z[t]=(s[t]-m)/sd if sd>0 else 0
    return z
def halflife(s):
    ds=np.diff(s); sl=s[:-1]; b=np.polyfit(sl,ds,1)[0]; return (-np.log(2)/b) if b<0 else np.inf
def pair_strat(a,b):
    d,pa,pb=series(a,b); s=np.log(pa)-np.log(pb); z=zscore(s)
    ra=pa[1:]/pa[:-1]-1; rb=pb[1:]/pb[:-1]-1; spread_ret=ra-rb          # long A / short B, dollar-neutral
    pos=0; posv=np.zeros(len(spread_ret)); trades=0
    for t in range(len(spread_ret)):
        zt=z[t]                                   # z at close of day t (info available for holding into t+1)
        if pos==0:
            if zt> 2: pos=-1; trades+=1
            elif zt<-2: pos= 1; trades+=1
        elif abs(zt)<0.5 or (pos==-1 and zt<0) or (pos==1 and zt>0):
            pos=0
        posv[t]=pos
    gross=np.zeros(len(spread_ret)); gross[1:]=posv[:-1]*spread_ret[1:]
    turn=np.abs(np.diff(np.concatenate([[0],posv])))
    net=gross-COST*2*turn                          # 2 legs
    return net,gross,trades,halflife(s)
def sh(x): return x.mean()/x.std()*np.sqrt(252) if x.std()>0 else 0

print(f"pairs mean-reversion — threshold |z|>2 enter, |z|<0.5 exit, 60d window, 2bps/leg\n")
print(f"{'pair':<12}{'corr':>6}{'half-life':>11}{'trades':>8}{'grossSh':>9}{'netSh':>8}{'netCAGR':>9}")
print("-"*63)
nets=[]
for a,b in PAIRS:
    d,pa,pb=series(a,b); ra=pa[1:]/pa[:-1]-1; rb=pb[1:]/pb[:-1]-1; corr=np.corrcoef(ra,rb)[0,1]
    net,gross,tr,hl=pair_strat(a,b); nets.append(net)
    cagr=np.prod(1+net)**(252/len(net))-1
    print(f"{a+'/'+b:<12}{corr:>6.2f}{hl:>10.0f}d{tr:>8}{sh(gross):>9.2f}{sh(net):>8.2f}{cagr*100:>8.1f}%")
# diversified pairs book: vol-target each to 8% then equal-weight (the real stat-arb portfolio)
L=min(len(n) for n in nets); B=[]
for n in nets:
    x=n[-L:]; v=x.std()*np.sqrt(252); B.append(x*(0.08/v) if v>0 else x)
book=np.mean(np.vstack(B),axis=0)
print("-"*63)
print(f"{'BOOK (all pairs, vol-eq)':<37}{'':>8}{sh(book*0+ (np.mean([sh(g) for g in [pair_strat(a,b)[1] for a,b in PAIRS]]))):>9.2f}"[:46], end="")
print(f"{sh(book):>8.2f}{(np.prod(1+book)**(252/len(book))-1)*100:>8.1f}%")
print(f"\n(gross Sharpe of the book ≈ average of gross pair Sharpes; net Sharpe {sh(book):.2f} is after costs)")
