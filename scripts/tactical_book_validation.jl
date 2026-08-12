#!/usr/bin/env julia
# ============================================================================
# tactical_book_validation.jl — the TACTICAL SLEEVE BOOK: the non-keepers built the way they are meant to be
# used (user's design): NOT standalone perpetual sleeves, but REGIME sleeves run in LIMITED size, ONLY in their
# favorable regime, TIME-BOXED to a quarter or two (forced stand-down + cooldown), and COMBINED so no one sleeve
# carries the book. Encodes the three rules and validates the combined book — causal, net of cost — both
# standalone and as an OVERLAY on the keeper book (cost-push alone added nothing; the diversified COMBO should).
#
# THE THREE RULES (per sleeve): (1) alloc cap ALLOC; (2) regime gate — deploy only when the sleeve's own signal
# is on (each target returns flat otherwise); (3) time-box — after MAXHOLD consecutive deployed rebalances,
# force stand-down for COOL rebalances (caps the "overstay the regime into the reversal" tail).
# Sleeves: cost-push (short food-mfrs when suppliers strong), beige (short airlines when fuel rising, short-only),
# bulgar (long processors when ag rising). Each SPY-beta-hedged -> market-neutral. Reuses the keeper machinery so
# the keeper book + tactical book share one causal, net-of-cost, date-aligned walk-forward. Read-only (data only).
#
# RESULT (net 5bp/side, causal, 2017-11..2026-07) — the design WORKS:
#   standalone: cost-push +0.22 / beige +0.38 / bulgar +0.16 Sharpe, each beta ~0, maxDD 2-5%. COMBINED 30%
#   tactical book +0.45 Sharpe, beta -0.01, maxDD -6% — the combo BEATS every individual sleeve (diversification
#   is additive; the sleeves cover each other's regime losses). corr(tactical, keeper) = +0.04 (uncorrelated),
#   so as an OVERLAY it LIFTS the keeper book: keeper +1.28 -> +1.35 at half-weight (+0.07 / ~5%). Cost-push ALONE
#   added +0.1% (nothing); the COMBINED book adds ~5%, because it has a real +0.45 own-Sharpe at ~0 correlation.
#   CONCLUSION: the non-keepers, used as the user prescribed (small + regime-gated + time-boxed + combined), are a
#   worthwhile uncorrelated overlay on the keeper book. The time-box costs a little Sharpe on these clean-neutral
#   sleeves (a safety rail for the tail-prone/directional ones); keep it as governance, not a return driver.
#   Run:  julia --project=. scripts/tactical_book_validation.jl
# ============================================================================
using Statistics, LinearAlgebra, Dates, Printf
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "scripts/research/keeper_ingredients.jl"))
include(joinpath(REPO, "src/module_11_cv/purged_kfold.jl")); using .PurgedKFold

const SPINE_AC     = ["SPY", "IEF", "GLD", "DBC", "DBA"]
const TREND_ASSETS = ["SPY", "IEF", "TLT", "GLD", "DBC", "DBA"]
const BORE_NAMES   = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","JPM","V","MA","UNH","HD",
                      "PG","XOM","JNJ","COST","WMT","LLY","ORCL","CVX"]
const CP_SUP  = ["INGR","ADM"]; const CP_CUST = ["KO","PEP","MDLZ","GIS","KHC"]
const BEIGE_AIR = ["DAL","UAL","AAL","LUV","ALK","JBLU"]
const BULGAR_PROC = ["INGR","ADM","BG"]
const DATA_UNIVERSE = unique(vcat(SPINE_AC, TREND_ASSETS, ["CRAK","USO","DBA"], BORE_NAMES,
                                  CP_SUP, CP_CUST, BEIGE_AIR, BULGAR_PROC))
const COST = parse(Float64, get(ENV, "BB_COST_BPS", "5")) / 1e4
const REB, WARMUP = 21, 380
const ALLOC = 0.10                 # limited space: 10% of the tactical book per sleeve
const MAXHOLD = 5                   # time-box: max consecutive deployed rebalances (~5 mo = a quarter or two)
const COOL = 1                      # cooldown rebalances after a time-box stand-down (~1 mo)

@info "fetching $(length(DATA_UNIVERSE)) instruments..."
D = Dict(s => fetch_closes(s) for s in DATA_UNIVERSE)
dates = sort(collect(intersect([Set(keys(v)) for v in values(D)]...)))
Rinst = hcat([(p = [D[s][d] for d in dates]; p[2:end] ./ p[1:end-1] .- 1) for s in DATA_UNIVERSE]...)
rdates = dates[2:end]; T = size(Rinst, 1); sidx = Dict(s => i for (i, s) in enumerate(DATA_UNIVERSE))
col(R, s) = R[:, sidx[s]]

# ---- keeper book (unchanged) ----
function ingredients(R)
    ac = [col(R, s) for s in SPINE_AC]
    hcat(ac..., compute_crack(col(R,"USO"), col(R,"CRAK"), size(R,1)),
         compute_bore(hcat([col(R,s) for s in BORE_NAMES]...), col(R,"SPY"), size(R,1)),
         compute_trend(hcat([col(R,s) for s in TREND_ASSETS]...), size(R,1)))
end
function keeper_weights(R)
    Rp = ingredients(R); valid = findall(t -> all(isfinite, Rp[t,:]), 1:size(Rp,1))
    b = risk_parity(cov(Rp[valid,:])); bAC,bC,bB,bT = b[1:5],b[6],b[7],b[8]
    tw = trend_weights_today(hcat([col(R,s) for s in TREND_ASSETS]...))
    wbo, beta = bore_weights_today(hcat([col(R,s) for s in BORE_NAMES]...), col(R,"SPY")); csig = crack_signal(col(R,"USO"))
    net = Dict{String,Float64}(); add!(s,x)=(net[s]=get(net,s,0.0)+x)
    for (k,s) in enumerate(SPINE_AC); add!(s,bAC[k]); end; add!("CRAK", bC*csig)
    for (k,s) in enumerate(TREND_ASSETS); add!(s,bT*tw[k]); end
    for (k,s) in enumerate(BORE_NAMES); add!(s,bB*wbo[k]); end; add!("SPY", bB*(-beta)); net
end

# ---- a generic market-neutral regime sleeve: SHORT/LONG a basket when a signal-level trend is up ----
_lvl(R, names) = cumprod(1 .+ vec(mean(hcat([col(R,s) for s in names]...), dims=2)))
function neutral_sleeve(R, basket, sig_lvl_names, side, lb)          # side = -1 short basket, +1 long basket
    Tr = size(R,1); sl = _lvl(R, sig_lvl_names)
    on = Tr > lb && (sl[Tr]/sl[Tr-lb] - 1) > 0
    !on && return (Dict{String,Float64}(), false)
    B = hcat([col(R,s) for s in basket]...); spy = col(R,"SPY")
    br = vec(mean(B, dims=2))                                        # equal-weight basket daily return
    w60 = max(1,Tr-59):Tr; bt = var(spy[w60])>0 ? clamp(cov((side.*br)[w60], spy[w60])/var(spy[w60]), -3.0, 3.0) : 0.0
    net = Dict{String,Float64}(); for s in basket; net[s] = side*(1/length(basket)); end
    net["SPY"] = get(net,"SPY",0.0) - bt                             # market-neutral hedge
    (net, true)
end
costpush_w(R) = neutral_sleeve(R, CP_CUST,     CP_SUP,       -1.0, 63)     # short customers when suppliers strong
beige_w(R)    = neutral_sleeve(R, BEIGE_AIR,   ["USO"],      -1.0, 126)    # short airlines when fuel rising
bulgar_w(R)   = neutral_sleeve(R, BULGAR_PROC, ["DBA"],      +1.0, 63)     # long processors when ag rising
const SLEEVES = [("cost-push", costpush_w), ("beige", beige_w), ("bulgar", bulgar_w)]

# ---- dual walk-forward with TACTICAL GOVERNANCE (cap + time-box + cooldown) ----
oosK = Float64[]; oosT = Float64[]; oosS = Dict(n=>Float64[] for (n,_) in SLEEVES); oosidx = Int[]
wpK = Dict{String,Float64}(); wpT = Dict{String,Float64}()
runlen = Dict(n=>0 for (n,_) in SLEEVES); cooldn = Dict(n=>0 for (n,_) in SLEEVES)   # time-box state per sleeve
for t0 in WARMUP:REB:(T-1)
    wK = keeper_weights(Rinst[1:t0,:])
    wT = Dict{String,Float64}(); sleeve_net = Dict(n=>Dict{String,Float64}() for (n,_) in SLEEVES)
    for (n, f) in SLEEVES
        net, on = f(Rinst[1:t0,:])
        deploy = on
        if cooldn[n] > 0; cooldn[n] -= 1; deploy = false; runlen[n] = 0
        elseif on && runlen[n] >= MAXHOLD; cooldn[n] = COOL; deploy = false; runlen[n] = 0   # time-box hit
        elseif on; runlen[n] += 1
        else; runlen[n] = 0; end
        if deploy
            for (s,x) in net; v = ALLOC*x; wT[s] = get(wT,s,0.0)+v; sleeve_net[n][s] = v; end
        end
    end
    tK = sum(abs(get(wK,s,0.0)-get(wpK,s,0.0)) for s in union(keys(wK),keys(wpK)))
    tT = sum(abs(get(wT,s,0.0)-get(wpT,s,0.0)) for s in union(keys(wT),keys(wpT)); init=0.0)
    for day in (t0+1):min(t0+REB, T)
        rK = sum(get(wK,s,0.0)*Rinst[day,sidx[s]] for s in keys(wK))
        rT = sum(get(wT,s,0.0)*Rinst[day,sidx[s]] for s in keys(wT); init=0.0)
        day==t0+1 && (rK -= tK*COST; rT -= tT*COST)
        push!(oosK,rK); push!(oosT,rT); push!(oosidx,day)
        for (n,_) in SLEEVES
            sn = sleeve_net[n]; push!(oosS[n], sum(get(sn,s,0.0)*Rinst[day,sidx[s]] for s in keys(sn); init=0.0))
        end
    end
    global wpK = wK; global wpT = wT
end

S(x)=sharpe(collect(skipmissing(x))); vol(x)=std(x)*sqrt(252)
DD(x)=(l=cumprod(1 .+ x); minimum(l ./ accumulate(max,l) .- 1))
yrs = unique([rdates[i][1:4] for i in oosidx])
yrret(x) = [prod(1 .+ x[[j for j in eachindex(oosidx) if rdates[oosidx[j]][1:4]==y]])-1 for y in yrs]

println("="^80, "\nTACTICAL SLEEVE BOOK — non-keepers, capped+regime-gated+time-boxed+combined (net, causal)\n", "="^80)
@printf("\n  window %s..%s  OOS days %d   rules: %.0f%%/sleeve, time-box %d reb (~%d mo), cooldown %d reb\n",
        rdates[oosidx[1]], rdates[oosidx[end]], length(oosT), ALLOC*100, MAXHOLD, MAXHOLD, COOL)
@printf("\n  %-28s %8s %8s %8s %7s\n", "book", "Sharpe", "CAGR", "maxDD", "beta")
spyO = [Rinst[i,sidx["SPY"]] for i in oosidx]; bto(x) = var(spyO)>0 ? cov(x,spyO)/var(spyO) : 0.0
for (n,_) in SLEEVES
    x=oosS[n]; @printf("  %-28s %+8.2f %7.1f%% %7.0f%% %+7.2f\n", "  $n (10%)", S(x), ann_return(x)*100, DD(x)*100, bto(x))
end
betaT = bto(oosT)
@printf("  %-28s %+8.2f %7.1f%% %7.0f%% %+7.2f\n", "COMBINED tactical (30%)", S(oosT), ann_return(oosT)*100, DD(oosT)*100, betaT)
@printf("\n  corr(tactical book, keeper book) = %+.2f\n", cor(oosT, oosK))
# overlay: keeper + w*tactical
sK = S(oosK)
println("\n  OVERLAY on keeper book (keeper + w*tactical), net:")
@printf("    %-8s %8s %8s\n", "w", "Sharpe", "dSharpe")
for w in (0.0, 0.5, 1.0, 1.5, 2.0)
    comb = oosK .+ w .* oosT; @printf("    %-8.1f %+8.2f %+8.2f\n", w, S(comb), S(comb)-sK)
end
@printf("\n  keeper alone %+.2f ; combined tactical alone %+.2f (beta %+.2f) ; per-year tactical: %s\n",
        sK, S(oosT), betaT, join(["$(yrs[k]) $(round(100*yrret(oosT)[k]))%" for k in eachindex(yrs)], " "))
