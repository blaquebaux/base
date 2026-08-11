#!/usr/bin/env julia
# =============================================================================
# keeper_ingredients.jl — SHARED builder for the family's full keeper set.
#
# Not a sketch: a single source of truth for the reconstructed keeper ingredient
# matrix, used by multi_sleeve_portfolio.jl, negentropy_ranking.jl and
# hedge_saturation.jl so the sleeve constructions never drift between them.
# `include` it, then call `build_ingredients()`. It also brings the engine's
# PortfolioOpt (and the Gamma-ARMA modules 4/5) into scope for the caller.
#
# Ingredients: 5 asset classes (SPY/IEF/GLD/DBC/DBA) + 10 keeper sleeves
#   CRACK BORE TREND CAMPROT DDBOUNCE BLOCK REGIME GAMMA_REG BARBELL CURVEBALL.
# Keys from env only (ALPACA_KEY_ID / ALPACA_SECRET_KEY). Read-only (data only).
# =============================================================================
using Dates, HTTP, JSON3, Statistics, LinearAlgebra, Printf
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl")); using .PortfolioOptModule
include(joinpath(REPO, "src/module_4_arma/module_4_arma.jl"));             using .ARMAGARCH
include(joinpath(REPO, "src/module_5_dpm/module_5_dpm.jl"));               using .DPM

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

const BORE_BASKET = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                     "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const TREND_ASSETS = ["SPY","IEF","TLT","GLD","DBC","DBA"]
const BROWN = ["XLE","XME","XOP","DBA","MOO"]          # value / real-economy camp
const BLUE  = ["XLK","ICLN","TAN","DIS","NFLX"]         # growth / long-duration-equity camp
const BLOCK_ASSETS = ["SPY","TLT","GLD","DBC","UUP"]    # one proxy per derivative block

# pure sleeve math (series builders + today-weight emitters), shared with the live driver
# (keeper_book_live.jl) so the two can never drift:
include(joinpath(@__DIR__, "keeper_sleeves.jl"))
function compute_gamma_regime(mkt, bil, vixy, vxz, Tr)
    sv = ARMAGARCH.rolling_realized_vol(mkt, 10); base = fill(NaN, Tr)
    for t in 252:Tr; w = sv[t-251:t]; w = w[.!isnan.(w)]; isempty(w) || (base[t] = median(w)); end
    crisis = falses(Tr)
    for t in 2:Tr
        (isnan(sv[t]) || isnan(base[t]) || base[t] <= 0) && continue
        vol3x = sv[t] > 3 * base[t]
        αlt   = ARMAGARCH.tail_index_from_vol_scale(sv[t], base[t]) < 1.8
        dstd  = std(mkt[max(1, t-251):t])
        jgt   = dstd > 0 && mean(abs.(mkt[max(1, t-9):t]) .> 3 * dstd) > 0.3
        vv    = t > 5 && (prod(1 .+ vxz[t-4:t]) != 0) &&
                (prod(1 .+ vixy[t-4:t]) / prod(1 .+ vxz[t-4:t])) > 1.1
        crisis[t] = DPM.detect_crisis_regime(nothing, vol3x, αlt, jgt, vv)
    end
    reg = fill(NaN, Tr); for t in 2:Tr; reg[t] = crisis[t-1] ? bil[t] : mkt[t]; end
    reg, crisis
end
# (compute_camprot / compute_ddbounce / compute_regime / compute_barbell / compute_curveball
#  now live in keeper_sleeves.jl, included above.)

# ---- shared metric helpers ----
skewf(x) = (m = mean(x); s = std(x); s > 0 ? mean((x .- m).^3)/s^3 : 0.0)
exkurt(x) = (m = mean(x); s = std(x); s > 0 ? mean((x .- m).^4)/s^4 - 3.0 : 0.0)
covidret(r, covid) = isempty(covid) ? 0.0 : prod(1 .+ r[covid]) - 1
function cvar(r, q=0.05)                    # mean of the worst q-tail (a positive loss number)
    s = sort(r); n = max(1, round(Int, q * length(s))); -mean(s[1:n])
end

"""
    build_ingredients() -> NamedTuple

Fetch, build every keeper sleeve, assemble the ingredient matrix over the common
valid window, and return `(; labels, Rp, cvd, covid, gamma_crisis)`:
`Rp` is days×ingredients (valid rows only), `cvd` the aligned dates, `covid` the
row indices of the 2020-02-19..03-23 crash, `gamma_crisis` the valid-trimmed flag.
"""
function build_ingredients()
    RAW = unique(vcat(["SPY","IEF","GLD","DBC","DBA","TLT","USO","CRAK","VIXY","VXZ","BIL","UUP"],
                      BORE_BASKET, BROWN, BLUE))
    @info "fetching $(length(RAW)) symbols..."
    D = Dict(s => fetch_closes(s) for s in RAW)
    D = Dict(s => v for (s, v) in D if length(v) > 500)
    dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
    P(s) = [D[s][d] for d in dates]
    ret(s) = (p = P(s); p[2:end] ./ p[1:end-1] .- 1)
    rdates = dates[2:end]; Tr = length(rdates); spy = ret("SPY")
    retmat(syms) = hcat([ret(s) for s in syms]...)

    crack    = compute_crack(ret("USO"), ret("CRAK"), Tr)
    bore     = compute_bore(retmat(BORE_BASKET), spy, Tr)
    trend    = compute_trend(retmat(TREND_ASSETS), Tr)
    camprot  = compute_camprot(vec(mean(retmat(BROWN), dims=2)), vec(mean(retmat(BLUE), dims=2)), Tr)
    ddbounce = compute_ddbounce(retmat(BORE_BASKET), Tr)
    block    = compute_trend(retmat(BLOCK_ASSETS), Tr)
    regime   = compute_regime(spy, ret("BIL"), Tr)
    gamma_reg, gamma_crisis = compute_gamma_regime(spy, ret("BIL"), ret("VIXY"), ret("VXZ"), Tr)
    barbell  = compute_barbell(ret("BIL"), ret("VIXY"), rdates, Tr)
    curveball = compute_curveball(ret("BIL"), ret("VIXY"), spy, Tr)

    labels = ["SPY","IEF","GLD","DBC","DBA","CRACK","BORE","TREND","CAMPROT","DDBOUNCE","BLOCK","REGIME","GAMMA_REG","BARBELL","CURVEBALL"]
    cols = [ret("SPY"), ret("IEF"), ret("GLD"), ret("DBC"), ret("DBA"),
            crack, bore, trend, camprot, ddbounce, block, regime, gamma_reg, barbell, curveball]
    Rp = hcat(cols...)
    valid = findall(t -> all(isfinite, Rp[t, :]), 1:Tr)
    Rp = Rp[valid, :]; cvd = rdates[valid]
    covid = findall(d -> "2020-02-19" <= d <= "2020-03-23", cvd)
    @info "ingredient matrix" days=size(Rp,1) ingredients=size(Rp,2) span="$(cvd[1]) .. $(cvd[end])"
    return (; labels, Rp, cvd, covid, gamma_crisis = gamma_crisis[valid])
end
