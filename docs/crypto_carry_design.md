# Crypto Funding-Rate Carry — Venue Integration & Executor Design

**Status:** design scope (no keys, no venue code yet). Prototype validated in
[`scripts/research/crypto_funding_carry.py`](../scripts/research/crypto_funding_carry.py):
BTC+ETH cash-and-carry **+11.9%/yr net**, **corr +0.01 to SPY**, positive every year 2020–2026 — the one
genuinely orthogonal, market-neutral premium the new-mechanism search found.

**The crux decision this doc frames:** the premium is real and uncorrelated, but it introduces a **new risk
category** the equity/ETF book has never carried — venue/counterparty, cross-margin liquidation, basis
blowout, stablecoin depeg, funding-regime death. The smooth funding series prints Sharpe ~9–10; that number
is a *trap*. This sleeve must be **sized by the tail, not the vol**, and it is only worth adding if that new
tail is governed as hard as the rest of the platform. This design is about making that tail governable.

---

## 1. What cash-and-carry needs that the current architecture lacks

The spine/keeper/tactical stack is **long-biased or market-neutral *within one spot venue* (Alpaca), price is
the only P&L, and there is no leverage/liquidation.** Cash-and-carry breaks four of those assumptions:

| Need | Current | Gap to close |
|---|---|---|
| Two legs (long **spot** + short **perp**) held delta-neutral | single spot instrument | a paired-position executor |
| **Funding** as the P&L source | price only | a funding data feed + accrual accounting |
| **Short a perpetual** with margin/leverage | long/spot only | perp order semantics (position side, reduce-only, leverage) |
| **Liquidation / margin health** | none (unlevered) | a cross-margin health monitor + de-lever circuit breaker |
| **Venue/counterparty tail** | Alpaca-only, regulated | a hard per-venue capital cap + stablecoin/basis monitors |

Everything else — idempotency, the per-pool budget gate, lineage, reconcile, the kill switch — **is reused
unchanged**: the executor still routes every leg through the venue-agnostic `ExecutionController`. We are
adding an *adapter* and a *risk layer*, not forking the engine.

---

## 2. Venue choice (a user decision — flagged, not made)

The carry needs one venue offering **spot + perp on the same cross-margined account** (so a spot rally's gain
offsets the short perp's loss *inside one margin account*, with no liquidation-transfer gap).

| Venue | Reachable here | Spot+perp cross-margin | Caveat |
|---|---|---|---|
| **OKX** | ✅ (public API responded) | ✅ (unified account) | **US-access/KYC restrictions** — likely needs a non-US entity; *your call* |
| Binance | ❌ 451 geo-blocked | ✅ | US-blocked from here |
| Bybit | ❌ 403 | ✅ | blocked from here |
| dYdX v4 | ✅ (on-chain) | perp-only (no spot leg) | would need spot elsewhere → breaks single-account cross-margin |
| CME (regulated) | via futures broker | ❌ (futures ≠ spot venue) | regulated/clean, but dated futures + separate spot custody |

**Recommendation:** OKX for a *prototype/testnet* because it's reachable and has a unified cross-margin
account. **The live venue + legal entity is explicitly your decision** — the venue/counterparty cap below is
what makes any single choice survivable. Data (funding history) is public and needs no account on any of them.

---

## 3. The `PerpVenue` adapter (implements `ExecutionVenue`)

A thin adapter, exactly like `AlpacaVenue`, satisfying the existing contract in
[`venue_interface.jl`](../src/module_7_execution/venue_interface.jl):

- `connect!` / `is_connected` / `disconnect!` — REST/WebSocket session (key/secret/**passphrase** for OKX).
- `submit!(v, ::VenueOrder)::OrderAck` — translate the canonical order. **New perp params** carried via the
  symbol convention + order type: spot `BTC/USDC`, perp `BTC-USDC-SWAP`; perp shorts use `reduce_only` on
  unwind and an explicit position side. `:accepted/:rejected/:uncertain` maps to OKX order states (the
  `:uncertain` idempotency-lock path is *critical* on a leveraged venue).
- `positions(v, account)` — returns **both** the spot balance and the signed perp position (negative = short).
- `drain_fills` — confirmed fills for lineage + expected-position tracking.
- `account_info` — equity, **margin ratio / maintenance margin**, buying power (the margin fields are new and
  feed the tail governance below).
- `funding_at(coins)` — a data provider mirroring `CryptoPanelProvider`: reads the venue's **public** funding
  endpoint (no keys) → current + trailing funding per coin, cached to `~/.config/blaquebaux/funding_cache.json`
  (like the PEAD earnings calendar). Refreshed each run; historical dumps seed the backtest.

All order placement still flows **through `ExecutionController`** so idempotency, the pool budget gate, audit
lineage, and reconcile apply to each crypto leg unchanged.

---

## 4. The cash-and-carry executor (`carry_book`)

Not a `rebalance-to-target`; a **paired-position maintainer**:

1. **Target:** for each deployed coin, long spot notional `N` and short perp notional `N`, `N = ALLOC ×
   tactical_capital` (small — see tail sizing). A matched pair is **delta-neutral by construction** and *stays*
   neutral as price moves (both legs scale 1:1), so it needs **no price-chasing rebalance** — only funding
   accrues and margin must be maintained.
2. **Funding gate (regime):** deploy a coin only when trailing-7d funding > threshold; **unwind** when funding
   turns negative for N consecutive periods (the premium is dead — don't hold a losing carry). This is the
   tactical "regime gate," crypto-native.
3. **Establish / unwind:** two governed orders per coin (spot leg + perp leg), each an idempotent `VenueOrder`
   through the controller; unwind reverses both, `reduce_only` on the perp.
4. **State:** `~/.config/blaquebaux/carry_state.jls` — current pairs, deploy-since, funding-gate state, last
   margin snapshot (mirrors the tactical time-box state file).

Dry-run computes the target pairs + gate + tail checks and **logs**, placing nothing (like every other driver).

---

## 5. Tail governance — the real cost of admission (NEW risk layer)

The equity book never needed this. These are **hard, pre-trade + continuous** checks, on top of `SafetyLimits`:

- **Per-venue capital cap** (the FTX lesson): a hard max — e.g. ≤ **3–5% of total AUM** on the perp venue,
  *regardless* of how good the carry looks. Counterparty failure ⇒ you lose what's on the venue; cap that loss.
- **Cross-margin requirement:** spot + perp **must** be one cross-margined account, else reject the venue. A
  spot rally must offset the perp short *inside* the margin account.
- **Margin-health circuit breaker:** monitor maintenance-margin buffer each run; if it falls below a threshold
  (e.g. equity/maintenance < 3×), **de-lever/unwind before the venue liquidates**.
- **Basis circuit breaker:** if perp − spot deviates beyond a band, halt new deployment (basis-blowout mark-to-
  market risk).
- **Stablecoin monitor:** if the collateral (USDC) depegs beyond a band, halt + unwind.
- **Funding-regime kill:** negative funding for N periods ⇒ unwind (see gate).
- **Kill switch:** the existing `~/.config/blaquebaux/HALT` unwinds **both legs** and stands down.
- **Tail sizing (the governing principle):** size the allocation assuming a **−50% to −100%** loss on the
  venue exposure is possible; do **not** size by the 1%-vol carry Sharpe. At a 3–5% AUM cap, even a total
  venue loss is a ~3–5% portfolio hit — survivable, uncorrelated, and small relative to a +12%/yr carry on
  that slice. This is the whole reason it can be added at all.

---

## 6. Phased rollout (each phase gated on the previous)

- **Phase 0 — research (DONE):** premium confirmed real, orthogonal, tail-shaped.
- **Phase 1 — governed dry-run driver (DONE, no keys):** [`scripts/carry_book_live.jl`](../scripts/carry_book_live.jl)
  (wrapper [`run_carry_book_daily.sh`](../scripts/run_carry_book_daily.sh), launchd
  [`com.blaquebaux.carry_book.plist`](../scripts/launchd/com.blaquebaux.carry_book.plist)) computes the
  delta-neutral spot/perp pairs against **live public OKX funding data**, enforces the funding gate + **every
  tail circuit breaker** (per-venue cap, basis, stablecoin, kill switch — all verified to fire), runs the
  safety-gate preflight, and **logs — placing nothing**. Paper/live are blocked in the driver until the
  PerpVenue adapter exists. Margin-health is live-only (no account in dry-run).
- **Phase 2 — testnet:** OKX demo/paper credentials; real order path, fake money; verify submit/reconcile/unwind
  + the margin & kill circuit breakers actually fire.
- **Phase 3 — tiny real allocation:** dedicated sub-account, funded at the venue cap only; tail governance live;
  ramp slowly, watch the funding regime.

---

## 7. Open decisions for you

1. **Do we add crypto-venue tail risk to a platform built on risk-control at all?** The +12%/yr is genuinely
   uncorrelated, but it's a *new kind* of tail. The tactical framing (3–5% cap, tail-sized, governed) is the
   mitigant; it is not elimination. This is a philosophy call, not a code call.
2. **Venue + legal entity** (OKX reachable but US-restricted; regulated CME route is cleaner but breaks
   single-account cross-margin).
3. **AUM cap** (recommend 3–5%) and **collateral** (recommend USDC over USDT).

If Phase 1 is a go, it's buildable with **no keys** — a paper/dry-run driver on public funding data — so you can
watch it run and stress the tail checks before any venue or capital commitment.
