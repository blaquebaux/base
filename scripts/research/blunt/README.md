# Blaque Baux Blunt — short-horizon tactical research

A separate, faster-cadence research track from the spine. The spine harvests risk
premia over days-to-weeks; **Blunt** tests short-horizon (1-day to intraweek)
tactical ideas. Same Path-A discipline: build it, test it honestly on real data,
write down the verdict — including *what didn't work*.

All sketches read Alpaca SIP bars (daily; **hourly for #6's intraday test**) from
`ALPACA_KEY_ID` / `ALPACA_SECRET_KEY` in env, are read-only, and print their own
results. Numbers are **gross of costs** unless marked NET; sample is 2016–2026
(#6's intraday test is 2019–2026). The cross-sectional basket is 45 liquid S&P
names (current constituents → mild survivorship bias; treat as directional).

```bash
export $(grep -v '^#' ~/.config/blaquebaux/alpaca.env | xargs)   # or source it
python scripts/research/blunt/crack_prototype.py                  # the #4 prototype
python scripts/research/blunt/blunt_1_low_sharpe.py               # etc.
```

## Scorecard

| # | Proposed | Result | Verdict |
|---|----------|--------|---------|
| 1 | Short lowest trailing-Sharpe names | short −0.88 Sharpe, −91% DD; **flipped long** +0.88 gross but **beta-neutral −0.05** | ❌→long: pure beta |
| 2 | Long top movers / short bottom movers | momentum −0.14; **flipped long losers** +0.97 gross, **beta-neutral +0.24** | ❌→long: small bounce |
| 3 | Asia / chip cascade → next-day US | overnight→intraday corr ≈0; TSM→SMH next-day corr −0.10 | ❌ priced instantly |
| 4 | Crack spread (crude vs refined) | **crude→refiner lead-lag: NET Sharpe +1.06** (prototype) | ✅ built |
| 5 | Short high Ulcer/Pain names | short −1.00; **flipped long** +1.00 gross, **beta-neutral +0.46** | 🟡→long: real edge |
| 6 | Long Mon→Wed-noon / short Wed-noon→Fri | intraday: proposed +0.50…+0.72 vs **just-hold +0.87…+1.06** | ❌ dominated by holding |

## The synthesis

**#1, #2, and #5 are one mistake in three costumes.** Low-Sharpe, "biggest loser,"
and high-Ulcer/Pain all select the same thing — *recent losers* — and at a one-day
horizon losers **bounce** (short-term reversal). Shorting them steps in front of the
bounce, which is why all three short books post −0.9 to −1.0 Sharpe and one hits a
−91% drawdown.

Flipped to **long** (per the "go long the backwards ones" call), the honest picture
after removing market beta:

- **#1 (Sharpe screen): no edge** — beta-neutral −0.05. The raw long leg is pure beta.
- **#2 (return screen): thin** — beta-neutral +0.24.
- **#5 (drawdown/Ulcer screen): real** — beta-neutral **+0.46**, the strongest
  short-term contrarian signal of the three. The *drawdown* screen picks the best
  bounce candidates. This is the flipped idea worth developing (a beta-neutral
  loser-bounce sleeve).

## Documented results — both directions, as tested

For the record: every version that was run, working or not. These are **point-in-time**
over the stated sample and may behave differently in other regimes or need
modification later — but they were tested, and here is what came back.

**#1 / #2 / #5 — cross-sectional (45-name basket, 2016–2026, gross of costs/borrow):**

| Strategy | Short (proposed) | Long (flipped) | Long, beta-neutral |
|---|---|---|---|
| #1 lowest trailing-Sharpe | −0.88 Sharpe, −91% DD | +0.88, CAGR +19.6% | **−0.05** (pure beta) |
| #1 highest trailing-Sharpe | −1.26 | +1.26 | +0.38 |
| #2 movers, 1-day (winners vs losers) | momentum −0.14 | long-losers +0.97, CAGR +23.5% | **+0.24** (small bounce) |
| #2 movers, 5-day formation | momentum −0.07 | contrarian +0.07 | — |
| #5 highest Ulcer | −1.00 Sharpe, −96% DD | +1.00, CAGR +27.0% | **+0.46** (real edge) |
| #5 highest Pain | −0.99 | +0.99 | +0.43 |

Read: the **short** side is a loss-maker across the board (shorting recent losers,
which bounce). The **long** side is positive but mostly market beta — except the
**drawdown-based #5**, which keeps a genuine ~+0.46 beta-neutral edge.

**#6 — intraweek, real intraday test (hourly SIP, Wed-noon pivot, 396 weeks 2019–2026, NET ~1bp/side):**

| Index | Proposed (long first half / short second) | Benchmark: just hold Mon→Fri | leg A Mon→Wed-noon | leg B Wed-noon→Fri |
|---|---|---|---|---|
| SPY | +0.55 Sharpe, CAGR +7.6%, DD −26% | **+1.03, +16.3%** | +26.9 bp/wk | +6.5 bp/wk |
| QQQ | +0.72, +13.2%, −39% | **+1.06, +21.3%** | +37.4 bp/wk | +5.7 bp/wk |
| DIA | +0.50, +6.6%, −25% | **+0.87, +12.9%** | +23.0 bp/wk | +4.6 bp/wk |

Read: the proposed short-the-second-half is **dominated by simply holding the week**.
Leg B (the back half) is weaker but still *positive*, so shorting it fights the
equity risk premium — the same "backwards" trap as #1/#2/#5. The first-half strength
is real but only supports a long-only *tilt*, not a short.

## The one that got built: #4

`crack_prototype.py`. Two candidate signals; only one survived full-sample costs:

- **A — crack-spread mean-reversion: dead.** NET −0.05. Its earlier promise
  (Sharpe +0.87) was a data trap: the heating-oil ETF **UHN delisted in 2018**, so
  intersecting on it silently truncated the test to a stale 2016–2018 window.
  Documented as a rejected component, not hidden.
- **B — crude→refiner lead-lag: real.** Crude moves lead refiner equities by a day
  (corr(USO_t, CRAK_{t+1}) ≈ +0.18). Going long CRAK the day after crude rises
  (flat otherwise) gives **NET Sharpe +1.06** after 3 bp/side, and roughly **halves
  the drawdown** vs buying refiners outright (−12% vs −60%). Stable across
  sub-periods (first half +1.14, second half +0.99), so it is not just dodging the
  2020 crash. This is the tradeable version of the geopolitics/oil-shock thesis:
  trade the *follow-through*, not "the war."

Caveats: single-commodity, regime-sensitive, long-biased, and **not validated to
the spine's bar**. A candidate for a live paper A/B, not for real capital.

## Files
- `_blunt_common.py` — shared data/metrics helpers.
- `blunt_1_low_sharpe.py`, `blunt_2_movers.py`, `blunt_3_overnight_cascade.py`,
  `blunt_5_ulcer_pain.py`, `blunt_6_intraweek.py` — the six proposed ideas (#4 is
  the prototype below).
- `crack_prototype.py` — the #4 sleeve prototype (vol-targeted, cost-modeled).
