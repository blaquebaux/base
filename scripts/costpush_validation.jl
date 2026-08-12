#!/usr/bin/env julia
# ============================================================================
# costpush_validation.jl — VALIDATE-BEFORE-KEEPER gate for the COST-PUSH LAG sleeve candidate.
#
# THESIS (user, ex-Ingredion): supplier pricing power LEADS a customer margin squeeze. When the ingredient
# suppliers (INGR/ADM) get strong — they can't sell sweetener/starch/oil at last year's price — the food
# manufacturers' (KO/PEP/MDLZ/GIS/KHC) input costs rise and their stock takes the hit LATER, as contracts
# reprice and earnings reveal it. Confirmed lead-lag: supplier 63d strength -> customer forward return is
# NEGATIVE and GROWS with horizon (-0.04 @5d -> -0.17 @126d). The sleeve trades it: SHORT the customer basket
# when the supplier basket's 63d momentum > 0, then hedge out SPY beta so the book is market-neutral.
# GATE RESULT — MECHANISM REAL, but a NEAR-MISS (does NOT clear the :neutral bar). A gross, daily-repositioned
# research scratch showed +0.37, but that DID NOT charge transaction costs and repositioned every day. The
# honest net-of-cost, monthly-held, causal walk-forward here gives:
#   * full 2016-2026 (SIP): OOS Sharpe +0.16, beta -0.07 (neutral PASS), 50% folds+ — FAIL on Sharpe & folds.
#   * recent (IEX ~2020+):  OOS Sharpe +0.11, beta -0.03 (PASS), 67% folds+ (PASS) — FAIL on Sharpe only.
# The lead-lag IS real (supplier 63d strength -> customer forward return -0.04@5d -> -0.17@126d, and the book is
# the cleanest market-neutral structure found: beta ~ -0.05, purged-fold mean +0.23). But the margin-squeeze
# signal is SLOW and SMALL: it doesn't move the customer stocks enough, fast enough, to beat trading friction,
# and the 2021-2022 staples-as-defensive-haven regime eats a chunk. VERDICT: near-miss, not a keeper; the
# confirmed mechanism is a useful risk/tilt input, not a standalone sleeve. No fitted params (63d, direction
# from the mechanism); refused to tune to a pass.
#
# Fully causal walk-forward: reuses costpush_target() each rebalance, holds net weights, accrues P&L NET OF
# COSTS, reports OOS Sharpe/CAGR/maxDD vs SPY + purged 6-fold + the :neutral bar (Sharpe>=0.30, |beta|<=0.25,
# >=60% folds+). Runs on the base engine (this repo IS the engine).
#   Run (full history):  BB_FEED=sip BB_ASOF_LAG=7 julia --project=. scripts/costpush_validation.jl
# ============================================================================
using Dates, Printf, Statistics, LinearAlgebra
const SRC = normpath(joinpath(@__DIR__, "..", "src"))
include(joinpath(SRC, "module_1_data", "equity_panel.jl"))
include(joinpath(SRC, "module_1_data", "alpaca_panel.jl"))
include(joinpath(SRC, "module_11_cv", "purged_kfold.jl"))
using .EquityPanel, .AlpacaPanel, .PurgedKFold

const SUPPLIERS = ["INGR", "ADM"]                              # ingredient suppliers (pricing-power signal; never held)
const CUSTOMERS = ["KO", "PEP", "MDLZ", "GIS", "KHC"]          # food manufacturers (the ones we short)
const UNIVERSE  = vcat(SUPPLIERS, CUSTOMERS, "SPY")
const GROSS     = 1.0
const SIG_LB    = 63                                          # supplier-strength lookback (~1 quarter)
const FEED = get(ENV, "BB_FEED", "iex")
const ASOF = Dates.today() - Day(parse(Int, get(ENV, "BB_ASOF_LAG", "0")))

"Netted per-symbol COST-PUSH weights. Short the customer basket equally when the supplier basket's SIG_LB
 momentum > 0 (pricing power -> coming margin squeeze); SPY leg strips the book's rolling beta (market-neutral)."
function costpush_target(panel, cap)
    syms = panel.symbols; R = panel.returns; T = size(R, 1); Nc = length(CUSTOMERS)
    col(s) = R[:, findfirst(==(s), syms)]; px(s) = panel.prices[findfirst(==(s), syms)]
    C = hcat([col(s) for s in CUSTOMERS]...); spy = col("SPY")
    sl = cumprod(1 .+ vec(sum(hcat([col(s) for s in SUPPLIERS]...), dims = 2) ./ length(SUPPLIERS)))  # supplier basket level
    sgn(tt) = tt > SIG_LB && (sl[tt] / sl[tt-SIG_LB] - 1) > 0 ? -1.0 : 0.0        # short customers when supplier strong
    w = fill(sgn(T) / Nc, Nc)
    cut = fill(NaN, T); sg = sgn(SIG_LB + 1)                                      # causal daily book -> rolling 60d beta
    for tt in (SIG_LB+1):(T-1)
        (tt - (SIG_LB + 1)) % 21 == 0 && (sg = sgn(tt))
        cut[tt+1] = sg * mean(C[tt+1, :])
    end
    y = cut[max(1, T-59):T]; x = spy[max(1, T-59):T]; m = .!isnan.(y)
    beta = (sum(m) > 20 && var(x[m]) > 0) ? cov(y[m], x[m]) / var(x[m]) : 0.0
    beta = clamp(beta, -3.0, 3.0)
    gw = sum(abs, w); s = gw > 1e-6 ? GROSS / gw : 0.0
    net = Dict{String,Float64}(); price = Dict{String,Float64}()
    for (i, sym) in enumerate(CUSTOMERS); net[sym] = s * w[i]; price[sym] = px(sym); end
    net["SPY"] = get(net, "SPY", 0.0) + s * (-beta); price["SPY"] = px("SPY")
    targets = Dict(sym => round(Float64, net[sym] * cap / price[sym]) for sym in keys(net))
    (targets = targets, prices = price, net = net, beta = beta, gross = sum(abs, values(net)))
end

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
_cagr(r) = (lvl = cumprod(1 .+ r); lvl[end] <= 0 ? -1.0 : lvl[end]^(252 / length(r)) - 1)

function validate(; label, warmup = 150, reb = 21, cost_bps = parse(Float64, get(ENV, "BB_COST_BPS", "5")), benchmark = "SPY")
    panel = fetch_panel(unique(vcat(UNIVERSE, benchmark)))
    R = panel.returns; syms = panel.symbols; T = size(R, 1)
    sidx = Dict(s => i for (i, s) in enumerate(syms)); dummy = ones(length(syms)); cost = cost_bps / 1e4
    subpanel(t) = (returns = R[1:t, :], symbols = syms, prices = dummy)
    bookret(w, day) = sum(get(w, s, 0.0) * R[day, sidx[s]] for s in keys(w); init = 0.0)
    oos = Float64[]; oosidx = Int[]; wprev = Dict{String,Float64}(); inmkt = 0; nreb = 0
    for t0 in warmup:reb:(T-1)
        w = costpush_target(subpanel(t0), 1.0).net; nreb += 1
        any(s -> s in CUSTOMERS && abs(get(w, s, 0.0)) > 1e-6, keys(w)) && (inmkt += 1)
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
    @printf("\n  OOS days %d   rebalances %d (in-market %d = %.0f%%)   warmup %d reb %d   feed=%s\n",
            length(oos), nreb, inmkt, 100inmkt/nreb, warmup, reb, FEED)
    @printf("  %-26s %8s %8s %8s\n", "book", "Sharpe", "CAGR", "maxDD")
    @printf("  %-26s %+8.2f %7.1f%% %7.0f%%\n", "sleeve OOS (net, causal)", osh, _cagr(oos)*100, _dd(oos)*100)
    @printf("  %-26s %+8.2f %7.1f%% %7.0f%%\n", "SPY (same window)", ssh, _cagr(spy)*100, _dd(spy)*100)
    @printf("  beta-SPY %+.2f  corr-SPY %+.2f   purged 6-fold OOS Sharpe: mean %+.2f min %+.2f (%d folds)\n",
            beta, corr, mean(fsh), minimum(fsh), length(fsh))
    checks = [("OOS net Sharpe >= 0.30", osh >= 0.30, @sprintf("%.2f", osh)),
              ("market-neutral (|beta| <= 0.25)", abs(beta) <= 0.25, @sprintf("%.2f", beta)),
              ("positive in >= 60% of folds", posfold >= 0.60, @sprintf("%.0f%%", posfold*100))]
    println("\n  THE BAR (neutral):")
    for (n, ok, v) in checks; @printf("    [%s] %-40s %s\n", ok ? "PASS" : "FAIL", n, v); end
    allpass = all(c -> c[2], checks)
    println("\n  VERDICT: ", allpass ? "PASS — clears the :neutral bar." : "MIXED — does not fully clear the bar.")
    return (; label, osh, ssh, beta, corr, maxdd = _dd(oos), pass = allpass)
end

if abspath(PROGRAM_FILE) == @__FILE__
    (get(ENV, "ALPACA_KEY_ID", "") == "" || get(ENV, "ALPACA_SECRET_KEY", "") == "") &&
        error("Set ALPACA_KEY_ID and ALPACA_SECRET_KEY (read-only bars).")
    validate(; label = "COST-PUSH LAG (short food-mfrs when ingredient-suppliers strong)")
end
