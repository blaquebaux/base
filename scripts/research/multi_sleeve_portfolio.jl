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
#     CRACK    crude->refiner lead-lag (long CRAK when crude up)
#     BORE     beta-hedged momentum-neutral over large caps
#     TREND    vol-scaled multi-horizon trend over the spine (convexity is free)
#     CAMPROT  brown/blue camp rotation (hold the stronger-trending camp)
#     DDBOUNCE drawdown-bounce (long the most-fallen quality names)
#
# The two beta-heavy sleeves (CAMPROT, DDBOUNCE) add return but also correlation;
# the genuinely uncorrelated fragments (BORE, TREND, CRACK) are what the risk-based
# allocators lean on — that is the honest lesson, made visible in the weights.
#
# RESULTS AS TESTED (2017-2026, gross of costs; avg pairwise corr 0.15):
#   standalone Sharpe / maxDD:
#     SPY +0.80/-34  IEF +0.12/-24  GLD +0.80/-26  DBC +0.55/-41  DBA +0.42/-32
#     CRACK +1.20/-24  BORE +0.26/-27  TREND +0.68/-16  CAMPROT +0.88/-36  DDBOUNCE +0.81/-39
#   optimized book        Sharpe   CAGR   vol  maxDD
#     equal-weight         +1.38   12.5%   9%  -17%
#     risk-parity          +1.48    7.7%   5%   -8%   <- best risk-adjusted, robustly diversified
#     max-diversification  +1.43    6.3%   4%   -6%
#     HRP                  +1.36    6.1%   4%   -7%
#     min-variance         +1.21    4.8%   4%   -7%
#     min-CVaR             +1.17    4.7%   4%   -7%
#   best SINGLE ingredient: CRACK +1.20 at -24% DD.
#   risk-parity weights: IEF 28% | TREND 22% | BORE 12% | DBA 8% | CRACK 7% | ... | DDBOUNCE 4% | CAMPROT 3%
# The honest read: with the full keeper set the diversified book now BEATS the best single (lucky)
# sleeve on BOTH axes — risk-parity +1.48 Sharpe vs CRACK's +1.20, at -8% drawdown vs -24% — because
# the added keepers include genuinely uncorrelated diversifiers (TREND corr -0.11, BORE -0.07). The
# weights make the lesson blunt: the beta-heavy keepers CAMPROT/DDBOUNCE (corr 0.75/0.79) earn only
# 3-4% despite +0.88/+0.81 standalone Sharpe. HIGH STANDALONE SHARPE DOES NOT EARN WEIGHT; LOW
# CORRELATION DOES. That is the diversification payoff — robustness and drawdown control — not
# manufactured alpha; and it far exceeds the old Bio+Basel-only pair (+0.71).
#
# Read-only (data only). Run:  julia --project=. scripts/research/multi_sleeve_portfolio.jl
# =============================================================================
using Dates, HTTP, JSON3, Statistics, LinearAlgebra, Printf
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
using .PortfolioOptModule

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
RAW = unique(vcat(["SPY","IEF","GLD","DBC","DBA","TLT","USO","CRAK"], BORE_BASKET, BROWN, BLUE))

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

# ---- assemble the ingredient matrix over the common valid range ----
labels = ["SPY","IEF","GLD","DBC","DBA","CRACK","BORE","TREND","CAMPROT","DDBOUNCE"]
cols = [ret("SPY"), ret("IEF"), ret("GLD"), ret("DBC"), ret("DBA"),
        crack, bore, trend, camprot, ddbounce]
Rp = hcat(cols...)
valid = findall(t -> all(isfinite, Rp[t, :]), 1:Tr)
Rp = Rp[valid, :]; K = size(Rp, 2)
@info "ingredient matrix" days=size(Rp,1) ingredients=K span="$(rdates[valid[1]]) .. $(rdates[valid[end]])"

println("\n", "="^80, "\nMULTI-SLEEVE PORTFOLIO — engine PortfolioOpt on the FULL KEEPER SET\n", "="^80)
println("\nstandalone ingredients (5 asset classes + 5 keeper sleeves):")
for j in 1:K
    r = Rp[:, j]
    @printf("  %-9s Sharpe %+.2f  vol %2.0f%%  maxDD %4.0f%%  corr-SPY %+.2f\n",
            labels[j], sharpe(r), ann_vol(r)*100, max_drawdown(r)*100, cor(r, Rp[:,1]))
end
avgcorr = (sum(cor(Rp)) - K) / (K*(K-1))
@printf("\n  average pairwise correlation across ingredients: %.2f  (low = lots to diversify)\n", avgcorr)

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
println("\nread: risk-based allocators lean on the genuinely uncorrelated fragments (BORE/TREND/CRACK);")
println("the beta-heavy keepers (CAMPROT/DDBOUNCE) add return but get down-weighted. The diversified")
println("book matches the best single sleeve's Sharpe at a fraction of its drawdown — diversification,")
println("the engine's real edge, NOT manufactured alpha.")
