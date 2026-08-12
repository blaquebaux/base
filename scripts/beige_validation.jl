#!/usr/bin/env julia
# ============================================================================
# beige_validation.jl — VALIDATE-BEFORE-KEEPER gate for the BEIGE sleeve candidate.
#
# BEIGE (research: scripts/research/beige_annual_hedge.py): airlines are SHORT their jet-fuel input, so
# rising fuel SQUEEZES their margins at a lag. The sleeve trades that mirror: when fuel (USO) 126-day
# momentum > 0 go SHORT the airline basket (BEIGE_CONTINUOUS=1 also flips LONG when fuel falls), then hedge
# out SPY beta so the book is market-neutral.
#
# GATE RESULT — BEIGE DOES NOT CLEAR THE :neutral BAR on full history. This gate is why we validate before
# promoting: the research's +0.50 in-sample was flattered by (a) in-sample fit and (b) a robustness check
# that DROPPED the 2020/2022 episodes, and my first walk-forward run (+0.77) used the IEX feed, whose common
# history only starts ~Sept-2020 — i.e. AFTER the COVID crash. On the full 2016-2026 SIP window:
#   * continuous flip:   OOS Sharpe +0.00, CAGR -8%, maxDD -94%, 33% folds+ — FAIL. The "flip LONG airlines
#     when oil falls" limb is a disaster: oil falling is often a demand-collapse recession (2020) that
#     craters airlines, so the sleeve goes long straight into the crash.
#   * short-only-on-rising (default; never long airlines): OOS Sharpe +0.21, CAGR +2%, maxDD -57%, beta
#     -0.14 (market-neutral PASS) but 50% folds+ — FAIL on Sharpe (<0.30) and fold-consistency (<60%).
# CORRECTION (scripts/research/beige_regime_epochs.py): the failure is NOT "the pre-COVID era" — 2017-2019
# short-only was POSITIVE (+0.61). The full-sample drag is TWO specific years, 2016 (-2.47, an oil-bottom
# whipsaw) and 2020 (COVID); ex-2016 short-only is +0.62 over 2017-2026 and +1.12 in 2023-2026. Both bad
# years share ONE structural failure — airlines recovering off a crash INDEPENDENT of fuel, so the
# fuel-momentum signal fights the dominant driver (a recurring vulnerability, e.g. any demand-shock recession).
# So BEIGE fails the KEEPER/spine :neutral bar (which wants full-sample robustness) but, SHORT-ONLY (the -94%
# came entirely from the flip's LONG-airline limb in 2020), is a defensible REGIME-CONDITIONAL PAPER sleeve:
# positive in 4 of 5 epochs, judged against the family's paper-sleeve bar, shipped with the crash-recovery
# whipsaw as a documented kill-condition. Run BB_FEED=sip BB_ASOF_LAG=7 for the full window; the family-default
# iex feed only sees ~2020+ (post-COVID) and flatters the result (+0.77).
#
# Fully causal walk-forward: reuses beige_target(panel,cap) each rebalance, holds net weights, accrues P&L
# NET OF COSTS, reports OOS Sharpe/CAGR/maxDD vs SPY + purged 6-fold check + the :neutral bar (Sharpe>=0.30,
# |beta|<=0.25, >=60% folds+). Runs on the base engine (this repo IS the engine). Read-only bars; keys from env.
#   Run:  BB_FEED=sip BB_ASOF_LAG=7 julia --project=. scripts/beige_validation.jl
# ============================================================================
using Dates, Printf, Statistics, LinearAlgebra
const SRC = normpath(joinpath(@__DIR__, "..", "src"))
include(joinpath(SRC, "module_1_data", "equity_panel.jl"))
include(joinpath(SRC, "module_1_data", "alpaca_panel.jl"))
include(joinpath(SRC, "module_11_cv", "purged_kfold.jl"))
using .EquityPanel, .AlpacaPanel, .PurgedKFold

const AIRLINES = ["DAL", "UAL", "AAL", "LUV", "ALK", "JBLU"]   # the airline basket (short the input-cost squeeze)
const FUEL     = "USO"                                          # jet-fuel proxy (crude); signal only, never held
const UNIVERSE = vcat(AIRLINES, FUEL, "SPY")
const GROSS    = 1.0                                            # airline book scaled to ~1x gross
const FUEL_LB  = 126                                           # ~ annual hedging horizon (the lag that matters)
const CONT     = get(ENV, "BEIGE_CONTINUOUS", "0") in ("1", "true", "yes")  # default short-only (the flip's long-airline limb blows up in 2020); =1 to flip

"Netted per-symbol BEIGE weights + targets. Short airlines when fuel is trending up (flip to long when CONT
 and fuel trending down); SPY leg strips the book's rolling market beta so the sleeve is market-neutral."
function beige_target(panel, cap)
    syms = panel.symbols; R = panel.returns; T = size(R, 1); N = length(AIRLINES)
    col(s) = R[:, findfirst(==(s), syms)]; px(s) = panel.prices[findfirst(==(s), syms)]
    A = hcat([col(s) for s in AIRLINES]...); spy = col("SPY")
    fl = cumprod(1 .+ col(FUEL))
    sgn(tt) = tt > FUEL_LB && (fl[tt] / fl[tt-FUEL_LB] - 1) > 0 ? -1.0 : (CONT ? 1.0 : 0.0)  # short if fuel rising
    s0 = sgn(T)
    w = fill(s0 / N, N)                                         # equal-weight the airline basket, signed
    # causal daily book series (signal recomputed monthly) -> rolling 60d beta for the hedge
    cut = fill(NaN, T); sg = sgn(FUEL_LB + 1)
    for tt in (FUEL_LB+1):(T-1)
        (tt - (FUEL_LB + 1)) % 21 == 0 && (sg = sgn(tt))
        cut[tt+1] = sg * mean(A[tt+1, :])
    end
    y = cut[max(1, T-59):T]; x = spy[max(1, T-59):T]; m = .!isnan.(y)
    beta = (sum(m) > 20 && var(x[m]) > 0) ? cov(y[m], x[m]) / var(x[m]) : 0.0
    beta = clamp(beta, -3.0, 3.0)                              # sane hedge (no real book runs a 100x SPY leg)
    gw = sum(abs, w); s = gw > 1e-6 ? GROSS / gw : 0.0        # flat book -> truly flat (no runaway hedge leg)
    net = Dict{String,Float64}(); price = Dict{String,Float64}()
    for (i, sym) in enumerate(AIRLINES); net[sym] = s * w[i]; price[sym] = px(sym); end
    net["SPY"] = get(net, "SPY", 0.0) + s * (-beta); price["SPY"] = px("SPY")   # market-neutral hedge
    targets = Dict(sym => round(Float64, net[sym] * cap / price[sym]) for sym in keys(net))
    (targets = targets, prices = price, net = net, beta = beta, gross = sum(abs, values(net)))
end

# ---- walk-forward OOS harness (mirrors the flavor repos' _sleeve_validation.jl) ----
const FEED = get(ENV, "BB_FEED", "iex")   # family default iex (~2020+); BB_FEED=sip for full 2016+ history
const ASOF = Dates.today() - Day(parse(Int, get(ENV, "BB_ASOF_LAG", "0")))  # lag past free-tier recent-SIP block
function fetch_panel(fetchU, lb = 2600)
    try
        return panel_at(AlpacaPanelProvider(fetchU; lookback = lb, feed = FEED), ASOF)
    catch e
        m = match(r"only (\d+) common", sprint(showerror, e))
        m === nothing && rethrow(e)
        n = parse(Int, m.captures[1]) - 20
        (n < 80 || n >= lb) && rethrow(e)
        return fetch_panel(fetchU, n)
    end
end
_sh(r; ann = 252) = (x = r[isfinite.(r)]; s = std(x); s > 0 ? mean(x) / s * sqrt(ann) : NaN)
_dd(r) = (lvl = cumprod(1 .+ r); minimum(lvl ./ accumulate(max, lvl) .- 1))
_cagr(r) = (lvl = cumprod(1 .+ r); lvl[end] <= 0 ? -1.0 : lvl[end]^(252 / length(r)) - 1)  # guard wipeout

function validate(; label, warmup = 210, reb = 21,
                  cost_bps = parse(Float64, get(ENV, "BB_COST_BPS", "5")), benchmark = "SPY")
    panel = fetch_panel(unique(vcat(UNIVERSE, benchmark)))
    R = panel.returns; syms = panel.symbols; T = size(R, 1)
    sidx = Dict(s => i for (i, s) in enumerate(syms)); dummy = ones(length(syms)); cost = cost_bps / 1e4
    subpanel(t) = (returns = R[1:t, :], symbols = syms, prices = dummy)
    bookret(w, day) = sum(get(w, s, 0.0) * R[day, sidx[s]] for s in keys(w); init = 0.0)
    oos = Float64[]; oosidx = Int[]; wprev = Dict{String,Float64}(); inmkt = 0; nreb = 0
    for t0 in warmup:reb:(T-1)
        w = beige_target(subpanel(t0), 1.0).net; nreb += 1
        any(s -> s in AIRLINES && abs(get(w, s, 0.0)) > 1e-6, keys(w)) && (inmkt += 1)
        turn = sum(abs(get(w, s, 0.0) - get(wprev, s, 0.0)) for s in union(keys(w), keys(wprev)); init = 0.0)
        for day in (t0+1):min(t0+reb, T)
            r = bookret(w, day); day == t0 + 1 && (r -= turn * cost)
            push!(oos, r); push!(oosidx, day)
        end
        wprev = w
    end
    spy = [R[i, sidx[benchmark]] for i in oosidx]
    beta = var(spy) > 0 ? cov(oos, spy) / var(spy) : 0.0; corr = cor(oos, spy)
    folds = purged_kfold_split(length(oos), PurgedKFoldConfig(; n_splits = 6, embargo_bars = reb); returns = oos)
    fsh = [_sh(oos[f.test_idx]) for f in folds if length(f.test_idx) > 30 && std(oos[f.test_idx]) > 0]
    osh, ssh = _sh(oos), _sh(spy); posfold = mean(fsh .> 0)

    println("="^76, "\n$label — walk-forward OOS validation (net $(round(Int,cost*1e4)) bps/side, kind=neutral)\n", "="^76)
    @printf("\n  mode %s   OOS days %d   rebalances %d (in-market %d = %.0f%%)   warmup %d reb %d\n",
            CONT ? "continuous flip (long/short)" : "short-only-on-rising", length(oos), nreb, inmkt, 100inmkt/nreb, warmup, reb)
    @printf("  %-26s %8s %8s %8s\n", "book", "Sharpe", "CAGR", "maxDD")
    @printf("  %-26s %+8.2f %7.1f%% %7.0f%%\n", "sleeve OOS (net, causal)", osh, _cagr(oos)*100, _dd(oos)*100)
    @printf("  %-26s %+8.2f %7.1f%% %7.0f%%\n", "SPY (same window)", ssh, _cagr(spy)*100, _dd(spy)*100)
    @printf("  beta-SPY %+.2f  corr-SPY %+.2f   purged 6-fold OOS Sharpe: mean %+.2f min %+.2f (%d folds)\n",
            beta, corr, mean(fsh), minimum(fsh), length(fsh))
    checks = [("OOS net Sharpe >= 0.30",          osh >= 0.30, @sprintf("%.2f", osh)),
              ("market-neutral (|beta| <= 0.25)", abs(beta) <= 0.25, @sprintf("%.2f", beta)),
              ("positive in >= 60% of folds",     posfold >= 0.60, @sprintf("%.0f%%", posfold*100))]
    println("\n  THE BAR (neutral):")
    for (n, ok, v) in checks; @printf("    [%s] %-40s %s\n", ok ? "PASS" : "FAIL", n, v); end
    allpass = all(c -> c[2], checks)
    println("\n  VERDICT: ", allpass ? "PASS — clears the :neutral bar; graduate to a paper driver." :
                                       "MIXED — does not fully clear the bar; keep as research-only candidate.")
    return (; label, osh, ssh, beta, corr, maxdd = _dd(oos), pass = allpass)
end

if abspath(PROGRAM_FILE) == @__FILE__
    (get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == "") &&
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY (read-only bars).")
    validate(; label = "BEIGE (airlines short fuel, market-neutral)")
end
