# Blaque Baux

**A governed, systematic risk-premium harvesting platform — in Julia.**

Blaque Baux does *not* try to predict returns. After rigorous out-of-sample testing found no
exploitable predictive edge at the horizons and instruments studied, it was built around the edge
that *does* survive: **risk structure**. It harvests diversification and trend premia, times risk
with a stateful daily process, and routes every order through a governed execution layer that
enforces hard, tested invariants.

> **Not investment advice.** Educational/research software. All performance figures are historical
> backtests or paper-trading results, net of modeled costs — not a promise of future results.
> Trading carries substantial risk, including loss of principal. See [LICENSE](LICENSE).

## About Blaque Baux

**Blaque Baux** is a quantitative research initiative and a subsidiary of **[Carter Warrens](https://carterwarrens.com)**.
[**BlaqueBaux.com**](https://blaquebaux.com) is the home for the work; the code lives here on GitHub — open to
study, test, and build bespoke strategies on top of.

Anyone can point an AI at a market. The edge is **understanding what the data actually says — and turning it
into something you can act on.** We test relentlessly and put most of it *on the record as rejected, with the
reason*; what survives is built, governed, and validated before it is ever called real. That combination —
honest research, reproducible evidence, and execution you can trust — is why Carter Warrens leads on
**strategy and implementation**, not merely uses the tools everyone now has.

### → The capstone white paper — [`docs/whitepaper.html`](docs/whitepaper.html)

*Blaque Baux — An Honest Architecture for Systematic Risk.* The whole of it in one document: the philosophy,
the engine, the four books that trade, the derivatives layer, the graveyard of rejected ideas, and the ten
durable laws the failures taught. Start here.

---

## What it is

- **The spine** — a two-sleeve strategy: an inverse-vol / equal-risk-contribution **base** that
  harvests the diversification premium by risk structure, plus a 12-month time-series-momentum
  **trend** sleeve that hedges crises (it made *money* in 2022, short bonds / long energy). Each
  sleeve is volatility-targeted on its own realized P&L, blended, and scaled by a drawdown-based
  **regime brake**. Rebalanced once daily.
- **Governed execution** — a venue-agnostic controller enforcing idempotency, per-pool budget and
  loss limits, data-staleness, position reconciliation, a kill switch, and full fill lineage. No
  language model is anywhere near the order path; the strategy is reproducible code.
- **A live-money safety gate** — pre-trade drawdown/loss halts, gross-leverage and per-name caps,
  account/data checks, and alerting, on top of the controller's invariants.
- **Honest validation** — the methodology and the results, including *what didn't work*, are
  documented in full (see below). This repo tries to be a trustworthy quant reference, not a pitch.

## Performance (historical, net of ~2 bps/side; paper-verified live path)

| | Sharpe | Sortino | Max drawdown | 2022 | Cadence |
|---|---|---|---|---|---|
| Spine (production, regime brake) | **~0.97** | ~1.30 | **~−11%** | −1.4% | daily |

Honest context: this is a **single-digit-CAGR, ~1.0-Sharpe** strategy — institutional-quality
*risk-adjusted* performance, not headline returns. Leverage to reach double digits is possible but
carries proportional (double-digit) drawdown, and is net-negative at today's margin rates — the
trade-off is quantified in [`docs/leverage_decision.html`](docs/leverage_decision.html). There is
no double-digit-return-at-low-risk configuration, and this repo says so.

## The research program — 20+ strategies, one honest scorecard

The spine is the *survivor* of a much larger program. This repo is a research corpus: two dozen
strategies were built and tested across return-prediction, convexity / tail-hedging, correlation
structure, and leverage — and most were **rejected, on the record, with the reason.** The complete
white paper is the map:

### → [`docs/compendium.html`](docs/compendium.html) · [PDF](docs/compendium.pdf) — *The Complete Method*

| Status | # | Examples |
|---|---|---|
| **Live / production** | 2 | the spine; DBA agriculture sleeve |
| **In live A/B** | 2 | multi-horizon trend; split-universe spine |
| **Research (kept)** | 6 | Gamma-ARMA regime framework; Taleb barbell; the curveball; inverse-carry tail hedge; diversified tail hedge; the optimizer library |
| **Tested & rejected** | 10 | Bayesian & cross-sectional alpha; blue-chip / mid-cap prediction; 15-min alpha; earnings lead-lag; pairs stat-arb; vol-overlay hedge; convex-response function; carry sleeve; carry-as-base; leverage-to-double-digits |

Ten durable laws came out of it — e.g. *convexity is free (trend) or paid (long-vol), never both cheap
and fast*; *timing the tail removes the tail*; *correlation is priced instantly — a risk tool, not
alpha*; *aggression multiplies edge, and with none it multiplies only ruin*; *you can't short
momentum-driven strength (it's ruin) — and being long it survives on drift, not selection: winner-picking
is beta, the tradeable residue is trend convexity*. Every result is a reproducible sketch in
[`scripts/research/`](scripts/research/) (34 scripts), consolidated in
[`docs/research_thread_summary.pdf`](docs/research_thread_summary.pdf).

**That most of the scorecard is red is the point** — a strategy is only as trustworthy as the ideas it was willing to kill.

## The mathematics

Everything — covariance estimation, the sleeve construction, risk metrics (Sharpe/Sortino/Calmar/
VaR/CVaR), the governed-execution invariants, the validation methodology (Information Coefficient),
and the empirical findings (momentum-vs-reversal by horizon, daily-vs-intraday, the leverage
trade-off) — is specified with formulas and code references in:

### → [`docs/FINANCIAL_METHODS.md`](docs/FINANCIAL_METHODS.md)

Architecture and design decisions: [`docs/CANONICAL_ARCHITECTURE.md`](docs/CANONICAL_ARCHITECTURE.md).

## Beyond the spine — a portfolio-optimization toolkit

The spine is one strategy built on a **general-purpose optimization library** (`src/module_13_portfolio/`,
module `PortfolioOpt`) that is useful on its own:

- **Optimizers** — mean-variance (min-variance, max-Sharpe, efficient frontier), **Black–Litterman**,
  risk parity / HRP / max-diversification, **tail-risk** (min-CVaR / min-CDaR via Rockafellar–Uryasev
  LPs), and **cost-aware** mean-variance (trades from current holdings with linear + impact penalties).
- **Monte-Carlo robustification** (`robust.jl`) — Gaussian / IID / block / stationary bootstrap and
  Student-t data-generating processes feeding a **Michaud resampled frontier** and a feasible-set
  Monte-Carlo cloud. This is MC used to *defend against estimation error*, not to forecast price.
- **A REST service** (`scripts/portfolio_server.jl`, JSON on `:8766`) with a Python **Dash** dashboard
  (`scripts/dashboard.py`): `/optimize`, `/frontier`, `/resampled_frontier`, `/backtest`, `/metrics`,
  `/random_portfolios`.

```bash
julia --project=. scripts/portfolio_server.jl     # optimizer backend on :8766
python scripts/dashboard.py                        # dashboard UI on :8050
```

A worked cross-family demo — [`scripts/research/multi_sleeve_portfolio.jl`](scripts/research/multi_sleeve_portfolio.jl) —
runs risk-parity / min-variance / max-diversification / HRP / min-CVaR over the **full
keeper set**: the five asset-class spine plus ten reconstructed keepers — crude→refiner
(CRACK), beta-hedged market-neutral (BORE), vol-scaled multi-horizon trend (TREND),
brown/blue camp rotation (CAMPROT), drawdown-bounce (DDBOUNCE), Block's four-block cross-asset
trend (BLOCK), the live drawdown-regime brake (REGIME), the **actual Gamma-ARMA crisis detector
wired in** (GAMMA_REG — module 4 ARMA+GARCH tail-index/vol + module 5 `detect_crisis_regime`),
and two *paid-convexity* tail hedges, the Taleb barbell (BARBELL) and vol-gated curveball
(CURVEBALL). It surfaces **three** honest lessons. First, the return-earning keepers push the
diversified book past the best single sleeve, and the risk budget flows to the genuinely
uncorrelated fragments (TREND corr −0.14, BORE −0.06), not the high-Sharpe *beta* sleeves —
high standalone Sharpe doesn't earn weight, low correlation does; and folding in BLOCK shows the
converse — it's 0.84-correlated to TREND, so the optimizer just splits the trend budget between
them and the book lifts only +1.60→+1.66 (the FX/dollar block, Block's one new axis) — redundant
sleeves don't earn new weight either. Second, the two regime timers differ sharply: the live drawdown
brake catches slow drawdowns but whipsaws, while the wired-in Gamma-ARMA detector flags only
~2% of days yet catches ~67% of the COVID crash and is the *best single ingredient* (+1.13,
COVID −8% vs SPY −33%) — it **times** the tail cheaply; but it's 0.88-correlated to SPY (so
still down-weighted as beta) and its thresholds fit COVID *in-sample*, which is exactly why the
framework stays research and the live spine trusts the simpler brake. Third, the paid-convexity
hedges are negative-carry **insurance** (CURVEBALL alone a −86% ruin) that a variance objective
**misprices** — risk-parity hands BARBELL ~31% because it's low-vol and anti-correlated.
**Convexity must be budgeted, not optimized in:** free convexity (trend) the book earns, paid
(long-vol) you size, timed (the crisis detector) is seductive in-sample — the spine's "harvest
risk structure" thesis with the tail-hedge and regime-timing caveats made visible.

> On the Gamma-ARMA framework: modules 1–6 (ARMA+GARCH, the Gamma-hyperprior DPM regime model,
> `detect_crisis_regime`) are present in-repo and importable, and unit-tested under
> [`test/runtests.jl`](test/runtests.jl). "Quarantined" means only that they sit **outside the
> production validation gate and the live path** — a separate research lineage that showed no
> edge over the simpler drawdown brake, not code that was removed.

The keeper book has a **governed dry-run/paper driver** — [`scripts/keeper_book_live.jl`](scripts/keeper_book_live.jl)
(wrapper [`run_keeper_book_daily.sh`](scripts/run_keeper_book_daily.sh), launchd
[`com.blaquebaux.keeper_book.plist`](scripts/launchd/com.blaquebaux.keeper_book.plist)). It rebuilds the
book daily (risk-parity over the 8 ingredients), expands each sleeve into its current instrument weights,
nets them per symbol, and routes the targets through the **same Layer-3 safety gate + governed execution
controller** as the spine (`preflight → execute_rebalance! → reconcile`). It defaults to **dry-run**
(computes the book, runs the gate, logs the netted targets — places nothing) and graduates to Alpaca
paper only with its own isolated keys/ledger.

Before graduating it, [`scripts/keeper_book_validation.jl`](scripts/keeper_book_validation.jl) is the
**validate-before-live gate**: a fully causal walk-forward that recomputes the book from data strictly
before each rebalance, nets it to the **instrument level** (so it pays the sleeves' real internal
turnover), **net of costs**, against a stated pass/fail bar (+ a purged-K-fold cross-check via
`module_11_cv`). The keeper book **clears it**: OOS net Sharpe **+1.28** (5 bps/side) / CAGR +6.4% /
maxDD **−6%**, positive in 9 of 10 years — an honest haircut from the demo's +1.66 gross-in-sample, but
still well ahead of SPY (+0.79 / −34%), with all five checks passing. That is the research earning its
graduation to the paper path — still *not* validated to the spine's full production bar.

The **non-keepers** are not discarded — they are governed as **tactical regime sleeves**. Several near-miss
sleeves (each real and mechanism-grounded, but below the standalone keeper bar) are run the way they are
*meant* to be used: small, deployed only in their favorable regime, **time-boxed to a quarter or two**, and
**combined** so no one sleeve carries the book. [`scripts/tactical_book_validation.jl`](scripts/tactical_book_validation.jl)
is their gate: a causal, net-of-cost walk-forward of the combined book (cost-push / beige / bulgar / **pead**),
which comes out **+0.46 net Sharpe, beta ≈ 0, uncorrelated to the keeper book (+0.05)** — so as an *overlay* it
**lifts the keeper book +1.28 → +1.35** at half weight (~+5%), where any one of them alone adds nothing. The
fourth sleeve, **PEAD** (post-earnings drift: long top-third / short bottom-third surprise among names still in
their drift window), is *event-driven* — fed by an earnings-calendar pipeline
([`scripts/pead_calendar.py`](scripts/pead_calendar.py) → [`pead_earnings_calendar.json`](scripts/pead_earnings_calendar.json))
and exempt from the time-box (its positions self-limit as the drift window rolls off); it qualifies
(market-neutral, +0.11, uncorrelated) but adds only marginally — diversification is bounded by own Sharpe. The
**governed driver** is [`scripts/tactical_book_live.jl`](scripts/tactical_book_live.jl) (wrapper
[`run_tactical_book_daily.sh`](scripts/run_tactical_book_daily.sh), launchd
[`com.blaquebaux.tactical_book.plist`](scripts/launchd/com.blaquebaux.tactical_book.plist)): it checks each
sleeve's regime, applies the **three rules** (10% cap / regime gate / a persisted **time-box** clock that
forces a stand-down + cooldown after a quarter or two of continuous deployment), nets the combined
market-neutral book, and routes it through the **same safety gate + governed execution** as the spine. It
defaults to **dry-run** (and dry-run never advances the time-box clock), with its own fully isolated
keys/ledger/state so it can never touch the spine or keeper accounts.

Two companion analyses build on the same keeper set (via the shared `keeper_ingredients.jl`
builder). [`negentropy_ranking.jl`](scripts/research/negentropy_ranking.jl) asks — in Schrödinger's
negentropy language — *what* the optimizer pays for: not standalone Sharpe (it avoids it, −0.43) and
not fat tails (marginal non-Gaussianity earns nothing), but **inverse volatility** (+0.88), with
independence only weakly rewarded; a book built to harvest independence + low vol still reproduces the
engine's risk-controlled character. [`hedge_saturation.jl`](scripts/research/hedge_saturation.jl) draws
the **convexity-budget curve**: barbell drawdown-protection *saturates* by ~10% weight, after which only
the negative carry compounds — yet a naive risk-parity assigns the barbell ~29%, deep past the knee. Both
make the demo's "budget convexity, don't optimize it in" concrete.

Full math for all of the above: [§9 of `docs/FINANCIAL_METHODS.md`](docs/FINANCIAL_METHODS.md).
*(Crypto note: a Deribit BTC volatility signal is available as a risk **input** via
`module_1_data/data_feeds_production.jl`; the spine trades ETFs, not crypto assets.)*

## Quickstart

Requires Julia (1.10+). From the repo root:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # one-time
julia --project=. test/runtests.jl                    # gate suites (should be green)
```

Backtest / inspect the spine (uses the bundled `scripts/data/sector_panel.csv`):

```bash
julia --project=. scripts/leverage_decision_data.jl   # regenerates the leverage-analysis data
```

**Paper trading** through [Alpaca](https://alpaca.markets) (paper keys need no account approval):

```bash
export ALPACA_KEY_ID=PK_your_key   ALPACA_SECRET_KEY=your_secret
julia --project=. scripts/spine_live.jl               # PAPER by default; safety gate always on
```

Live money is deliberately gated: it requires an explicit `BB_LIVE_CONFIRM` sentinel, a funded /
approved brokerage account, and the safety gate green. Do not flip it lightly.

## Repository layout

```
src/
  module_1_data/        data adapters: CSV, Alpaca, IBKR panel providers
  module_7_execution/   governed ExecutionController + venue adapters (Alpaca / IBKR)
  module_8_governance/  Layer-3 live-money safety gate
  module_11_cv/         purged / combinatorial cross-validation
  module_13_portfolio/  PortfolioOpt: moments, risk-based weights, the spine, metrics
scripts/
  spine_live.jl         production daily driver (safety-gated)
  run_spine_daily.sh    launchd wrapper (scheduled pre-open run)
  spine_end_to_end.jl   full pipeline on cached data (integration demo)
docs/
  compendium.html           THE COMPLETE METHOD — every strategy, scored (start here for breadth)
  FINANCIAL_METHODS.md      the validated math (start here for depth)
  CANONICAL_ARCHITECTURE.md architecture & decisions
  research_thread_summary.pdf  consolidated convexity/correlation/leverage findings
  leverage_decision.html    interactive leverage trade-off visual
scripts/research/          34 reproducible research sketches (the scorecard's evidence);
                           keeper_ingredients.jl is the shared keeper-set builder they reuse
test/                    gate + (quarantined legacy) suites
```

## Status

- **Paper-tested end-to-end** (data → strategy → governed orders → ledger with lineage →
  reconciliation) against a real broker paper account.
- The strategy is validated out-of-sample; the live path is verified on paper.
- Real capital has **not** been deployed. The legacy Gamma-ARMA base modules (a separate research
  lineage — modules 1–6) remain in-repo and unit-tested under `test/runtests.jl`, but sit **outside
  the production validation gate and the live path**; the live spine uses the simpler drawdown regime
  brake (§3.4). "Quarantined" means gate/live exclusion, not removal.

## Roadmap & archived work

This repository is the **canonical, validated core**. A larger body of earlier and exploratory work
is preserved *outside* the repo (a local `Archive/` tree) for provenance — it is **not published here
and not wired into the live path**. It's catalogued so the lineage is clear and so the honest
"what's next" is on the record:

- **Crypto-Quant MVP** *(archived)* — a Streamlit app with a natural-language (LLM) interface for
  cryptocurrency portfolio risk analysis via Monte-Carlo simulation. A plausible future *front-end /
  product* direction; it is a separate prototype, never connected to the spine. Today crypto appears
  in the core only as a **risk input** (Deribit BTC volatility) — see `data_feeds_production.jl`.
- **Alpha research track** *(archived; see [`FINANCIAL_METHODS.md` §10](docs/FINANCIAL_METHODS.md))* —
  a Bayesian return-estimation engine and a Monte-Carlo / "Six-Sigma Oracle" risk engine. The math is
  sound but measured **no predictive edge** at the horizons tested, which is *why* the live strategy
  harvests risk premia instead. This is "Path A" — kept as funded-research material, not production.
- **Earlier prototypes** *(archived)* — Python builds (`v1`/`v2`/`polyglot`) and a standalone
  optimizer service, all **superseded** by this Julia core (the in-repo `portfolio_server.jl` replaces
  the old optimizer service).

**Direction of travel:** the near-term roadmap is depth on the validated core (broader instrument
universe, live-money graduation off paper, more governance coverage), *not* re-adopting archived
components. Anything from the archive returns only if it clears the same out-of-sample edge bar the
core was held to (§7). No archived component has cleared it yet — and this README will say so until one does.

## The Blaque Baux family

This repo is the base/blueprint. Each family repo consumes this engine as a git submodule
and steers it at a different market — one platform, many directions:

> **Evaluation standard (family-wide).** Returns are fat-tailed, so a bare Sharpe misleads. Every sleeve's
> research toolkit now **tests normality with Jarque-Bera** before leaning on any mean-variance number, and
> reports risk-adjusted performance with **Jensen's alpha** (return beyond what beta earns) and **M²**
> (return re-scaled to the benchmark's own volatility) — not Sharpe alone. Where JB rejects normality (it
> usually does for daily bars), the **left tail / max-drawdown** carries as much weight as the mean. This is
> also the honest core of the *conditional-keeper* idea: a book "fine until the crash" is only a keeper if a
> validated regime gate makes the **gated** version clear the bar on the full sample, black swans *in*.

| Repo | Focus | State |
|------|-------|-------|
| **blaquebaux** | base engine + validated risk-premium spine | live path (paper) |
| **blaquebaux-blunt** | short-horizon tactical (crude→refiner sleeve) | live driver built — **validation PASS** |
| **blaquebaux-bull** | naive long-growth book (QQQ/VUG/XLK), governed | live driver built — the **naive counterpart to broad** (no trend/vol-target). Raw book is growth beta, a regime bet not alpha (bogle #3); made ownable by **balanced's `rate_regime` overlay, validated ON** — on this *unmanaged* book de-risking when rates rise cuts maxDD **−35%→−30%** (13%), lifts Sharpe **+0.96→+1.04** / M² +1.0%→+2.3%, improves skew −0.15→−0.05, keeps 90%. **The one book in the family that earns the rate overlay on-by-default** (broad, managed, declined it — benchmark #4's law from the earning side) |
| **blaquebaux-boom** | mega-cap blue chips (momentum tilt) | live driver built — **validation PASS**. **Two regime overlays wired, both OFF by default.** *bonds*: 0% DD cut / −0.05 Sharpe (the earlier −22% DD was a 2022-window IEX artifact). *market_regime* (the **conditional-keeper test**): cuts maxDD **41%** (−19%→−11%), nudges Sharpe +1.22→**+1.26**, lifts M², and **flips skew −0.31→+0.23** (removes the momentum-crash left tail) — but gives back ~20% of return, **failing the retain-80% bar**, because BOOM already vol-targets (self-de-risks, cf. broad/bridgewater). Ships **opt-in** as drawdown/left-tail insurance, not a default keeper |
| **blaquebaux-brash** | aggressive: crypto, alternatives | research done (growth-vs-ruin lab; fractional-Kelly rule) + **live driver built** — ETF-proxy gate MIXED; thesis PASSES on the real crypto rail (+0.72 aggressive), **crypto execution now wired** — trades real BTC/ETH (aggressive, governed) |
| **blaquebaux-bleed** | contrarian; positioned for the tails | research done (regime-spanning tail basket) + **live driver built** — **validation PASS** (as insurance: +79% vs SPY -82% on crash days) |
| **blaquebaux-bottom** | sub-small-cap / penny names | research done (cap-ladder bounce rejected; a large-cap play) + **live driver built** — **validation PASS** |
| **blaquebaux-brittle** | near-expiry far-OTM options/ETFs | research done (short-vol premium is a trap; naked rejected) |
| **blaquebaux-broad** | broad-market & thematic ETFs (IVES, GRNY, QQQ, TQQQ) | research done (leverage law; managed-exposure keeper) + **live driver built** — **validation PASS**; consumes **blaquebaux-bonds' regime signal** (overlay **ON**, marginal: full-cycle Sharpe +0.94→+0.96, 95% of return kept). The *only* equity consumer where the overlay survives a full-cycle re-test — it already self-de-risks via trend + vol-target. **Declined** benchmark's `market_regime` (redundant: gating cuts Sharpe +0.84→+0.80, its vol-target already does the vol-timing). **Consumes balanced's `rate_regime` opt-in** (rising rates = growth headwind): lifts Sharpe +0.96→+1.03 / M² +0.8%→+2.0% but 0% DD cut → fails the DD bar, ships opt-in (self-manages, same as market_regime) |
| **blaquebaux-bore** | market-neutral, indifferent to bull/bear | research done (beta-hedged keeper) + **live driver built** — **validation PASS**. **Declined** benchmark's `market_regime` overlay (measured beta −0.07; gating a neutral book hurts, Sharpe +0.42→+0.31) — wrong signal for a market-neutral book, keeps its own beta hedge |
| **blaquebaux-bulk** | defense / military & adjacent | research done (moderate factor; systematic null) |
| **blaquebaux-brown** | conservative-leaning sectors (energy, mining, ag, firearms, prisons) | research done (Brown/Blue rotation keeper) + **live driver built** — **validation PASS** |
| **blaquebaux-blue** | entertainment/film, green energy, tech | research done (Brown/Blue rotation keeper) + **live driver built** — **validation PASS** |
| **blaquebaux-beyond** | short-horizon growth (CAGR over weeks, not years) | research done (growth-momentum keeper) + **live driver built** — validation MIXED (stays dry-run) |
| **blaquebaux-bubble** | the AI complex viewed as one | research done (crowded factor; bubble not fadeable) |
| **blaquebaux-basel** | Basel-regulated banks (one regulated factor) | research done (one-factor; macro sleeve) |
| **blaquebaux-bio** | biotech; idiosyncratic FDA events (the anti-Basel) | research done (systematic null) |
| **blaquebaux-bounce** | range-bound "kangaroo" market (mean-reversion) | research done (gated reversal keeper) + **live driver built** — validation MIXED (stays dry-run) |
| **blaquebaux-emea** | Europe, the Middle East & Africa | research done (null — US beta wearing a flag, 11 ETFs → 1.8 bets; FX drag; no rotation edge). **Dollar overlay tested:** only trades return for drawdown (Sharpe flat, 12% DD cut) — does not rescue the null |
| **blaquebaux-apac** | Asia-Pacific | research done (US beta + severe FX drag, Japan −229%; the one region with a rotation pulse, long-short +0.30) + **live driver built** — **validation PASS**. **Dollar overlay declined:** the live L/S book is dollar-neutral (measured beta −0.01 to UUP) — wrong signal, correctly not consumed |
| **blaquebaux-latam** | Latin America | research done (null — US/commodity beta, worst tail −55%, unhedgeable in-wrapper FX, rotation hurts). **Dollar overlay tested:** meaningfully de-risks (DD −55%→−40%, 28% cut) at ~flat Sharpe — a better ingredient, still below SPY, not a keeper |
| **blaquebaux-bitdollar** | crypto / dollar-crypto axis | research done (trend+vol-target keeper; dollar axis rejected) + **live driver built** — ETF-proxy gate MIXED; thesis PASSES on the real BTC/ETH rail (+0.72), **crypto execution now wired** — trades real BTC/ETH (fractional, governed) |
| **blaquebaux-blurred** | deliberately uncorrelated names, traded as one | research done (null — uncorrelated equities are a +0.17 floor & unstable; diversify across asset classes) |
| **blaquebaux-backsliders** | broken decliners, 25%+ off high, no path back (short) | research done (short-the-fallen null; the long bounce is the edge) |
| **blaquebaux-brute-force** | names propped up by options/squeeze/flow | research done (fade rejected; needs positioning data) |
| **blaquebaux-block** | a basket of derivative strategies | research done (the 4 blocks interlock but stay ~4.6/8 diversified; linkages real yet regime-dependent & priced-in — a risk map, diversification is the edge) |
| **blaquebaux-burry** | Michael Burry's book, re-examined (the mechanism, not the man) | research done (**cautionary null** — the style is mostly ~1.0-beta equity (+0.6 corr-to-momentum), buying the hated (3y reversal) nulls out (L/S Sharpe −0.00), shorting froth is regime/ruin (−98% DD, +86% only in 2022), concentration is a ruin machine; residue (gold, Bleed) already in the family. Joins brute-force/backsliders) |
| **blaquebaux-buffett** | Buffett's strategy in fragments (quality/value/safety/leverage) | research done + **live driver built — validation MIXED (stays dry-run)**. On the full 2016–2026 SIP history the cheap-safe-quality QUAL/USMV/VLUE/MOAT blend is **not genuinely defensive** (DD −35% ≈ SPY −34%, Sharpe +0.82 < +0.89) — marginally lower-vol but market-like, so it does not clear the defensive bar. Bonds overlay OFF (adds nothing). Defensive beta, not alpha; the real moat (cheap float) is un-buyable |
| **blaquebaux-beltway** | Democratic-era darlings (Biden/Obama/Clinton) — do they hold up? | research done (**emphatic null — inverted**; 2016+ only, Clinton/Obama out of sample) — the party-aligned basket loses under its own party 4/4; DEM darlings −14.8%/yr under D vs +39.8%/yr under R; under Biden clean energy −21%/yr while fossil +26%/yr — macro dominates, and darlings revert (rank persistence −0.95). Joins bubble/burry) |
| **blaquebaux-brics** | the tradable core of BRICS (best emerging growth engines) | research done + **live driver built** — the keeper (Gulf KSA/UAE/QAT as a low-corr EM **diversifier**); **validation PASS as a diversifier** (corr-SPY 0.56 vs EEM 0.74, vol 15% vs 20.7%, standalone Sharpe +0.46, full-SIP 2016-2026). 'Best of BRICS' (momentum) & the full basket (EM beta) rejected; Russia excluded on the data. A diversifier, not a market-beater. **Dollar-regime overlay wired, validated & ON** (its *right* macro signal, not the bonds one): de-risk ×0.5 when the dollar trends up → Sharpe +0.48→**+0.51**, maxDD −35%→**−20%**; brics also **publishes** `dollar_regime.txt` for the family. Paper/dry-run |
| **blaquebaux-bonds** | the bond–equity relationship (macro overlay for sizing/hedging) | research done + **live driver built** — regime overlay + regime-signal emitter; **validation PASS as an overlay** (full-cycle: cuts equity DD **41%** −34%→−20%, keeps 61% of return, 11% vs 18.7% vol; timing ~static 60/40 as research found — the one overlay that *strengthens* on the full cycle). The corr-regime read (72% persistent a quarter out; hedge works only in neg-corr) is published for the family to size against. Paper/dry-run — not a live-money endorsement |
| **blaquebaux-basket** | exchange / swap funds — hidden private-wealth vehicles | **analytical study done** (4 sketches, grounded in Fidelity / Morgan Stanley GIC / Concentrated-Position-Toolkit docs). All Reg D private placements (democratized $1M/QP → $100k/accredited via Cache, still private); two structures — **721** (≥20% *leveraged real estate* → rate risk, K-1s, ~80% index) vs **351** (diversified-contribution, cleaner). No alpha (fund = index − fee); the product **is** the capital-gains deferral, conditional (**+5–22% after-tax hold-to-death** via the step-up, break-even fee ~1.8%). Its niche vs the toolkit (sell+TLH / completion / collar / CRT): a very-low-basis position you can't afford to sell *or* dilute and intend to hold into your estate. A tax/estate vehicle, not a strategy |
| **blaquebaux-blank** | SPACs / blank-check shells (trust carry, deSPAC shorts, busts) | research done (**diagnostic null** — de-SPAC decay real (−9pp/yr, 60% below the $10 trust) but untradeable: naive short −26%/yr on −89% DD as ASTS +643%/RKLB +429% run it over; broken-subset short buried by 20-100% borrow; sound trust carry needs SPAC-level data — parked. Joins bubble/brute-force) |
| **blaquebaux-benchmark** | market internals as a risk-regime read (VIX, credit, breadth, Dow Theory, defensives) | research done + **regime emitter built** — internals **coincide, they don't lead** (peak cross-corr k=0), but the composite gates SPY net of cost (Sharpe +0.87→**+1.11**, DD −34%→**−16%**). **Publishes `market_regime.txt`** (family's 3rd regime signal) labeled honestly as **vol-timing, not breadth alpha** (strip vol and breadth/credit/DT barely beat B&H). Internals confirm, don't forecast |
| **blaquebaux-bridgewater** | Bridgewater's All-Weather & Pure Alpha | research done — All-Weather is a real low-vol risk-parity compounder (+0.95 Sharpe, ~⅓ market vol) but **the same book as the spine** (corr **0.96**), and the **spine beats it** (+0.97 vs +0.84) by omitting long-bond TLT — an **external validation of the spine**. Pure Alpha = documented gap. **Live driver built**: the recognizable static **All-Seasons** allocation as a distinct low-vol/−23%-DD diversification sleeve — but its `bonds_regime` overlay, the *right* signal for its 2022 failure, **fails the bar** (cuts DD 20% yet costs Sharpe +0.77→+0.74 and 22% of return) because the book already self-diversifies → **overlay OFF**. The **mirror image of blackstone**: right signal, but a book that doesn't need it |
| **blaquebaux-bind** | the rest of the hedge-fund landscape (Millennium, Citadel, pod shops) | research done (**diagnostic null**) — the liquid replicators are watered-down positive-beta (equal-weight book **+3.5%/yr**, not the pods' 10-15%); the only genuinely uncorrelated slices (**DBMF** managed-futures, **BTAL** anti-beta crisis hedge) = the family's **trend + Bleed** already. Real pod-shop edge (leverage × PMs × execution × access) is private/unreplicable. Nothing to add |
| **blaquebaux-blackstone** | listed private-equity managers (BX/KKR/Apollo/Carlyle/Ares) | research done — the "buy, prop, exit" model is a **levered pro-cyclical market/credit factor**, not diversification: beta-SPY **1.39** / beta-XLF 0.99, **1.8/6 eff-bets**, beta-credit **+1.55**, up/down beta 1.34/1.41 (falls harder), coupled to private-credit BDCs. Huge in the easy-money bull (**+784% vs SPY +337%**) but 31% vol / −45→−57% DD → Sharpe +0.83 < SPY +0.88 (extra return is leverage, not skill), the opposite of a hedge — **so the live driver ships it *governed***: equal-weight PE book + benchmark's `market_regime` overlay **ON** (validation PASS). The **first consumer book to *earn* that overlay** — on this uniquely unmanaged high-beta book it lifts Sharpe **+0.76→+0.95** (above SPY), holds CAGR flat, cuts DD **−45%→−31%** for free |
| **blaquebaux-benefactors** | foreign creditors — US Treasury holdings by country vs their economies/markets | research done (**honest macro null**) — FRED data (Japan 1984, China 2003) supplied by hand (box can't reach FRED). A creditor's Treasury *buying* has only a weak ~+0.15 coincident link to its own market, swamped by global (SPY) beta, **no clean lead** — for China the *market leads the flow* (+0.18), so causality runs **backward**. Creditor status is a macro read, not a signal. Market test ETF-capped to 2016-2026 |
| **blaquebaux-buyouts** | post-buyout targets — pump-and-dump on the exit? | **[Concept]** — the PE *targets* (cf. blackstone = the managers). Private "prop it up" leg is invisible (no ticker); testable surface = sponsor-backed IPOs/re-IPOs (`IPO`/`FPX`) + post-lockup drift → a **short/avoid** thesis on the sponsor exit. Fat-tail toolkit (JB + Jensen's α + M²) |
| **blaquebaux-bigbrother** | America's new SOEs — US government equity stakes (Intel, CHIPS, bailouts) | **[Concept]** — does a government backstop prop the stock (implicit put) or **drag it like a China SOE** (state ownership destroys value)? Two opposed hypotheses; the tell is the **tail**. Rare hand-curated stake events + an industrial-policy/defense basket vs SPY |
| **blaquebaux-battered** | distressed assets that survive to pay out (the MF Global playbook) | **[Concept]** — fallen angels (`ANGL`), high-yield; the *right-thesis-killed-by-leverage* lesson. A prime **conditional-keeper** case — the fat left tail is the true cost, so verdicts lean on JB + max-drawdown. OTC distressed invisible; `ANGL`/`HYG` proxies, survivorship flagged |
| **blaquebaux-bets** | the gambling complex (sports betting, casinos, prediction markets) | **[Concept]** — durable "house always wins" premium, or levered consumer discretionary? Kalshi/Polymarket private (gap); listed books/casinos + `BETZ` testable vs SPY/XLY. Fat-tail toolkit |
| **blaquebaux-balanced** | value investing / margin of safety — still crucial? | research done — **value is a rate-regime bet, and "margin of safety" is mostly a myth at the factor level.** Value **lagged growth** risk-adjusted (RPV α −2.3% / M² −4.9% vs RPG −3.4%; spread −1.9%/yr) — a different beta, not alpha (cf. bogle). It crashed **harder** than growth (pure value maxDD **−51% vs −37%**, worse skew) — the safety folklore inverted; its only real safety is lower downside vol + cushioning growth-specific selloffs. Its one strong, clean signal is **rate-conditional** (value−growth **+12.3%/yr rising rates, −12.3%/yr falling**), but a coarse rate-timed rotation (α +1.8%) **doesn't clear** the SPY hurdle net of cost (M² −0.5%). A conditional-keeper **ingredient**, not a standalone edge — **publishes `rate_regime.txt`** (the family's 4th regime signal) for value-sensitive consumers |
| **blaquebaux-bogle** | Vanguard / low-cost indexing | research done (**meta-sleeve — the hurdle**) — the `VOO` line **Sharpe +0.89 / Jensen-α 0 / M² 0** is the bar the family is measured against. Broader diversification *cost* return this US-led decade (VTI α −0.7%, VT α −1.6%); **0/7** Vanguard tilts beat plain VOO risk-adjusted (tilting = different beta, not alpha); only **2/10** popular active/thematic funds cleared it (QQQ/XLK — pure tech-beta, a regime bet), and **ARKK** hid a **−81% DD** behind +13% CAGR. Bogle stands; the toolkit makes it precise. **Publishes `bogle_hurdle.txt`** (the plain-VOO bar) + a reusable scorer — the family yardstick. *(Also corrected M² to the Sharpe-difference form → benchmark-vs-itself = 0.)* |
| **blaquebaux-bureaucrats** | congressional trading under the STOCK Act (Pelosi et al.) | **[Concept]** — do lawmakers beat the market, or is it a **mega-cap-tech tilt**? `NANC`/`KRUZ` tracker ETFs priceable from 2023; granular STOCK Act data hand-supplied (egress wall). Distinct from beltway (party-era winners) — this is the legislators' personal book |
| **blaquebaux-belt-tighteners** | the inflation domino across sectors, globally | **[Concept]** — belt-tightening cascade `XLY→XLP→XLB→XLU→XLRE→XLE`, then contagion when **US + China** sneeze together. A **correlation-tightening** study; inflation via breakevens or hand-loaded CPI; `XLC` only from 2018, global capped ~2016 |

Cross-family paper A/B is monitored by `scripts/family_summary.py` (each leg's keys live in
`~/.config/blaquebaux/`, so it snapshots whatever sleeves are active).

### Cross-sleeve wiring — published regime signals

Some sleeves *feed* others rather than trade alone. **Four published regime signals** now exist (plus
bogle's benchmark **hurdle**), each matched to the sleeves it actually helps — the discipline is *match the
signal to the sleeve*:

- **[bonds](https://github.com/blaquebaux/bonds)** → `bonds_regime.txt` (US **stock-bond correlation**) —
  for net-long **US-equity** sleeves.
- **[brics](https://github.com/blaquebaux/brics)** → `dollar_regime.txt` (US **dollar trend**, UUP vs
  100d MA) — for **USD/international** sleeves (a rising dollar is an EM headwind).
- **[balanced](https://github.com/blaquebaux/balanced)** → `rate_regime.txt` (US **rate direction**, IEF vs
  100d MA) — for **value/growth-sensitive** sleeves (value beats growth +12%/yr when rates rise, −12% when
  they fall; the regime is clean, the coarse rotation itself doesn't beat the index — an ingredient).
  Consumers tested: on *managed* **[broad](https://github.com/blaquebaux/broad)** (QQQ) it lifts Sharpe
  +0.96→+1.03 / M² +0.8%→+2.0% but cuts 0% off drawdown → **opt-in** (broad self-manages). On the *naive*
  growth book **[bull](https://github.com/blaquebaux/bull)** (QQQ/VUG/XLK, no trend/vol-target) the *same*
  signal **earns ON-by-default** — DD −35%→−30% (13% cut), Sharpe +0.96→+1.04, keeps 90% — because the naive
  book has the drawdown gap the managed one already filled. The law holds: a de-risking overlay's value ∝
  how unmanaged the book is (and whether its worst DD is rate-driven). bull is the sleeve built to earn it.
- **[bogle](https://github.com/blaquebaux/bogle)** → `bogle_hurdle.txt` (the plain-**VOO** bar) + a reusable
  scorer — not a regime but the **yardstick** every sleeve is measured against (clear it net of cost/tax:
  Jensen α > 0 AND M² > 0 vs VOO, or it isn't a keeper).
- **[benchmark](https://github.com/blaquebaux/benchmark)** → `market_regime.txt` (**market-internals**
  risk-on/off composite) — a broad de-risking flag, *honestly labeled vol-timing, not breadth alpha*.
  Its value shrinks monotonically with how much a book already manages its own risk (benchmark #4):
  **earned by naive high-beta books with no risk control** — benchmark's own gated-SPY (SPY +0.87→+1.11)
  and now **[blackstone](https://github.com/blaquebaux/blackstone)**, the first *consumer* sleeve to earn
  it (levered listed-PE, Sharpe +0.76→+0.95 / DD −45%→−31% / CAGR flat) — and **declined by the
  managed/neutral sleeves** — `broad` (redundant with its trend+vol-target, +0.84→+0.80), `bore`
  (market-neutral → wrong signal), and `boom` (the **conditional-keeper test**: cuts DD 41% and flips skew
  −0.31→+0.23, i.e. removes the momentum-crash left tail, but gives back ~20% return → fails the retain-80%
  bar since it already vol-targets; ships **opt-in insurance**, not default). So it's earned where nothing
  else manages the vol, and refused (or made opt-in) everywhere that already does.

**The bonds (stock-bond) overlay**, consumed to de-risk gross when the bond hedge is dead. Each consumer
is validated independently on the **full 2016–2026 SIP history** — it ships on *only* where it earns it:

| consumer | overlay effect (full cycle) | default |
|----------|-----------------------------|---------|
| **bonds** (own overlay vs static 60/40) | **−41% drawdown** (−34%→−20%), timing ≈ static | **ON** |
| **broad** | +0.02 Sharpe, ~flat DD — marginal but consistent | **ON** |
| **bridgewater** (All-Weather) | −20% DD (−23%→−19%) but −0.03 Sharpe & keeps only 78% return | OFF |
| **boom** | 0% DD cut, −0.05 Sharpe | OFF |
| **buffett** | no DD help, −0.04 Sharpe | OFF |
| **keeper book** | no change (−6% DD either way) | OFF |

**Honest finding (after a full-cycle re-test):** the equity-sleeve de-risk overlay is *not* the broad
win it first looked like. An early pass on the engine's default IEX feed (only ~2021+) showed boom
gaining a −22% drawdown cut — but that was a **2022-window artifact**: boom's worst full-cycle drawdown
is the 2020 COVID crash, a *negative*-correlation episode the overlay correctly leaves alone. On the
full cycle the equity overlay barely helps anywhere; only **broad** keeps it (marginally). The robust,
strengthening benefit is **bonds' own overlay** — the direct hedge-vs-cash switch — which cuts drawdown
41% across the 2020 and 2022 crashes.

**The dollar (UUP-trend) overlay** is the counter-example that proves the discipline. Pointed at
**brics** (a USD-EM book, −0.66 beta to the dollar), de-risking the Gulf ×0.5 when the dollar trends up
**improves** Sharpe (+0.48→+0.51) *and* cuts drawdown 43% (−35%→−20%) on the full cycle — a clean win,
because it's the *right* signal for that book. The same book correctly *rejects* the bonds overlay.
The other USD/international sleeves were tested against it too, and the honest results differ by book:

| consumer | dollar overlay effect (full cycle) | outcome |
|----------|-----------------------------------|---------|
| **brics** (Gulf) | Sharpe +0.48→**+0.51**, DD **−35%→−20%** | **ON** — earns it |
| **latam** | ~flat Sharpe, DD **−55%→−40%** (28% cut) | de-risks; a better ingredient, still a null |
| **emea** | flat Sharpe, DD −40%→−35% (12% cut) | trades return for DD; still a null |
| **apac** | live L/S book is **dollar-neutral** (beta −0.01) | **declined** — wrong signal for a neutral book |

Same lesson as the bonds side: *the dollar is the right lever to try for a USD-exposed book, but only
brics clears the bar; the rest are de-risked at best, and apac's neutral live book declines it outright.*

The lesson: **match the signal to the sleeve, validate each pairing on the full cycle, ship on only
what earns it** — and beware short-window results. Every consumer keeps a graceful fallback
(missing/stale signal → full gross) and a `BB_BONDS_OVERLAY` / `BB_DOLLAR_OVERLAY` toggle.

**A deeper law, revealed by the fat-tail toolkit (Jarque-Bera + skew + Jensen's α + M²).** Returns are
non-normal (JB rejects normality everywhere), so an overlay's real job is the *left tail*, which Sharpe
can't see. Re-examining the borderline declines under the toolkit shows an overlay only buys genuine tail
insurance — **flips return skew from negative to positive** — when it de-risks on a **crash-timing** signal:
`market_regime` (vol-timing) did exactly that for **boom** (skew −0.31→**+0.23**, DD −41%), making it an
opt-in insurance overlay. Overlays keyed on a **persistent state** — the stock-bond correlation (**bridgewater**,
~33% of days) or the dollar trend (**latam**, ~63% of days) — de-risk indiscriminately, so they shed return
and *worsen* skew (bridgewater −0.32→−0.73; latam −0.94→−1.16) instead of catching the tail. And "defensive"
is itself a tail claim: **buffett**'s blend has a *worse* skew and *negative* Jensen's α / M² vs SPY — not
defensive at all. So the toolkit doesn't rescue borderline nulls; it **discriminates by mechanism** —
crash-timed overlays can insure, state-timed ones only shave — and sharpens every honest rejection.

## Contributing / using this

You're welcome to study, fork, and build on this. If you deploy real capital, **validate
independently** and start on paper. Issues and PRs that improve the math, the tests, or the
execution safety are especially welcome.

## BLAQUE BAUX

Explore the [production site](https://www.blaquebaux.com/), [interactive LABS](https://www.blaquebaux.com/labs/), and [open research CORPUS](https://www.blaquebaux.com/corpus/).

## License

[MIT](LICENSE), plus a [not-financial-advice notice](DISCLAIMER.md). © 2026 Carter Warrens.
