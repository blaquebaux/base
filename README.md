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
alpha*; *aggression multiplies edge, and with none it multiplies only ruin*. Every result is a
reproducible sketch in [`scripts/research/`](scripts/research/) (11 scripts), consolidated in
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
scripts/research/          11 reproducible research sketches (the scorecard's evidence)
test/                    gate + (quarantined legacy) suites
```

## Status

- **Paper-tested end-to-end** (data → strategy → governed orders → ledger with lineage →
  reconciliation) against a real broker paper account.
- The strategy is validated out-of-sample; the live path is verified on paper.
- Real capital has **not** been deployed. The legacy Gamma-ARMA base modules (a separate research
  lineage) are quarantined from the test gate; see `test/runtests.jl`.

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

| Repo | Focus | State |
|------|-------|-------|
| **blaquebaux** | base engine + validated risk-premium spine | live path (paper) |
| **blaquebaux-blunt** | short-horizon tactical (crude→refiner sleeve) | live driver built |
| **blaquebaux-boom** | mega-cap blue chips (momentum tilt) | live driver built |
| **blaquebaux-brash** | aggressive: crypto, alternatives | scaffold |
| **blaquebaux-bleed** | contrarian; positioned for the tails | scaffold |
| **blaquebaux-bottom** | sub-small-cap / penny names | scaffold |
| **blaquebaux-brittle** | near-expiry far-OTM options/ETFs | scaffold |
| **blaquebaux-broad** | broad-market & thematic ETFs (IVES, GRNY, QQQ, TQQQ) | scaffold |
| **blaquebaux-bore** | market-neutral, indifferent to bull/bear | scaffold |
| **blaquebaux-bulk** | defense / military & adjacent | scaffold |
| **blaquebaux-brown** | conservative-leaning sectors (energy, mining, ag, firearms, prisons) | scaffold |
| **blaquebaux-blue** | entertainment/film, green energy, tech | scaffold |

Cross-family paper A/B is monitored by `scripts/family_summary.py` (each leg's keys live in
`~/.config/blaquebaux/`, so it snapshots whatever sleeves are active).

## Contributing / using this

You're welcome to study, fork, and build on this. If you deploy real capital, **validate
independently** and start on paper. Issues and PRs that improve the math, the tests, or the
execution safety are especially welcome.

## License

[MIT](LICENSE), with a not-financial-advice notice. © 2026 Carter Warrens.
