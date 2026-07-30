# Blaque Baux — Financial Methods

**A risk-premium harvesting platform: the mathematics, honestly.**

*Version 1.0 · 2026-07-30 · reference implementation in Julia (execution + strategy) with an archived Python research track.*

---

## 0. Abstract

Blaque Baux is a systematic, governed trading platform. Its live strategy — the **spine** — does **not** attempt to predict returns. It harvests **risk premia** (diversification, trend, term/asset premia) and manages risk with a stateful daily process, then routes every order through a governed execution layer that enforces hard invariants. This document specifies the financial mathematics as implemented, and states plainly what is validated, what is research, and what did **not** work.

The central empirical result that shaped the platform: on the instruments and horizons tested, **there was no exploitable predictive edge** (information coefficient ≈ 0; see §7). The edge that *does* exist and survives out-of-sample is in the **risk structure** — diversification and risk-timing — not in return forecasting. Everything below follows from that finding.

> **Not investment advice.** This is an engineering/quantitative reference. All performance figures are historical backtests or paper-trading results, net of modeled costs; they are not a promise of future results. Trading involves risk of loss.

---

## 1. Notation and data

Let there be $N$ assets and discrete time steps $t = 1,\dots,T$ (daily bars unless stated).

- **Prices** $P_{t,i}$ (split/dividend-adjusted, i.e. total-return closes).
- **Simple returns**

$$ r_{t,i} = \frac{P_{t,i}}{P_{t-1,i}} - 1 . $$

- $R \in \mathbb{R}^{T\times N}$ is the return matrix (rows = time, columns = assets). This $T\times N$ convention is used throughout the code.
- $w_t \in \mathbb{R}^N$ is the target weight vector at time $t$ (fractions of capital; may be negative for shorts; $\sum_i |w_{t,i}|$ is **gross** exposure, $\sum_i w_{t,i}$ is **net**).
- Annualization uses $\mathrm{ppy}$ periods per year (252 for daily).

Reference universe (US ETFs, chosen for long history and low survivorship bias): **SPY** (US equity), **IEF** (7–10y Treasuries), **TLT** (20y+ Treasuries), **GLD** (gold), **DBC** (broad commodities).

---

## 2. Covariance estimation (EWMA / RiskMetrics)

The strategy is driven by **second moments**, which are more forecastable than first moments. The default estimator is an exponentially-weighted (RiskMetrics-style) covariance with half-life $H$.

Decay per step and normalized weights over a trailing window of length $T$:

$$ \lambda = 0.5^{1/H}, \qquad \tilde w_j = \frac{\lambda^{\,T-j}}{\sum_{k=1}^{T}\lambda^{\,T-k}}, \quad j = 1,\dots,T . $$

Weighted mean and covariance:

$$ \hat\mu = \sum_{j} \tilde w_j\, R_{j,\cdot}, \qquad \hat\Sigma = \sum_{j} \tilde w_j\, (R_{j,\cdot}-\hat\mu)^\top (R_{j,\cdot}-\hat\mu), $$

symmetrized as $\tfrac12(\hat\Sigma+\hat\Sigma^\top)$. The spine uses $H = 21$ (≈ a pandas `span`-60 EWMA), matching the horizon at which the strategy was validated.

Also available (`moments.jl`): unbiased `sample_cov`, Ledoit–Wolf constant-correlation `shrinkage_cov` (analytic optimal intensity), `nearest_psd`, `cov2cor`.

---

## 3. The spine — portfolio construction

The spine is a **two-sleeve** book: a long-biased *base* that harvests the diversification premium by risk structure, plus a *trend* sleeve that is the divergent, crisis-hedging component. Each sleeve is independently volatility-targeted, the two are blended, and a regime overlay scales gross exposure.

### 3.1 Base sleeve — risk-based weights (no return forecast)

The base allocates by **risk**, not expected return. Three options (`riskbased.jl`), default **inverse-vol**:

- **Inverse-volatility** (naive risk parity):

$$ w^{\text{iv}}_i = \frac{1/\sigma_i}{\sum_j 1/\sigma_j}, \qquad \sigma_i = \sqrt{\hat\Sigma_{ii}} . $$

- **Inverse-variance:** $w_i \propto 1/\sigma_i^2$.

- **Equal-risk-contribution (ERC / risk parity):** weights such that every asset contributes equally to portfolio variance. With marginal contribution $\mathrm{RC}_i = w_i(\hat\Sigma w)_i$, ERC solves the convex program

$$ \min_{w>0}\; \tfrac12\, w^\top \hat\Sigma\, w \;-\; \sum_i b_i \ln w_i, \qquad b_i = \tfrac1N, $$

whose first-order condition is $w_i(\hat\Sigma w)_i = b_i$ for all $i$. It is solved by cyclical coordinate descent (solver-free, robust inside a backtest loop): for each $i$, solve the scalar quadratic

$$ \hat\Sigma_{ii}\, w_i^2 + \Big(\textstyle\sum_{j\ne i}\hat\Sigma_{ij} w_j\Big) w_i - b_i = 0, \quad w_i>0, $$

then renormalize $w \gets w/\sum_i w_i$.

Also implemented: **maximum diversification** (Choueifaty–Coignard: maximize the diversification ratio $\frac{w^\top \sigma}{\sqrt{w^\top\hat\Sigma w}}$) and **Hierarchical Risk Parity** (López de Prado: correlation-distance $d_{ij}=\sqrt{(1-\rho_{ij})/2}$, hierarchical clustering, quasi-diagonalization, recursive bisection by inverse cluster variance — no matrix inversion, stable when $N$ is large relative to sample length).

### 3.2 Trend sleeve — time-series momentum

The trend sleeve is the only place a *directional* view enters, and only at a horizon where momentum is real (§8.1). For each asset, the 12-month time-series-momentum sign:

$$ s_i = \operatorname{sign}\!\Big( \textstyle\prod_{u=t-k+1}^{t}(1+r_{u,i}) - 1 \Big), \qquad k = 252 . $$

Inverse-vol scaled and gross-normalized to a long/short book:

$$ w^{\text{trend}}_i = \frac{s_i/\sigma_i}{\sum_j |s_j/\sigma_j|}, \qquad \textstyle\sum_i |w^{\text{trend}}_i| = 1 . $$

This is the standard managed-futures construction (Moskowitz–Ooi–Pedersen): it goes long assets trending up and **short** assets trending down, sized to equalize each position's risk.

### 3.3 Per-sleeve volatility targeting (load-bearing)

Each sleeve is scaled to a target volatility $\sigma^\star$ (default 8%), using the sleeve's **own realized P&L volatility**, tracked with a RiskMetrics recursion on the realized sleeve return $p_t = w_{t-1}\!\cdot r_t$:

$$ v_t^2 = \lambda\, v_{t-1}^2 + (1-\lambda)\, p_t^2, \qquad \hat\sigma^{\text{sleeve}}_t = \sqrt{v_t^2 \cdot \mathrm{ppy}} . $$

Exposure multiplier (capped, de-risk-only when $\text{cap}\le 1$):

$$ e_t = \min\!\Big(\text{cap},\ \frac{\sigma^\star}{\hat\sigma^{\text{sleeve}}_t}\Big) . $$

> **Why realized-P&L vol, not ex-ante asset vol?** A long/short trend book's P&L can be *smooth while it works* (e.g. steadily short bonds in 2022) even as the underlying asset vols spike. Targeting on ex-ante asset-covariance vol would throttle the hedge exactly when it pays; targeting on the sleeve's own realized P&L keeps it engaged. This distinction is verified — using ex-ante vol collapses the strategy's crisis performance.

### 3.4 Blend and regime overlay

Blend the vol-targeted sleeves (default $\theta = 0.5$):

$$ \tilde w_t = \theta\, e^{\text{base}}_t\, w^{\text{base}}_t \;+\; (1-\theta)\, e^{\text{trend}}_t\, w^{\text{trend}}_t . $$

A discrete **regime brake** scales gross exposure using the drawdown state of an equal-weight market proxy $m_t = \frac1N\sum_i r_{t,i}$ with index $I_t = \prod_{u\le t}(1+m_u)$:

$$ \mathrm{dd}_t = \frac{I_t}{\max_{u\le t} I_u} - 1, \qquad g_t = \begin{cases} \phi & \text{if } \mathrm{dd}_t < -0.08 \\ 1 & \text{otherwise} \end{cases}\quad (\phi = 0.5). $$

Final target book:

$$ \boxed{\,w_t = g_t \cdot \tilde w_t\,.} $$

The regime brake was selected empirically over four candidate signals (vol-spike, drawdown, correlation, trend); the drawdown variant improved risk-adjusted return at ≈ zero cost, while the others whipsawed or never triggered on a diversified book (§8.2).

### 3.5 Stateful daily update

In production the spine is stateful: `SpineState` carries each sleeve's RiskMetrics variance $(v^{\text{base}}, v^{\text{trend}})$ and the last-held weights across days. Each trading day, `spine_step!(state, window)`:

1. folds the just-realized bar into each sleeve's vol via §3.3 (using the previously-held weights);
2. recomputes base and trend weights from the trailing window (§3.1–3.2);
3. sizes each sleeve (§3.3), blends (§3.4), applies the regime brake;
4. returns the target book and stores the new sleeve weights.

Positions are then converted to signed share targets $q_i = w_i \cdot C / P_i$ (capital $C$, price $P_i$) and reconciled against the broker so the strategy trades the **delta**, not the full target, each day.

---

## 4. Risk metrics

Standard definitions (`metrics.jl`), all annualized with $\mathrm{ppy}=252$.

- **Annualized return** (geometric): $\big(\prod_t(1+r_t)\big)^{\mathrm{ppy}/T} - 1$.
- **Annualized volatility:** $\operatorname{std}(r)\sqrt{\mathrm{ppy}}$.
- **Sharpe ratio:** $\dfrac{\bar r\,\mathrm{ppy} - r_f}{\operatorname{std}(r)\sqrt{\mathrm{ppy}}}$.
- **Sortino ratio** (downside deviation about a minimum acceptable return $\text{MAR}$):

$$ \text{DD} = \sqrt{\operatorname{mean}\big(\min(r-\text{MAR},0)^2\big)}\,\sqrt{\mathrm{ppy}}, \qquad \text{Sortino} = \frac{\text{AnnRet}-r_f}{\text{DD}} . $$

- **Drawdown series and max drawdown:** with cumulative $C_t=\prod_{u\le t}(1+r_u)$,

$$ \mathrm{DD}_t = \frac{C_t}{\max_{u\le t}C_u} - 1, \qquad \mathrm{MaxDD} = \min_t \mathrm{DD}_t . $$

- **Calmar ratio:** $\text{AnnRet}\,/\,|\mathrm{MaxDD}|$.
- **Value-at-Risk** at confidence $\alpha$ (three methods):
  - *Historical:* $\mathrm{VaR}_\alpha = -Q_{1-\alpha}(r)$.
  - *Gaussian:* $-(\mu + z_{1-\alpha}\sigma)$.
  - *Cornish–Fisher* (skew/excess-kurtosis adjusted):

$$ z_{cf} = z + (z^2-1)\tfrac{s}{6} + (z^3-3z)\tfrac{k}{24} - (2z^3-5z)\tfrac{s^2}{36}, \qquad \mathrm{VaR}_\alpha = -(\mu + z_{cf}\,\sigma). $$

- **Expected shortfall (CVaR):** $\mathrm{ES}_\alpha = -\operatorname{mean}\{\,r : r \le Q_{1-\alpha}(r)\,\}$.

---

## 5. Governed execution — risk invariants as guards

Every order passes through one governed path (`ExecutionController`) that enforces hard, testable invariants before the order can reach a venue. These are risk *controls*, not strategy — the strategy proposes, the controller disposes.

| Invariant | Rule |
|---|---|
| **Idempotency** (REQ-EXEC-002) | Client order id = `pool\|symbol\|solve_id`; a repeated solve never double-submits (also deduped broker-side). |
| **Per-pool budget** (REQ-RISK-003) | Reject if cumulative emitted notional in a pool exceeds its daily budget; reset each trading day. |
| **Daily loss halt** (REQ-RISK-004) | Halt the pool if realized daily P&L $\le -L_{\max}$. |
| **Data staleness** (REQ-DATA-003) | Reject emission if the pool's market data is older than a threshold. |
| **Reconciliation** (REQ-EXEC-003) | Compare fill-driven expected positions to broker positions; on divergence beyond tolerance, halt. |
| **Kill switch** (REQ-GOV-002) | A manual/alert stop halts all normal emission; liquidation orders bypass it (you must always be able to flatten). |
| **Fill lineage** (REQ-AUDIT-001) | Every recorded fill carries `signal_id / regime / solve_id / order_id`. |

### 5.1 Layer-3 pre-trade safety gate (live money)

Before any order in live mode, a pre-flight aggregate must pass (`SafetyGate.preflight`), else the book is halted and an alert fires. Guards include:

- **Drawdown halt:** with a persisted equity high-water mark $\mathrm{HWM}$, halt if $\dfrac{E}{\mathrm{HWM}}-1 < -d_{\max}$ (default 15%).
- **Daily-loss halt:** halt if $E - E_{\text{prev}} < -L_{\max}$.
- **Gross-leverage cap:** reject if $\dfrac{\sum_i |q_i| P_i}{E} > \Lambda_{\max}$ (default 2×).
- **Per-name cap:** reject if any $|q_i|P_i / E$ exceeds a bound (default 0.85 — a *runaway-bug* catcher; genuine concentration risk is handled by the risk-based construction and the gross/drawdown caps, since inverse-vol legitimately places large weight in low-vol bonds).
- **Account & data checks:** account active/not blocked, sufficient buying power, data fresh.

---

## 6. Composition — the daily pipeline

$$ \text{prices} \xrightarrow{\S1} R \xrightarrow{\S2} \hat\Sigma \xrightarrow{\S3}\ \underbrace{w_t}_{\text{spine target}}\ \xrightarrow{\ \times C/P\ } q_t \xrightarrow[\text{seed from broker}]{\text{delta}}\ \underbrace{\text{governed orders}}_{\S5}\ \to\ \text{fills}\to\text{reconcile}. $$

One rebalance per trading day (§8.3 explains why not intraday), executed pre-open so orders fill at the open.

---

## 7. Validation methodology — measuring edge honestly

The platform's design was gated on **out-of-sample edge tests**, not in-sample fit.

### 7.1 Information Coefficient

For a per-bar cross-sectional score $x_{t,i}$ and forward return $r_{t+1,i}$, the **Information Coefficient** is the Spearman rank correlation across assets each window; the **IC information ratio** is its $t$-statistic across $N_w$ windows:

$$ \mathrm{IC}_t = \rho_{\text{Spearman}}\big(x_{t,\cdot},\, r_{t+1,\cdot}\big), \qquad \mathrm{IC\text{-}IR} = \frac{\overline{\mathrm{IC}}}{\operatorname{std}(\mathrm{IC})}\sqrt{N_w}. $$

A signal is treated as real only if roughly $|\overline{\mathrm{IC}}| > 0.02$ **and** $|\mathrm{IC\text{-}IR}| > 2$.

### 7.2 Out-of-sample discipline

- **Train/test split** and walk-forward evaluation; parameters fixed *a priori* (round numbers), never tuned on the test window.
- **Control for confounds:** e.g. when testing a regime-conditional blend, compare not only to the static baseline but to *static-at-the-adaptive-rule's-own-mean-weight*, to separate genuine timing value from "just ran a different constant."
- **Purged K-fold / combinatorial-purged CV** (López de Prado) is available for series with overlapping labels (`module_11_cv`).
- **Multiple-testing awareness:** a rule is granted one or two well-motivated shots; fishing variants until one passes is treated as p-hacking and rejected.

### 7.3 The decisive result

On 60-day 15-minute data (≈1,547 bars × 60 S&P names), two candidate alpha models were tested:

| Model | Directional accuracy | $p$ vs 50% | IC |
|---|---|---|---|
| 3-factor cross-sectional | 50.9% | 0.48 | −0.004 |
| Bayesian (Kalman/NIG/James–Stein/ADVI) | 50.7% | 0.59 | +0.001 |

Both are **coin flips.** There was no exploitable predictive edge at this horizon/universe. This is *why* the platform harvests risk premia rather than forecasts returns.

---

## 8. Empirical findings that shaped the design

All figures are historical backtests, net of ~2 bps/side costs, on the reference universe.

### 8.1 Momentum vs. reversal by horizon

IC of a trailing $k$-day return against the next-day return, pooled across assets, 2006–2026:

| $k$ | 1d | 2d | 3d | 5d | 10d | 21d | 63d | 126d | 252d |
|---|---|---|---|---|---|---|---|---|---|
| IC | −.038 | **−.041** | −.035 | −.031 | −.021 | −.010 | −.000 | +.005 | +.002 |

Short horizons (1–63d) exhibit **reversal** (a sharp drop tends to bounce); **momentum** appears only at 126–252d. This is the quantitative reason the trend sleeve uses a **12-month** lookback and why "shorting a 2-day selloff" fights the strongest short-horizon force in the data.

### 8.2 The validated spine

Base ⊕ trend ⊕ vol-target ⊕ regime brake, 2007–2026 (incl. GFC, COVID, 2022):

| Configuration | Sharpe | Sortino | Max DD | 2022 |
|---|---|---|---|---|
| Diversified base only | 0.85 | 1.24 | −18% | −15% |
| **Spine (base + trend), regime `:none`** | **0.94** | 1.28 | **−10.6%** | −3.2% |
| **Spine, regime `:dd`** (production) | **0.97** | 1.30 | −10.6% | **−1.4%** |

The trend sleeve made **+4.4% in 2022** (short bonds / long energy) while a long-only book bled — that is the crisis hedge working as designed.

### 8.3 Cadence — daily, not intraday

On 17,659 real 15-minute bars (2022–2026), applying the daily book intraday: holding through the day gives Sharpe ≈ 1.24. An intraday vol-brake **never triggered** (a 5-asset diversified book barely moves intraday — stocks/bonds/gold/commodities offset within the bar; diversification *is* the intraday shock absorber). An intraday drawdown-brake **whipsawed** (−1% CAGR for −0.7% max-DD). Full 15-minute re-optimization is pure cost drag — risk premia do not change in 15 minutes. **Conclusion: once-daily rebalance.**

### 8.4 Leverage — the return/drawdown trade-off

Leverage $L$ on the strategy return $r_t$, financing the borrowed portion at annual rate $f$:

$$ r^{L}_t = L\, r_t - (L-1)\,\frac{f}{\mathrm{ppy}} . $$

2007–2026, financing at 3% (the friendliest case) vs. 6.5% (today's retail margin):

| $L$ | CAGR @3% | CAGR @6.5% | Vol | Sharpe | Max DD |
|---|---|---|---|---|---|
| 1.0 | +5.9% | +5.9% | 6.1% | 0.97 | −10.6% |
| 1.5 | +7.2% | +5.4% | 9.2% | 0.81 | −18.1% |
| 2.0 | +8.5% | +4.7% | 12.2% | 0.73 | −25.1% |
| 3.0 | +10.6% | +3.2% | 18.3% | 0.64 | −39.1% |

Two facts: (i) **Sharpe only falls with leverage** (financing is a pure drag on risk-adjusted return); (ii) at today's ~6.5% margin, leverage is **net-negative** — the strategy's ~6% return is below the cost of borrowing, so leverage subtracts return while amplifying drawdown roughly $\propto L$. Double-digit CAGR requires ~3×, which comes with a **−39% drawdown**. There is no double-digit-return-at-low-risk configuration.

---

## 9. The research track (Python) — archived, and why

The platform began as an alpha-prediction system. That code is preserved (archived) because the mathematics is sound, but it is **not on the live path** — edge validation (§7) found no predictive signal at the horizons tested. Documented honestly:

- **Bayesian alpha engine** (`signal_engine.py`): per-ticker return estimation via Kalman filtering → Normal-Inverse-Gamma conjugate updating → James–Stein shrinkage → ADVI, combined by inverse-variance weighting. Mathematically correct; **no measured predictive edge** (§7.3).
- **Monte-Carlo risk engine** (`monte_carlo_engine.py`): geometric-Brownian-motion simulation of a portfolio given *assumed* drift and volatility, producing VaR/CVaR/expected-shortfall/probability-of-profit. It is a **risk calculator, not an optimizer** — it sizes a position's tail; it does not create return. Correct tool for sizing a premium by its tail; wrong tool to find one.
- **Six-Sigma Oracle** (`risk_engine.py`): samples weight vectors and minimizes a simulated loss rate subject to a return target — i.e. Sharpe maximization on **historical means**. This is the Markowitz *error-maximization* trap: optimizing on noisy sample means fails out-of-sample. Its correct use is **survival-sizing** ("at exposure $X$, what is the six-sigma loss?" → cap gross so the tail stays within budget), not return generation.

The lesson, stated once: sophisticated machinery (long/short, QP optimization, Monte-Carlo, Bayesian filtering) *packages and sizes* a signal; it does not *create* one. The signal is the constraint, and at the tested horizons it was not there.

---

## 10. Code map

| Concept (§) | File · key symbols |
|---|---|
| Returns, moments, EWMA cov (§1–2) | `src/module_13_portfolio/moments.jl` · `simple_returns`, `ewma_cov`, `shrinkage_cov`, `nearest_psd` |
| Base weights (§3.1) | `src/module_13_portfolio/riskbased.jl` · `inverse_variance`, `risk_parity`, `max_diversification`, `hrp_weights` |
| Spine: trend, vol-target, blend, regime, stateful (§3.2–3.5) | `src/module_13_portfolio/spine.jl` · `tsmom_signal`, `tsmom_weights`, `voltarget_exposure`, `regime_multiplier`, `SpineState`, `spine_step!`, `spine_targets` |
| Metrics, VaR/CVaR (§4) | `src/module_13_portfolio/metrics.jl` · `sharpe`, `sortino`, `max_drawdown`, `calmar`, `value_at_risk`, `expected_shortfall` |
| Mean-variance / CVaR / Black-Litterman | `meanvariance.jl`, `tailrisk.jl`, `blacklitterman.jl` |
| Purged / combinatorial CV (§7.2) | `src/module_11_cv/` |
| Governed execution invariants (§5) | `src/module_7_execution/` · `execution_controller.jl`, `venue_interface.jl`, `venues/` |
| Layer-3 safety gate (§5.1) | `src/module_8_governance/safety_gate.jl` · `SafetyLimits`, `preflight`, `drawdown` |
| Data adapters (Alpaca / IBKR / CSV) | `src/module_1_data/` · `equity_panel.jl`, `alpaca_panel.jl`, `ibkr_panel.jl` |
| Live driver + safety | `scripts/spine_live.jl`, `scripts/run_spine_daily.sh` |
| Leverage / cadence / validation analyses (§7–8) | `scripts/leverage_decision_data.jl`, `docs/CANONICAL_ARCHITECTURE.md`, `docs/leverage_decision.html` |
| Research track (archived) | `Archive/blaque_baux/…` · `signal_engine.py`, `optimizer/risk_engine.py`; `Archive/crypto-quant-mvp-v2/monte_carlo_engine.py` |

---

## 11. References

1. Markowitz, H. (1952). *Portfolio Selection.* J. Finance.
2. J.P. Morgan/Reuters (1996). *RiskMetrics — Technical Document* (EWMA covariance, VaR).
3. Ledoit, O., & Wolf, M. (2003). *Honey, I Shrunk the Sample Covariance Matrix.*
4. Maillard, S., Roncalli, T., & Teïletche, J. (2010). *The Properties of Equally Weighted Risk Contribution Portfolios* (ERC).
5. Choueifaty, Y., & Coignard, Y. (2008). *Toward Maximum Diversification.*
6. López de Prado, M. (2016). *Building Diversified Portfolios that Outperform Out of Sample* (HRP); and *Advances in Financial Machine Learning* (2018) — purged/combinatorial CV.
7. Moskowitz, T., Ooi, Y. H., & Pedersen, L. H. (2012). *Time Series Momentum.*
8. Jegadeesh, N., & Titman (1993); Jegadeesh (1990) — momentum and short-horizon reversal.
9. Cornish, E., & Fisher, R. (1938). *Moments and Cumulants…* (Cornish–Fisher VaR expansion).
10. Sortino, F., & Price, L. (1994). *Performance Measurement in a Downside Risk Framework.*
11. Rockafellar, R. T., & Uryasev, S. (2000). *Optimization of Conditional Value-at-Risk.*

---

## 12. Disclaimer

This document and the accompanying code are provided for **educational and research purposes**. They do not constitute investment advice, a solicitation, or an offer. Performance figures are historical simulations or paper-trading results, net of modeled transaction costs and (where noted) financing; they are **not indicative of future results**. Systematic trading carries substantial risk, including loss of principal. Anyone deploying real capital does so at their own risk and should conduct independent validation.
