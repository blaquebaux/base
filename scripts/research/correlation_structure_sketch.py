#!/usr/bin/python3
# =============================================================================
# correlation_structure_sketch.py — PATH-A RESEARCH SKETCH (not a strategy).
#
# The consolidated cross-industry / cross-firm correlation investigation. Answers a series of
# "is this tradeable?" questions and reaches one durable conclusion:
#
#   Correlation is REAL and priced INSTANTLY. It is valuable for RISK (diversification) but is
#   NOT exploitable as ALPHA — cross-name read-through is in the price the same day (lead-lag ≈ 0,
#   and NEGATIVE in tech, where chasing it loses).
#
# Sections (all on Alpaca SIP daily bars):
#   1. Sector correlation structure (11 GICS sectors), the NVDA→semis supply chain, and the
#      oil/EV/auto "substitution" story (swamped by market beta).
#   2. Lead-lag / earnings read-through: NVDA→semis; banks both directions (GS/MS↔C/WFC/BAC and
#      JPM/WFC/C→GS/MS); tech (MSFT/GOOGL/META→AAPL/AMZN). All priced same-day; tech reverses.
#   3. The bank TIER ladder (T1 US GSIB, T1 Global ADRs, T2 super-regional, T3 regional,
#      T4 community) — US banks are ~0.8–0.95 one factor across every tier; geography (global) and
#      extreme size (community) are the only mildly-distinct pockets; beta shrinks with size.
#   4. Regulation & homogeneity (the WHY) — within-industry correlation ranked across 8 industries.
#      Prudential/structural regulation (banks, utilities, insurance) OR a common input (airlines:
#      fuel; semis: cycle) forces homogeneity → high correlation; product regulation with idiosyncratic
#      outcomes (pharma/biotech under the FDA) does NOT. Correlation ∝ shared FORCED exposure.
#
# Findings are directional; a tail/earnings backtest is dominated by which events fell in the window.
# Reads keys from env (ALPACA_KEY_ID / ALPACA_SECRET_KEY). Read-only; never trades.
# =============================================================================
import os, json, urllib.request
import numpy as np

H = {"APCA-API-KEY-ID": os.environ["ALPACA_KEY_ID"], "APCA-API-SECRET-KEY": os.environ["ALPACA_SECRET_KEY"]}
START, END = "2016-01-01", "2026-07-31"
_cache = {}
def fetch(s):
    if s in _cache: return _cache[s]
    u = (f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day"
         f"&start={START}&end={END}&adjustment=all&feed=sip&limit=10000")
    d = json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=40))
    _cache[s] = {b["t"][:10]: b["c"] for b in d.get("bars", {}).get(s, [])}
    return _cache[s]

def rets(syms):
    D = {s: fetch(s) for s in syms}; D = {s: v for s, v in D.items() if len(v) > 800}
    used = list(D); dates = sorted(set.intersection(*[set(D[s]) for s in used]))
    M = np.array([[D[s][d] for s in used] for d in dates], float)
    return used, dates[1:], (M[1:] / M[:-1] - 1)
def corr(a, b):
    m = np.isfinite(a) & np.isfinite(b); return float(np.corrcoef(a[m], b[m])[0, 1])
def basket(R, used, syms): return R[:, [used.index(s) for s in syms if s in used]].mean(axis=1)


def section1_sectors():
    print("=" * 70, "\n1. SECTOR CORRELATION STRUCTURE\n" + "=" * 70)
    sect = ["XLK","XLF","XLE","XLV","XLI","XLP","XLY","XLU","XLB","XLRE","XLC"]
    extra = ["NVDA","SMH","IHF","XBI","KARS","USO","F","GM","SPY"]
    used, dts, R = rets(sect + [e for e in extra if e not in sect])
    i = {s: used.index(s) for s in used}
    M = np.corrcoef(R[:, [i[s] for s in sect]].T); off = M[np.triu_indices(len(sect), 1)]
    print(f"11 GICS sectors: avg pairwise corr {off.mean():.2f} (min {off.min():.2f}, max {off.max():.2f})")
    print(f"avg sector↔SPY (market beta): {np.mean([corr(R[:,i[s]],R[:,i['SPY']]) for s in sect]):.2f}")
    print(f"supply chain  NVDA↔SMH {corr(R[:,i['NVDA']],R[:,i['SMH']]):.2f}  NVDA↔XLK {corr(R[:,i['NVDA']],R[:,i['XLK']]):.2f}  SMH↔XLK {corr(R[:,i['SMH']],R[:,i['XLK']]):.2f}")
    print(f"healthcare    XLV↔IHF {corr(R[:,i['XLV']],R[:,i['IHF']]):.2f}  XLV↔XBI {corr(R[:,i['XLV']],R[:,i['XBI']]):.2f}")
    print(f"substitution  USO↔KARS(EV) {corr(R[:,i['USO']],R[:,i['KARS']]):.2f}  USO↔F {corr(R[:,i['USO']],R[:,i['F']]):.2f}  KARS↔F {corr(R[:,i['KARS']],R[:,i['F']]):.2f}  (beta swamps the 'gas up → EV up / cars down' story)")


def leadlag(lead_syms, lag_syms, ew_months, ew_lo, ew_hi, label):
    used, dts, R = rets(list(set(lead_syms + lag_syms)))
    lead = basket(R, used, lead_syms); lag = basket(R, used, lag_syms); T = len(lead)
    ew = np.array([(int(d[5:7]) in ew_months and ew_lo <= int(d[8:10]) <= ew_hi) for d in dts])
    fwd3 = np.array([np.prod(1 + lag[t+1:t+4]) - 1 for t in range(T - 3)])
    same = corr(lead[:-3], lag[:-3]); nxt = corr(lead[:-3], lag[1:-2])
    same_e = corr(lead[:-3][ew[:-3]], lag[:-3][ew[:-3]]); d3_e = corr(lead[:-3][ew[:-3]], fwd3[ew[:-3]])
    print(f"  {label:<34} same-day {same:+.2f} | next-day {nxt:+.3f} | earn-wk same {same_e:+.2f}, →3d {d3_e:+.3f}")


def section2_leadlag():
    print("\n" + "=" * 70, "\n2. LEAD-LAG / EARNINGS READ-THROUGH  (is the co-move tradeable?)\n" + "=" * 70)
    print("  (positive same-day corr = they move together NOW; ~0 next-day = priced instantly, nothing to trade)")
    leadlag(["NVDA"], ["SMH","XLK"], (1,2,4,5,7,8,10,11), 1, 31, "NVDA → semis/tech (any day)")
    leadlag(["GS","MS"], ["C","WFC","BAC"], (1,4,7,10), 10, 25, "banks: GS/MS → C/WFC/BAC")
    leadlag(["JPM","WFC","C"], ["GS","MS"], (1,4,7,10), 10, 25, "banks: JPM/WFC/C → GS/MS (bake-in)")
    leadlag(["MSFT","GOOGL","META"], ["AAPL","AMZN"], (1,4,7,10), 20, 31, "tech: MSFT/GOOG → AAPL/AMZN (reverses)")


def section3_tiers():
    print("\n" + "=" * 70, "\n3. BANK TIER LADDER (US GSIB → community, + global)\n" + "=" * 70)
    TIERS = {
        "T1 US (GSIB)":      ["JPM","BAC","C","WFC","GS","MS"],
        "T1 Global":         ["UBS","HSBC","DB","BCS","RY","TD"],
        "T2 super-regional": ["USB","PNC","TFC","COF","BK"],
        "T3 regional":       ["RF","KEY","CFG","FITB","HBAN","MTB"],
        "T4 community":      ["TCBI","WSFS","FFIN","AUB","CATY","COLB","UCBI","INDB"],
    }
    alls = [s for v in TIERS.values() for s in v] + ["SPY"]
    used, dts, R = rets(alls); i = {s: used.index(s) for s in used}
    def bk(t): return R[:, [i[s] for s in TIERS[t] if s in used]].mean(axis=1)
    def within(t):
        idx = [i[s] for s in TIERS[t] if s in used]; C = np.corrcoef(R[:, idx].T)
        return C[np.triu_indices(len(idx), 1)].mean()
    t1 = bk("T1 US (GSIB)"); spy = R[:, i["SPY"]]
    print(f"  {'tier':<20}{'within':>8}{'→T1 US':>8}{'→SPY':>7}")
    for t in TIERS:
        print(f"  {t:<20}{within(t):>8.2f}{corr(bk(t),t1):>8.2f}{corr(bk(t),spy):>7.2f}")
    print("\n  Takeaway: US banks are ~0.82–0.95 ONE factor across every tier; global (0.6 internal) and")
    print("  community (lowest market beta ~0.63) are the only mildly-distinct pockets. Diversification")
    print("  lives across ASSET CLASSES, not across names/sectors/tiers within equities.")


def section4_regulation():
    print("\n" + "=" * 70, "\n4. REGULATION & HOMOGENEITY — why some industries are one factor\n" + "=" * 70)
    IND = {
        "Utilities (rate-reg)":       ["NEE","DUK","SO","D","AEP","EXC"],
        "Banks (prudential-reg)":     ["JPM","BAC","C","WFC","GS","MS"],
        "Insurance (solvency-reg)":   ["MET","PRU","AIG","ALL","TRV","CB"],
        "Airlines (safety; 1 fuel)":  ["DAL","UAL","AAL","LUV","ALK"],
        "Semiconductors (light reg)": ["NVDA","AMD","INTC","MU","AVGO","QCOM","TXN"],
        "Big Tech (light reg)":       ["AAPL","MSFT","GOOGL","AMZN","META","NVDA"],
        "Big Pharma (FDA product)":   ["PFE","MRK","JNJ","BMY","ABBV","LLY"],
        "Biotech (FDA; idiosyncr.)":  ["VRTX","REGN","GILD","BIIB","AMGN","MRNA"],
    }
    allsyms = sorted({s for v in IND.values() for s in v} | {"SPY"})
    used, dts, R = rets(allsyms); i = {s: used.index(s) for s in used}; spy = R[:, i["SPY"]]
    def st(t):
        idx = [i[s] for s in IND[t] if s in used]; C = np.corrcoef(R[:, idx].T)
        return C[np.triu_indices(len(idx), 1)].mean(), np.mean([corr(R[:, j], spy) for j in idx])
    print(f"  {'industry':<28}{'within-corr':>12}{'→SPY':>7}")
    for t, w, b in sorted(((t,) + st(t) for t in IND), key=lambda x: -x[1]):
        print(f"  {t:<28}{w:>12.2f}{b:>7.2f}")
    print("\n  Law: correlation ∝ shared FORCED exposure. Prudential/structural regulation (banks, utils,")
    print("  insurance) or a common input (airlines: fuel; semis: cycle) homogenizes firms → high corr;")
    print("  product regulation with idiosyncratic outcomes (pharma/biotech under the FDA) does NOT —")
    print("  each firm's fate is its own, so they stay uncorrelated despite heavy oversight.")


if __name__ == "__main__":
    section1_sectors(); section2_leadlag(); section3_tiers(); section4_regulation()
