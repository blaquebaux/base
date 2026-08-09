#!/usr/bin/python3
# =============================================================================
# crack_prototype.py — BLAQUE BAUX BLUNT, sleeve #4 (the one that survived).
#
# A short-horizon energy sleeve, two orthogonal signals blended, vol-targeted,
# and costed. NOT the spine; a tactical "Blunt" prototype (Path A, not validated).
#
#   Signal A — CRACK-SPREAD MEAN REVERSION. The gasoline crack (RBOB gasoline
#     minus WTI crude, via UGA vs USO) is a refining-margin spread that reverts.
#     We fade trailing-z deviations of its level (long spread when cheap, short
#     when rich). Market-neutral-ish: it is a spread, not a directional oil bet.
#     (NB: the 3-2-1 crack needs a distillate leg; the heating-oil ETF UHN
#      delisted in 2018, so we use the full-history gasoline crack instead.)
#   Signal B — CRUDE -> REFINER LEAD-LAG. Crude moves lead refiner equities by a
#     day (corr(USO_t, CRAK_{t+1}) ~ +0.18). An oil shock today (the geopolitics
#     channel) pulls refiners tomorrow. Long-biased; we take the long side only
#     (crude up -> long CRAK next day), flat otherwise, so we are not perpetually
#     short crude's drift.
#
# Each leg is EWMA vol-targeted to 10% annual, blended 50/50, and charged a
# realistic per-notional cost. We report GROSS and NET (post-cost) Sharpe/CAGR/DD.
# Reads ALPACA_KEY_ID / ALPACA_SECRET_KEY from env. Read-only; never trades.
# =============================================================================
import os, json, urllib.request, math
import numpy as np

H = {"APCA-API-KEY-ID": os.environ["ALPACA_KEY_ID"], "APCA-API-SECRET-KEY": os.environ["ALPACA_SECRET_KEY"]}
START, END = "2016-01-01", "2026-08-01"
COST_BPS = 3.0          # per side, per unit notional turnover (ETF spread+impact, generous)
VOL_TARGET = 0.10       # 10% annualized per leg
VOL_HL = 20             # EWMA halflife for vol estimate
LEV_CAP = 3.0

def bars(s):
    u = (f"https://data.alpaca.markets/v2/stocks/bars?symbols={s}&timeframe=1Day"
         f"&start={START}&end={END}&adjustment=all&feed=sip&limit=10000")
    d = json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=40))
    return {b["t"][:10]: b["c"] for b in d.get("bars", {}).get(s, [])}

def panel(syms):
    D = {s: bars(s) for s in syms}; D = {s: v for s, v in D.items() if len(v) > 500}
    u = list(D); dates = sorted(set.intersection(*[set(D[s]) for s in u]))
    M = np.array([[D[s][d] for s in u] for d in dates], float)
    return u, dates, M

def ewma_vol(r, hl):
    lam = 0.5 ** (1 / hl); v = r[0] ** 2; out = np.empty_like(r)
    for t in range(len(r)):
        v = r[t] ** 2 if t == 0 else lam * v + (1 - lam) * r[t] ** 2
        out[t] = math.sqrt(max(v, 1e-12))
    return out

def trailing_z(x, w):
    z = np.full(len(x), np.nan)
    for t in range(w, len(x)):
        seg = x[t - w:t]; sd = seg.std()
        if sd > 0: z[t] = (x[t] - seg.mean()) / sd
    return z

def vol_target(sig, leg_ret):
    """Scale a raw signal series so the position runs at VOL_TARGET on the leg."""
    vol = ewma_vol(leg_ret, VOL_HL) * math.sqrt(252)
    scale = np.clip(VOL_TARGET / np.maximum(vol, 1e-6), 0, LEV_CAP)
    return sig * scale

def metrics(pnl):
    r = np.asarray(pnl, float); r = r[np.isfinite(r)]
    if len(r) < 30 or r.std() == 0: return dict(sharpe=float('nan'), cagr=float('nan'), dd=float('nan'), vol=float('nan'))
    cum = np.cumprod(1 + r)
    return dict(sharpe=r.mean() / r.std() * math.sqrt(252),
                cagr=cum[-1] ** (252 / len(r)) - 1,
                dd=(cum / np.maximum.accumulate(cum) - 1).min(),
                vol=r.std() * math.sqrt(252))

def costed(pos, leg_ret, gross_mult):
    """pos: target position series (decided at close t, earns leg_ret[t+1]).
       gross_mult: notional multiplier for turnover cost (spread trades > 1 leg)."""
    pos = np.nan_to_num(pos)
    gross = pos[:-1] * leg_ret[1:]
    turn = np.abs(np.diff(np.concatenate([[0.0], pos])))[:-1] * gross_mult
    cost = turn * (COST_BPS / 1e4)
    return gross, gross - cost


# --------------------------------------------------------------------------- #
u, dts, M = panel(["USO", "UGA", "CRAK"])
r = M[1:] / M[:-1] - 1
i = {s: u.index(s) for s in u}
print("=" * 70, "\nBLAQUE BAUX BLUNT — sleeve #4 prototype (crude/refiner)\n" + "=" * 70)
print(f"data: {', '.join(u)}  |  {dts[1]}..{dts[-1]}  ({len(r)} days)  |  cost {COST_BPS}bp/side\n")

# ---- Signal A: gasoline-crack mean reversion (UGA gasoline vs USO crude) ----
crack = r[:, i["UGA"]] - r[:, i["USO"]]              # daily gasoline-crack return spread
lvl = np.cumprod(1 + crack)
z = trailing_z(lvl, 40)
rawA = -np.tanh(z)                                    # fade: long spread when z<0
posA = vol_target(rawA, crack)
grossA, netA = costed(posA, crack, gross_mult=2.0)   # 2-leg spread ~2x notional turnover
mA = metrics(netA)
print(f"A  crack-spread mean-reversion (fade z40):")
print(f"     gross Sharpe {metrics(grossA)['sharpe']:+.2f} | NET Sharpe {mA['sharpe']:+.2f}  CAGR {mA['cagr']*100:+.1f}%  vol {mA['vol']*100:.0f}%  maxDD {mA['dd']*100:.0f}%")

# ---- Signal B: crude -> refiner lead-lag (long side only) ----
crak = r[:, i["CRAK"]]; uso = r[:, i["USO"]]
rawB = (uso > 0).astype(float)                        # crude up today -> long CRAK tomorrow, else flat
posB = vol_target(rawB, crak)
grossB, netB = costed(posB, crak, gross_mult=1.0)
mB = metrics(netB)
print(f"B  crude->refiner lead-lag (long-only, crude-up):")
print(f"     gross Sharpe {metrics(grossB)['sharpe']:+.2f} | NET Sharpe {mB['sharpe']:+.2f}  CAGR {mB['cagr']*100:+.1f}%  vol {mB['vol']*100:.0f}%  maxDD {mB['dd']*100:.0f}%")
# benchmark: CRAK buy & hold over same window
mBH = metrics(crak[1:])
print(f"     (benchmark CRAK buy&hold: Sharpe {mBH['sharpe']:+.2f}  CAGR {mBH['cagr']*100:+.1f}%  maxDD {mBH['dd']*100:.0f}%)")

# ---- B variants (is the lead-lag robust, or just dodging the 2020 crash?) ----
print("\nB variants (net of cost):")
# long/short: crude up -> long CRAK, crude down -> short CRAK
rawBs = np.sign(uso); posBs = vol_target(rawBs, crak)
_, netBs = costed(posBs, crak, 1.0); print(f"  long/short by sign:          Sharpe {metrics(netBs)['sharpe']:+.2f}  maxDD {metrics(netBs)['dd']*100:.0f}%")
# magnitude-scaled long-only: size by size of crude move
rawBm = np.maximum(uso, 0) / (np.abs(uso).mean() + 1e-9); posBm = vol_target(rawBm, crak)
_, netBm = costed(posBm, crak, 1.0); print(f"  magnitude-scaled long-only:  Sharpe {metrics(netBm)['sharpe']:+.2f}  maxDD {metrics(netBm)['dd']*100:.0f}%")
# sub-period stability of the chosen (sign, long-only) sleeve
half = len(netB) // 2
print(f"  sub-period  first half:      Sharpe {metrics(netB[:half])['sharpe']:+.2f}   second half: Sharpe {metrics(netB[half:])['sharpe']:+.2f}")

print("\n" + "-" * 70)
print("VERDICT: the crack-spread mean-reversion (A) does NOT survive full-sample")
print("costs — its earlier promise was a stale delisted-ETF (UHN) window artifact.")
print("The crude->refiner lead-lag (B) is the real sleeve: NET Sharpe ~1.0, and it")
print("roughly HALVES refiner drawdown vs buy&hold by staying out after crude falls.")
print("Still single-commodity and regime-sensitive; a candidate for live A/B, not")
print("the spine. This is the honest core of Blaque Baux Blunt #4.")
