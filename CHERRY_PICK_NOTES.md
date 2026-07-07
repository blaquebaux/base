# BlaqueBaux — Cherry-Pick Implementation Notes

## Source Assessment

| Source | Score | Notes |
|--------|-------|-------|
| **Kimi** (base) | 59/70 | Best by a large margin. Full implementations, 650+ tests, integration + stress tests. |
| Deepseek | 43/70 | Second best. Good ARMA depth, RTF format. |
| ChatGPT | 38/70 | Solid but overlaps Deepseek. Better M6 position sizing math. |
| LeChat | 36/70 | Largest RTF (120KB), creative deviations from spec. |
| Perplexity | 31/70 | Spec-faithful but shallow. |
| Meta (simple) | 19/70 | API stubs only. GARCH hardcoded. Won't compile. |
| ZAi | 24/70 | Most cursory. |

**Decision:** Kimi used as base. All other implementations reviewed for cherry-pick items.

---

## Cherry-Pick Decisions

### Kept from Kimi (all modules)
- Full ARMA+GARCH implementation with proper BFGS optimization (Module 4)
- Particle filter E-step with systematic resampling (Module 5)
- Escobar-West concentration parameter update (Module 5)
- 4-state circuit breaker state machine (Module 7)
- SQLite version registry with serialize/deserialize (Module 8)
- `test_stress.jl` — GFC-level volatility, memory efficiency, rapid switching (unique to Kimi)
- `test_integration.jl` — Full daily pipeline simulation (unique to Kimi)

### Not cherry-picked from other sources
- **Deepseek M4**: Warm-start from rolling std — Kimi's approach is equivalent
- **ChatGPT M6**: Position sizing formula — Kimi's parallel pool implementation is spec-faithful
- **Meta test naming**: Minor convention difference, not worth re-formatting 28 files

---

## Fixes Applied to Kimi Base

### CRITICAL (would prevent compilation or produce wrong results)

**Fix 1 — Module 4: `ARMASpec(0,0)` assertion removed**
- *Problem:* `@assert p + q > 0` rejected `ARMASpec(0,0)`, which is the correct spec for Floating regime atoms (constant-mean, no lag structure, using realized vol)
- *Fix:* Removed assertion; added comment explaining (0,0) is valid for Floating regime

**Fix 2 — Module 5: `_regime_likelihood` atom type inconsistency**
- *Problem:* `_random_regime_model()` returns a `Dict{Symbol,Any}` but `_regime_likelihood` called `get(atom, :σ², 0.01)` which fails on `RegimeModel` structs (post-EM atoms)
- *Fix:* `_regime_likelihood` now checks `atom isa Dict` and handles both phases — Dict during initialization, RegimeModel struct post-EM. This preserves the duck-typing approach while making the boundary explicit.

### SIGNIFICANT (spec deviation)

**Fix 3 — Module 7: VVIX threshold changed from absolute to ratio**
- *Problem:* `vvix > 120.0` (absolute level) deviates from spec Section 7.4 which specifies `VVIX > 2×VIX` (ratio). An absolute level of 120 is regime-blind: VVIX=120 with VIX=100 is very different from VVIX=120 with VIX=20.
- *Fix:* `vvix_ratio = vvix / vix; if vvix_ratio > 2.0` — ratio-based trigger as specified

**Fix 4 — Module 7: Non-spec `VIX > 40` trigger removed**
- *Problem:* Kimi added an extra immediate liquidation trigger for `VIX > 40` not present in spec Section 7.4. This would cause emergency liquidation during normal elevated-vol periods (VIX regularly exceeds 40 during market stress that doesn't warrant full liquidation).
- *Fix:* Commented out with explanation. Re-enable if desired with explicit rationale.

### NOTABLE (numerical stability)

**Fix 5 — Module 4: GARCH σ² floor raised**
- *Problem:* Floor at `1e-10` is below machine precision territory for single-precision and creates near-zero conditional variances
- *Fix:* Raised to `1e-8` (≈ 0.01% daily volatility floor)

**Fix 6 — Module 5: EM convergence divide-by-zero guard**
- *Problem:* `abs(loglik_history[end-1])` could be `0.0` on first iteration if all likelihoods collapse, causing `Inf` relative change and immediate false non-convergence
- *Fix:* `denom = abs(prev_ll) < 1e-300 ? 1.0 : abs(prev_ll)`

---

## Known Remaining Limitations

These are NOT bugs — they are documented simplifications that need production work:

1. **Module 5 `_weighted_regime_update`**: Updates only `μ` and `σ²` per regime, not full ARMA coefficients. The M-step in production should call `estimate_armagarch` with observation weights. Documented in the function docstring.

2. **Module 5 `_regime_likelihood`**: Uses regime mean and vol_scale for the likelihood. Full production implementation should use the ARMA-GARCH conditional likelihood from Module 4. This is computationally expensive at 2,000 particles × 252 days — acceptable approximation for initialization.

3. **Module 7 `send_order`**: Simulated IBKR execution. Replace with actual IBKR TWS API calls via `InteractiveBrokers.jl` or the REST API.

4. **Module 8 model serialization**: `_serialize_model` / `_deserialize_model` use a placeholder. Replace with `JLD2.jl` or `Serialization.jl` for production.

5. **Module 1 `fetch_and_normalize`**: HTTP/API calls are scaffolded. Wire to actual Cboe WebSocket, FRED API, IBKR API, and Deribit WebSocket per Section 4.6 of the spec.

---

## How to Run

```bash
# Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run all tests
julia --project=. test/runtests.jl

# Daily operation (after DPM is initialized)
julia --project=. scripts/run_daily_recursive.jl

# Weekly EM re-estimation (Saturday job)
julia --project=. scripts/run_em_weekly.jl

# Pre-deployment validation gates
julia --project=. scripts/backtest_validation.jl
```

## Julia Version
Requires Julia 1.9+. Tested against 1.9 constraint in Project.toml.

---

## Deepseek v2 Integration (May 2026)

Deepseek v2 directly addressed all 6 remaining production gaps from the cherry-pick notes.
The following files were added to the repository:

| New File | Gap Addressed | Status |
|----------|--------------|--------|
| `src/module_5_dpm/mstep_weighted.jl` | Weighted ARMA M-step | Integrated with 3 fixes |
| `src/module_5_dpm/regime_likelihood_dispatch.jl` | Atom type ambiguity | Integrated with 1 fix |
| `src/module_1_data/data_feeds_production.jl` | Cboe/FRED/Deribit/TGA feeds | Integrated with endpoint corrections |
| `src/module_7_execution/ibkr_connection.jl` | IBKR API scaffold | Integrated with thread-safety + correct package ref |
| `src/module_8_governance/model_serialization.jl` | JLD2 serialization | Integrated with SQLite API corrections |

Gap 3 (VVIX threshold) was already resolved in the initial cherry-pick.

### Fixes applied to Deepseek v2 code

**mstep_weighted.jl:**
- `_get_baseline_volatility` now iterates `current_atoms` only (not partially-initialized `updated_atoms`)
- `_sigmoid_safe` / `_logit_safe` helpers added with clamping to prevent numerical overflow
- GARCH stationarity constraint enforced inside optimizer via `β₁ = sigmoid * (1 - α₁ - 1e-6)`
- Dict atom M-step also updates `:σ` key for consistency with Dict likelihood

**regime_likelihood_dispatch.jl:**
- Fixed `:σ` → `:σ²` key in Dict likelihood (Deepseek used std; `_random_regime_model` stores variance)
- `_full_conditional_likelihood`: `lagged_returns` properly passed as parameter (was undefined in scope)
- Added `ν = max(ν, 2.01)` guard in t-distribution to ensure finite variance

**data_feeds_production.jl:**
- Cboe endpoint corrected to `cdn.cboe.com/api/global/us_indices/daily_prices/` (daily CSV, no auth)
- TGA URL corrected to `api.fiscaldata.treasury.gov/services/api/v1/` with proper filter syntax
- GSW vs DGS distinction noted: FRED DGS series = par yields, not zero-coupon. GSW requires Fed download.
- OIS-SOFR: OIS not free via FRED — placeholder 5bps with production note

**ibkr_connection.jl:**
- Removed fake IBAPI.jl UUID — replaced with reference to `Jib.jl` (real Julia TWS client)
- Added `ReentrantLock` for thread-safe concurrent order management
- Added reconnect loop with configurable attempts and delay
- Port defaults to 7497 (paper trading); env var `IBKR_PORT` overrides

**model_serialization.jl:**
- `SQLite.execute!` → `DBInterface.execute` (SQLite.jl >= 1.0 API change)
- `SQLite.query` → `collect(DBInterface.execute(...))` 
- `StickBreaking` serialized field-by-field — no new struct fields required
- `_init_version_registry` extracted to avoid code duplication
