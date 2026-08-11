#!/usr/bin/env julia
# =============================================================================
# multi_sleeve_portfolio.jl — the diversification payoff of combining the family's
# FULL KEEPER SET through the engine's own PortfolioOpt optimizers.
#
# The Bio/Basel study showed you cannot MANUFACTURE cross-sectional alpha by
# optimizing correlated equity sectors. The real payoff of PortfolioOpt is
# DIVERSIFICATION across structurally different return drivers. So this demo drops
# the illustrative non-keeper sectors and assembles the validated asset-class spine
# plus every strategy KEEPER that can be reconstructed from daily bars, then runs
# risk-parity / min-variance / max-diversification / HRP / min-CVaR:
#
#   asset-class spine (validated diversifiers):
#     SPY equity   IEF duration   GLD gold   DBC commodities   DBA agriculture
#   keeper strategy sleeves (computed here):
#     CRACK     crude->refiner lead-lag (long CRAK when crude up)
#     BORE      beta-hedged momentum-neutral over large caps
#     TREND     vol-scaled multi-horizon trend over the spine (convexity is FREE)
#     CAMPROT   brown/blue camp rotation (hold the stronger-trending camp)
#     DDBOUNCE  drawdown-bounce (long the most-fallen quality names)
#     BLOCK     cross-asset trend over all 4 derivative blocks incl. FX (Block's tradeable residue)
#     REGIME    drawdown-regime brake on equity (§3.4 — the mechanism the LIVE spine actually uses)
#     GAMMA_REG the actual Gamma-ARMA crisis detector wired in: module 4 (ARMA+GARCH vol / tail index)
#               + module 5 (DPM.detect_crisis_regime). These modules are present and importable; they
#               are simply excluded from the production validation gate and the live path (a separate
#               research lineage that showed no edge over the simpler drawdown brake).
#     BARBELL   Taleb 90/10 BIL/VIXY (PAID convexity — negative carry, crisis insurance)
#     CURVEBALL vol-gated reversed barbell (deploy long-vol only when vol is cheap)
#
# Two honest lessons show in the weights: (1) the beta-heavy sleeves (CAMPROT, DDBOUNCE) add
# return but also correlation, so the risk allocators lean instead on the genuinely uncorrelated
# fragments (BORE, TREND, CRACK); and (2) the PAID-convexity keepers (BARBELL, CURVEBALL) are
# negative-carry insurance that a variance/Sharpe objective MISPRICES — convexity must be budgeted,
# not optimized in.
#
# RESULTS AS TESTED (2017-2026, 1831 days, gross of costs; avg pairwise corr 0.09):
#   standalone Sharpe / maxDD  (skew, COVID-capture for the convex/regime ones):
#     SPY +0.81/-34  IEF +0.10/-24  GLD +0.93/-26  DBC +0.57/-35  DBA +0.67/-21
#     CRACK +1.12/-24  BORE +0.44/-23  TREND +0.72/-16  CAMPROT +0.86/-36  DDBOUNCE +1.00/-40
#     BLOCK +0.74/-17 (4-block cross-asset trend incl. FX; corr to TREND +0.84 — mostly redundant)
#     REGIME +0.78/-20  GAMMA_REG +1.13/-24 (corr 0.88, skew +0.14, COVID -8%; flags 2% of days, catches 67% of COVID)
#     BARBELL -0.23/-32 (skew +1.87, COVID +19%)  CURVEBALL -0.79/-86 (skew +1.36)
#   optimized book        Sharpe   CAGR   vol  maxDD
#     risk-parity          +1.66    5.6%   3%   -5%
#     max-diversification  +1.64    4.8%   3%   -4%
#     min-variance         +1.62    4.5%   3%   -5%
#     min-CVaR             +1.57    4.5%   3%   -4%
#     HRP                  +1.50    5.4%   4%   -6%
#     equal-weight         +1.43   10.3%   7%  -11%
#   best SINGLE ingredient: GAMMA_REG +1.13 at -24% DD.
#   risk-parity weights: BARBELL 29% | IEF 13% | BLOCK 10% | TREND 8% | REGIME 6% | BORE 5% | ... | CAMPROT 2%
# The honest read: three lessons. (1) The RETURN-earning keepers (CRACK/BORE/TREND/CAMPROT/DDBOUNCE)
# push the diversified book past the best single sleeve; the risk budget flows to the genuinely
# uncorrelated fragments (TREND corr -0.14, BORE -0.06), not the high-Sharpe beta sleeves. Folding in
# BLOCK (Block's 4-block cross-asset trend) shows the same point from the other side: it is 0.84-
# correlated to TREND, so the optimizer just SPLITS the trend budget between the two (BLOCK 10% + TREND
# 8%) and the book lifts only +1.60 -> +1.66 — that lift is the FX/dollar block, the single new axis
# Block carries; redundant sleeves don't earn new weight. (2) The two REGIME timers behave differently:
# the live drawdown brake (REGIME +0.78) catches slow drawdowns but whipsaws (skew -1.00); the actual
# Gamma-ARMA crisis detector (GAMMA_REG, wired from module 4 tail index/vol + module 5
# detect_crisis_regime) flags only 2% of days yet catches 67% of the COVID crash, and is the BEST
# single ingredient (+1.13, COVID -8% vs SPY -33%) — it TIMES the tail cheaply rather than paying for
# it. Caveat: corr 0.88 to SPY (so risk-parity still down-weights it as beta, ~4%), and its thresholds
# catch COVID IN-SAMPLE on one path — no proof of forward skill, which is exactly why the framework is
# kept-as-research and the LIVE spine trusts the simpler drawdown brake. (3) The PAID-convexity keepers
# (BARBELL/CURVEBALL) are negative-carry insurance (CURVEBALL alone a -86% ruin) that a variance/Sharpe
# objective MISPRICES: risk-parity hands BARBELL ~29% because it is low-vol and anti-correlated.
# Convexity must be BUDGETED, not optimized in — free convexity (TREND/BLOCK) the book earns; PAID
# convexity (long-vol) is a sizing decision, and timed convexity (GAMMA_REG) is seductive in-sample.
#
# Read-only (data only). Run:  julia --project=. scripts/research/multi_sleeve_portfolio.jl
# =============================================================================
using Dates, HTTP, JSON3, Statistics, LinearAlgebra, Printf
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
using .PortfolioOptModule
# the actual Gamma-ARMA framework modules (present in-repo; excluded from the production
# validation gate and the live path, but fully importable — used here for the GAMMA_REG sleeve):
include(joinpath(REPO, "src/module_4_arma/module_4_arma.jl")); using .ARMAGARCH  # ARMA+GARCH, tail index
include(joinpath(REPO, "src/module_5_dpm/module_5_dpm.jl"));   using .DPM        # DPM crisis-regime detector

const KEY = ENV["ALPACA_KEY_ID"]; const SEC = ENV["ALPACA_SECRET_KEY"]
function fetch_closes(sym)
    r = HTTP.get("https://data.alpaca.markets/v2/stocks/bars";
        query = ["symbols"=>sym, "timeframe"=>"1Day", "start"=>"2016-01-01", "end"=>"2026-08-01",
                 "adjustment"=>"all", "feed"=>"sip", "limit"=>"10000"],
        headers = ["APCA-API-KEY-ID"=>KEY, "APCA-API-SECRET-KEY"=>SEC])
    j = JSON3.read(r.body)
    (!haskey(j, :bars) || !haskey(j.bars, Symbol(sym))) && return Dict{String,Float64}()
    Dict(String(b.t)[1:10] => Float64(b.c) for b in j.bars[Symbol(sym)])
end

BORE_BASKET = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
               "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
TREND_ASSETS = ["SPY","IEF","TLT","GLD","DBC","DBA"]
BROWN = ["XLE","XME","XOP","DBA","MOO"]          # value / real-economy camp
BLUE  = ["XLK","ICLN","TAN","DIS","NFLX"]         # growth / long-duration-equity camp
BLOCK_ASSETS = ["SPY","TLT","GLD","DBC","UUP"]    # one proxy per derivative block: equity/rates/commodities+gold/FX
RAW = unique(vcat(["SPY","IEF","GLD","DBC","DBA","TLT","USO","CRAK","VIXY","VXZ","BIL","UUP"], BORE_BASKET, BROWN, BLUE))

@info "fetching $(length(RAW)) symbols..."
D = Dict(s => fetch_closes(s) for s in RAW)
D = Dict(s => v for (s, v) in D if length(v) > 500)
dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
P(s) = [D[s][d] for d in dates]
ret(s) = (p = P(s); p[2:end] ./ p[1:end-1] .- 1)
rdates = dates[2:end]; Tr = length(rdates)
spy = ret("SPY")
retmat(syms) = hcat([ret(s) for s in syms]...)

ewma_vol(R, hl) = begin
    lam = 0.5^(1/hl); T, N = size(R); o = zeros(T, N); v = R[1, :].^2
    for t in 1:T
        v = t == 1 ? R[t, :].^2 : lam .* v .+ (1 - lam) .* R[t, :].^2
        o[t, :] = sqrt.(max.(v, 1e-16))
    end
    o
end

# ---- keeper 1: CRACK (crude->refiner lead-lag, long CRAK when crude up) ----
function compute_crack(uso, crak, Tr)
    crack = zeros(Tr)
    for t in 1:Tr-1
        crack[t+1] = (uso[t] > 0 ? 1.0 : 0.0) * crak[t+1]
    end
    crack
end
crack = compute_crack(ret("USO"), ret("CRAK"), Tr)

# ---- keeper 2: BORE (beta-hedged momentum-neutral over the basket) ----
function compute_bore(B, spy, Tr)
    N = size(B, 2); k = max(1, round(Int, N * 0.2))
    mom = fill(NaN, Tr, N)
    for t in 253:Tr
        mom[t, :] = vec(prod(1 .+ B[t-252:t-21, :], dims=1)) .- 1
    end
    cut = fill(NaN, Tr); w = zeros(N)
    for t in 253:Tr-1
        if (t - 253) % 21 == 0
            o = sortperm(mom[t, :]); w = zeros(N); w[o[end-k+1:end]] .= 1/k; w .-= 1/N
        end
        cut[t+1] = dot(w, B[t+1, :])
    end
    bore = fill(NaN, Tr)
    for t in 314:Tr
        y = cut[t-59:t]; x = spy[t-59:t]; m = .!isnan.(y)
        if sum(m) > 20 && var(x[m]) > 0
            bore[t] = cut[t] - (cov(y[m], x[m]) / var(x[m])) * spy[t]
        end
    end
    bore
end
bore = compute_bore(retmat(BORE_BASKET), spy, Tr)

# ---- keeper 3: TREND (vol-scaled multi-horizon trend over the spine) ----
function compute_trend(B, Tr)
    N = size(B, 2); sv = ewma_vol(B, 32); horizons = (63, 126, 252)
    tr = fill(NaN, Tr)
    for t in 253:Tr-1
        strength = zeros(N)
        for h in horizons
            strength .+= sign.(vec(prod(1 .+ B[t-h+1:t, :], dims=1)) .- 1)
        end
        strength ./= length(horizons)                       # multi-horizon agreement in [-1,1]
        raw = strength ./ (sv[t, :] .* sqrt(252) .+ 1e-12)   # inverse-vol scaled
        g = sum(abs.(raw)); w = g > 0 ? raw ./ g : zeros(N)  # gross = 1
        tr[t+1] = dot(w, B[t+1, :])
    end
    tr
end
trend = compute_trend(retmat(TREND_ASSETS), Tr)

# ---- keeper 4: CAMPROT (hold the stronger-trending of the brown / blue camp) ----
function compute_camprot(brown, blue, Tr)
    lb = cumprod(1 .+ brown); lu = cumprod(1 .+ blue); cr = fill(NaN, Tr)
    for t in 127:Tr-1
        cr[t+1] = (lb[t]/lb[t-126]-1) >= (lu[t]/lu[t-126]-1) ? brown[t+1] : blue[t+1]
    end
    cr
end
camprot = compute_camprot(vec(mean(retmat(BROWN), dims=2)), vec(mean(retmat(BLUE), dims=2)), Tr)

# ---- keeper 5: DDBOUNCE (long the most-fallen quality names, monthly) ----
function compute_ddbounce(U, Tr)
    N = size(U, 2); k = max(1, round(Int, N * 0.2)); lvl = cumprod(1 .+ U, dims=1)
    ddb = fill(NaN, Tr); w = zeros(N)
    for t in 61:Tr-1
        if (t - 61) % 21 == 0
            o = sortperm(vec(lvl[t, :] ./ lvl[t-60, :] .- 1)); w = zeros(N); w[o[1:k]] .= 1/k
        end
        ddb[t+1] = dot(w, U[t+1, :])
    end
    ddb
end
ddbounce = compute_ddbounce(retmat(BORE_BASKET), Tr)

# ---- keeper 6: REGIME (drawdown-regime-gated equity) — the VALIDATED, LIVE regime mechanism ----
# The regime brake the live spine actually uses (§3.4, chosen empirically over vol/corr/trend):
# hold SPY while its drawdown-from-high is shallow, step to T-bills once it breaches -8% (no lookahead).
function compute_regime(spy, bil, Tr; thr=-0.08)
    lvl = cumprod(1 .+ spy); peak = copy(lvl)
    for t in 2:Tr; peak[t] = max(peak[t-1], lvl[t]); end
    reg = fill(NaN, Tr)
    for t in 2:Tr
        reg[t] = (lvl[t-1]/peak[t-1] - 1) < thr ? bil[t] : spy[t]
    end
    reg
end
regime = compute_regime(spy, ret("BIL"), Tr)

# ---- keeper 6b: GAMMA_REG (the actual Gamma-ARMA crisis detector, wired in) ----
# Uses the real framework code: module 4 ARMAGARCH.rolling_realized_vol + tail_index_from_vol_scale,
# and module 5 DPM.detect_crisis_regime (fires on >=3 of 4 criteria). The term-structure criterion
# uses a VIXY/VXZ backwardation proxy for VIX/VXV. (We call the framework's regime CLASSIFIER on its
# own vol/tail-index primitives; we do NOT run the full particle-filter DPM EM here.) Gate: defensive
# (T-bills) the day after a crisis is flagged, else hold the market — directly comparable to REGIME.
function compute_gamma_regime(mkt, bil, vixy, vxz, Tr)
    sv = ARMAGARCH.rolling_realized_vol(mkt, 10)                 # annualized short-window vol
    base = fill(NaN, Tr)                                          # robust baseline = trailing-yr median
    for t in 252:Tr
        w = sv[t-251:t]; w = w[.!isnan.(w)]; isempty(w) || (base[t] = median(w))
    end
    crisis = falses(Tr)
    for t in 2:Tr
        (isnan(sv[t]) || isnan(base[t]) || base[t] <= 0) && continue
        vol3x = sv[t] > 3 * base[t]                                              # criterion 1
        αlt   = ARMAGARCH.tail_index_from_vol_scale(sv[t], base[t]) < 1.8        # criterion 2 (module 4)
        dstd  = std(mkt[max(1, t-251):t])                                        # criterion 3: jump intensity
        jgt   = dstd > 0 && mean(abs.(mkt[max(1, t-9):t]) .> 3 * dstd) > 0.3
        vv    = t > 5 && (prod(1 .+ vxz[t-4:t]) != 0) &&                         # criterion 4: VIXY/VXZ
                (prod(1 .+ vixy[t-4:t]) / prod(1 .+ vxz[t-4:t])) > 1.1           #   backwardation proxy
        crisis[t] = DPM.detect_crisis_regime(nothing, vol3x, αlt, jgt, vv)       # >=3 of 4 (module 5)
    end
    reg = fill(NaN, Tr)
    for t in 2:Tr; reg[t] = crisis[t-1] ? bil[t] : mkt[t]; end
    reg, crisis
end
gamma_reg, gamma_crisis = compute_gamma_regime(spy, ret("BIL"), ret("VIXY"), ret("VXZ"), Tr)

# ---- keeper 7: BARBELL (Taleb 90/10 BIL/VIXY, monthly) — PAID convexity, crisis insurance ----
function compute_barbell(bil, vixy, rdates, Tr; wsafe=0.9)
    port = zeros(Tr); sub = [wsafe, 1-wsafe]; V = 1.0
    for t in 1:Tr
        sub = sub .* (1 .+ [bil[t], vixy[t]]); nV = sum(sub); port[t] = nV/V - 1; V = nV
        if t < Tr && rdates[t+1][1:7] != rdates[t][1:7]; sub = [wsafe, 1-wsafe] .* V; end
    end
    port
end
barbell = compute_barbell(ret("BIL"), ret("VIXY"), rdates, Tr)

# ---- keeper 8: CURVEBALL (vol-gated reversed barbell) — deploy 10/90 BIL/VIXY only when vol is cheap ----
function compute_curveball(bil, vixy, spy, Tr)
    rv = fill(NaN, Tr); for t in 21:Tr; rv[t] = std(spy[t-20:t]) * sqrt(252); end
    pct = fill(0.5, Tr); for t in 272:Tr; pct[t] = mean(rv[t-251:t] .<= rv[t]); end
    port = zeros(Tr); V = 1.0
    for t in 1:Tr
        tgt = (t >= 272 && pct[t] < 0.33) ? [0.1, 0.9] : [1.0, 0.0]   # convex only when vol is cheap
        sub = tgt .* V; sub = sub .* (1 .+ [bil[t], vixy[t]]); nV = sum(sub); port[t] = nV/V - 1; V = nV
    end
    port
end
curveball = compute_curveball(ret("BIL"), ret("VIXY"), spy, Tr)

# ---- keeper 9: BLOCK (cross-asset trend over all four derivative blocks, incl. FX) ----
# Block's research: the 4 blocks (equity/FX/rates/commodities) interlock but stay diversified;
# the interlocks are priced-in and regime-unstable, so the tradeable residue is cross-asset TREND.
# This is that residue — the same trend engine as TREND, but over the 4 blocks WITH the FX/dollar
# block (UUP) that the spine-only TREND omits. Expect heavy overlap with TREND: the honest question
# is whether the FX block adds anything the book doesn't already have.
block = compute_trend(retmat(BLOCK_ASSETS), Tr)

# ---- assemble the ingredient matrix over the common valid range ----
labels = ["SPY","IEF","GLD","DBC","DBA","CRACK","BORE","TREND","CAMPROT","DDBOUNCE","BLOCK","REGIME","GAMMA_REG","BARBELL","CURVEBALL"]
cols = [ret("SPY"), ret("IEF"), ret("GLD"), ret("DBC"), ret("DBA"),
        crack, bore, trend, camprot, ddbounce, block, regime, gamma_reg, barbell, curveball]
Rp = hcat(cols...)
valid = findall(t -> all(isfinite, Rp[t, :]), 1:Tr)
Rp = Rp[valid, :]; K = size(Rp, 2)
@info "ingredient matrix" days=size(Rp,1) ingredients=K span="$(rdates[valid[1]]) .. $(rdates[valid[end]])"

skewf(x) = (m = mean(x); s = std(x); s > 0 ? mean((x .- m).^3)/s^3 : 0.0)
cvd = rdates[valid]; covid = findall(d -> "2020-02-19" <= d <= "2020-03-23", cvd)
covidret(r) = isempty(covid) ? 0.0 : prod(1 .+ r[covid]) - 1

println("\n", "="^80, "\nMULTI-SLEEVE PORTFOLIO — engine PortfolioOpt on the FULL KEEPER SET\n", "="^80)
println("\nstandalone ingredients (5 asset classes + 10 keeper sleeves; last 2 are PAID convexity):")
@printf("  %-9s %7s %5s %6s %8s %6s %8s\n", "", "Sharpe", "vol", "maxDD", "corr-SPY", "skew", "COVID")
for j in 1:K
    r = Rp[:, j]
    @printf("  %-9s %+7.2f %4.0f%% %5.0f%% %+8.2f %+6.2f %7.0f%%\n",
            labels[j], sharpe(r), ann_vol(r)*100, max_drawdown(r)*100, cor(r, Rp[:,1]), skewf(r), covidret(r)*100)
end
avgcorr = (sum(cor(Rp)) - K) / (K*(K-1))
@printf("\n  average pairwise correlation across ingredients: %.2f  (low = lots to diversify)\n", avgcorr)
# how the Gamma-ARMA crisis detector behaves (vs the live drawdown brake, both shown above)
gflag = gamma_crisis[valid]
@printf("\n  GAMMA_REG (real detector): flagged crisis on %d of %d days (%.0f%%); of the COVID-crash window it caught %.0f%%\n",
        sum(gflag), length(gflag), 100*mean(gflag), isempty(covid) ? 0.0 : 100*mean(gflag[covid]))
jb = findfirst(==("BLOCK"), labels); jt = findfirst(==("TREND"), labels)
@printf("  BLOCK vs TREND correlation: %+.2f  (high = the FX block adds little the spine-trend didn't already carry)\n",
        cor(Rp[:, jb], Rp[:, jt]))

Σ = cov(Rp)
books = [
    ("equal-weight",        fill(1/K, K)),
    ("risk-parity",         risk_parity(Σ)),
    ("min-variance",        min_variance(Σ)),
    ("max-diversification", max_diversification(Σ)),
    ("HRP",                 hrp_weights(Σ)),
    ("min-CVaR",            min_cvar(Rp)),
]
println("\noptimized books (long-only, full-invested; gross of costs):")
@printf("  %-20s %8s %7s %7s %8s\n", "optimizer", "Sharpe", "CAGR", "vol", "maxDD")
for (nm, wv) in books
    r = Rp * wv
    @printf("  %-20s %+8.2f %6.1f%% %6.0f%% %7.0f%%\n", nm, sharpe(r), ann_return(r)*100, ann_vol(r)*100, max_drawdown(r)*100)
end
best = argmax([sharpe(Rp[:, j]) for j in 1:K])
@printf("\n  best SINGLE ingredient: %s at Sharpe %+.2f, maxDD %.0f%%\n", labels[best], sharpe(Rp[:,best]), max_drawdown(Rp[:,best])*100)

println("\nrisk-parity weights (where the risk budget actually goes):")
for (l, wv) in sort(collect(zip(labels, risk_parity(Σ))), by = x -> -x[2])
    @printf("    %-9s %5.1f%%\n", l, wv*100)
end
println("\nread: three lessons. (1) The return keepers (CRACK/BORE/TREND/CAMPROT/DDBOUNCE) push the book")
println("past the best single sleeve; the risk budget flows to the uncorrelated fragments (TREND/BORE), not")
println("the high-Sharpe beta sleeves. Folding in BLOCK (Block's 4-block cross-asset trend) is 0.84-corr to")
println("TREND, so the optimizer just SPLITS the trend budget; the only new axis is the FX/dollar block")
println("(book +1.60 -> +1.66) — redundant sleeves don't earn new weight. (2) The two regime timers differ:")
println("the LIVE drawdown brake (REGIME) catches slow drawdowns but whipsaws; the Gamma-ARMA detector")
println("wired in here (GAMMA_REG, from module 4 tail-index/vol + module 5 detect_crisis_regime) flags")
println("~2% of days, catches ~67% of the")
println("COVID crash, and is the best single ingredient (+1.13) — it TIMES the tail cheaply. But it is 0.88")
println("corr to SPY (down-weighted as beta) and its thresholds fit COVID IN-SAMPLE — no forward proof,")
println("which is why it stays research and the live spine trusts the simpler brake. (3) The PAID-convexity")
println("hedges (BARBELL/CURVEBALL) are negative-carry insurance a variance objective MISPRICES (BARBELL")
println("gets ~31%). Convexity must be BUDGETED: free (TREND) the book earns; PAID (long-vol) you size;")
println("TIMED (GAMMA_REG) is seductive in-sample. Diversification is the engine's edge, not manufactured alpha.")
