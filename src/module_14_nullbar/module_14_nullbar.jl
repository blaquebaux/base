module Nullbar
# =============================================================================
# module_14_nullbar — the governed-research falsification & allocation toolkit.
#
# The guardrails that separate a fragile, overfit backtest from a pre-registered, robust pipeline. A sleeve is promoted
# to the `breakthrough` allocator only if it survives every layer:
#   STRESS (regime) → FRICTION (execution) → BLIND (time-shift null) → MIRAGE (specification) →
#   LEDGER/FDR (corpus multiple-testing) → BREAKTHROUGH (robustness-shrunk allocation)
#
# Ported from the Python prototype (github.com/blaquebaux/nullbar). Stdlib-only (no heavy deps) so it loads cleanly;
# the data-dependent layers (Friction ADV/borrow, PIT universe) consume `base`'s own MarketData feed.
# =============================================================================
using Statistics, LinearAlgebra, Random, Dates, Printf

export TradeLog, BlindResult, effective_n, run_blind_test,
       deflated_sharpe, pbo_cscv, edge_decay, specification_audit,
       FrictionModel, StaticFriction, InstitutionalFriction, slippage, apply_friction, capacity_curve,
       benjamini_hochberg, corpus_fdr, Keeper, shrink_returns, allocate_capital,
       correlation_map, factor_exposure, RegimeFilter, apply_stress,
       PASS_THROUGH, FILTER_ONLY, INVERT_ONLY, ASYMMETRIC

# ---- normal cdf / inverse-normal (stdlib only) ------------------------------------------------------
_erf(x) = (t = 1/(1+0.3275911abs(x)); s = 1 - (((((1.061405429t-1.453152027)t)+1.421413741)t-0.284496736)t+0.254829592)t*exp(-x^2); x ≥ 0 ? s : -s)
_ncdf(x) = 0.5*(1 + _erf(x/sqrt(2)))
function _nppf(p)
    p ≤ 0 && return -Inf; p ≥ 1 && return Inf
    a=(-39.69683028665376,220.9460984245205,-275.9285104469687,138.3577518672690,-30.66479806614716,2.506628277459239)
    b=(-54.47609879822406,161.5858368580409,-155.6989798598866,66.80131188771972,-13.28068155288572)
    c=(-0.007784894002430293,-0.3223964580411365,-2.400758277161838,-2.549732539343734,4.374664141464968,2.938163982698783)
    d=(0.007784695709041462,0.3224671290700398,2.445134137142996,3.754408661907416); pl=0.02425
    if p < pl; q=sqrt(-2log(p)); return (((((c[1]*q+c[2])q+c[3])q+c[4])q+c[5])q+c[6])/((((d[1]*q+d[2])q+d[3])q+d[4])q+1); end
    if p ≤ 1-pl; q=p-0.5; r=q*q; return (((((a[1]*r+a[2])r+a[3])r+a[4])r+a[5])r+a[6])*q/(((((b[1]*r+b[2])r+b[3])r+b[4])r+b[5])r+1); end
    q=sqrt(-2log(1-p)); return -(((((c[1]*q+c[2])q+c[3])q+c[4])q+c[5])q+c[6])/((((d[1]*q+d[2])q+d[3])q+d[4])q+1)
end
_sharpe(r; ppy=252) = (x=filter(isfinite,r); (length(x)>5 && std(x)>0) ? mean(x)/std(x)*sqrt(ppy) : 0.0)

# ============================================================================
# BLIND — time-shift null + cluster-corrected Effective N
# ============================================================================
struct TradeLog; entry_indices::Vector{Int}; hold_periods::Vector{Int}; trade_returns::Vector{Float64}; end
struct BlindResult; actual_sharpe::Float64; p_value::Float64; effective_n::Int; is_robust::Bool; end

"Effective (cluster-corrected) independent trades: total_bars / (avg_hold + min_gap)."
function effective_n(tl::TradeLog, total_bars::Int)
    n = length(tl.entry_indices); n ≤ 1 && return 1, 0
    gaps = [tl.entry_indices[i+1] - (tl.entry_indices[i] + tl.hold_periods[i]) for i in 1:n-1]
    min_gap = minimum(gaps); avg_hold = mean(tl.hold_periods)
    return max(1, floor(Int, total_bars / (avg_hold + max(min_gap,0) + 1))), min_gap
end

"Blind test: drop the exact trade-duration pattern at random (bidirectional) phases; p = P(luck ≥ actual)."
function run_blind_test(tl::TradeLog, universe_returns::Vector{Float64}; n_iterations::Int=5000, rng=MersenneTwister(0))
    T = length(universe_returns); eff_n, _ = effective_n(tl, T)
    lo = 1 - minimum(tl.entry_indices); hi = T - maximum(tl.entry_indices .+ tl.hold_periods)   # valid shift range (both ways)
    blind = zeros(n_iterations)
    for i in 1:n_iterations
        s = rand(rng, lo:hi); s == 0 && (s = 1)
        rs = [prod(1 .+ universe_returns[(e+s):(e+s+h-1)]) - 1 for (e,h) in zip(tl.entry_indices, tl.hold_periods)]
        blind[i] = mean(rs)/std(rs)*sqrt(252)
    end
    actual = mean(tl.trade_returns)/std(tl.trade_returns)*sqrt(252)
    p = count(>=(actual), blind)/n_iterations
    return BlindResult(actual, p, eff_n, p < 0.05 && eff_n ≥ 20)
end

# ============================================================================
# VALIDATION — Deflated Sharpe, PBO (CSCV), Edge Decay
# ============================================================================
"Deflated Sharpe Ratio (Bailey–López de Prado): P(true Sharpe>0) after deflating for n_trials."
function deflated_sharpe(returns::Vector{Float64}, n_trials::Int, trials_sharpe_std::Float64)
    r = filter(isfinite, returns); T = length(r); (T < 20 || std(r) == 0) && return NaN
    sr = mean(r)/std(r); z = (r .- mean(r))./std(r); sk = mean(z.^3); ku = mean(z.^4)
    N = max(n_trials, 2); g = 0.5772156649
    emax = trials_sharpe_std * ((1-g)*_nppf(1-1/N) + g*_nppf(1-1/(N*ℯ)))
    denom = sqrt(max(1e-12, 1 - sk*sr + (ku-1)/4*sr^2))
    return _ncdf(((sr - emax)*sqrt(T-1))/denom)
end

_combs(items, k) = k == 0 ? [Int[]] : k > length(items) ? Vector{Int}[] :
    vcat([[vcat(items[i], c) for c in _combs(items[i+1:end], k-1)] for i in 1:length(items)-k+1]...)

"Probability of Backtest Overfitting via CSCV. perf: (T × N) returns matrix. PBO>0.5 ⇒ selection picks noise."
function pbo_cscv(perf::Matrix{Float64}; S::Int=10)
    T, N = size(perf); (N < 2 || T < S) && return NaN
    S -= S % 2; blocks = [round(Int,(i-1)*T/S)+1 : round(Int,i*T/S) for i in 1:S]
    λ = Float64[]
    for comb in _combs(collect(1:S), S÷2)
        isb = vcat([collect(blocks[i]) for i in comb]...); oob = vcat([collect(blocks[i]) for i in setdiff(1:S,comb)]...)
        sis = [_sharpe(perf[isb,j]) for j in 1:N]; soos = [_sharpe(perf[oob,j]) for j in 1:N]
        nstar = argmax(sis); rank = count(<=(soos[nstar]), soos)/(N+1)
        rank = clamp(rank, 1e-6, 1-1e-6); push!(λ, log(rank/(1-rank)))
    end
    return count(<(0), λ)/length(λ)
end

"Edge decay: IS→OOS Sharpe/PF/win-rate, consistency-weighted score 0–100 + grade."
function edge_decay(returns::Vector{Float64}; split=0.5)
    r = filter(isfinite, returns); k = floor(Int, length(r)*split); IS=r[1:k]; OOS=r[k+1:end]
    pf(x) = (g=sum(x[x.>0]); l=-sum(x[x.<0]); l>0 ? g/l : Inf)
    sr_is=_sharpe(IS); sr_oos=_sharpe(OOS)
    consistency = sr_is>0 ? clamp(sr_oos/sr_is,0,1) : 0.0
    score = 100*(0.4consistency + 0.3*clamp(sr_oos/1.0,0,1) + 0.3*clamp((pf(OOS)-1)/((pf(IS)>1 ? pf(IS)-1 : 1e9)),0,1))
    grade = score≥80 ? "A" : score≥65 ? "B" : score≥50 ? "C" : score≥35 ? "D" : "F"
    return (score=round(score), grade=grade, sr_is=round(sr_is,digits=2), sr_oos=round(sr_oos,digits=2))
end

# ============================================================================
# MIRAGE — specification sign-stability (Leamer extreme bounds + bad-control)
# ============================================================================
function _ols(y, X)
    β = X \ y; resid = y - X*β; n,k = size(X); dof = max(n-k,1); s2 = (resid'resid)/dof
    XtXinv = try inv(X'X) catch; pinv(X'X) end
    se = sqrt.(max.(diag(s2 .* XtXinv), 0)); t = β ./ map(x->x>0 ? x : NaN, se)
    r2 = var(y)>0 ? 1 - var(resid)/var(y) : NaN
    return β, t, r2
end

"Re-estimate target ~ controls across ALL control subsets; report alpha sign-stability, per-control ΔR² vs Δalpha,
verdict ROBUST/FRAGILE/NULL/MIRAGE. A mirage control raises R² while killing alpha, collinear with the target."
function specification_audit(target::Vector{Float64}, controls::Dict{String,Vector{Float64}}; ann=252, max_controls=8)
    names = collect(keys(controls))[1:min(end,max_controls)]
    T = minimum(vcat(length(target), [length(controls[c]) for c in names]))
    y = target[end-T+1:end]; X = Dict(c=>controls[c][end-T+1:end] for c in names)
    a0 = mean(y)*ann; results = Tuple{Vector{String},Float64,Float64,Float64}[]
    for mask in 0:(2^length(names)-1)
        sub = [names[i] for i in 1:length(names) if (mask >> (i-1)) & 1 == 1]
        M = hcat(ones(T), [X[c] for c in sub]...)
        β,t,r2 = _ols(y, M); push!(results, (sub, β[1]*ann, t[1], r2))
    end
    alphas = [r[2] for r in results]; talphas = [r[3] for r in results]
    sign_stable = mean(sign.(alphas) .== sign(a0)); frac_sig = mean((abs.(talphas).>2) .& (sign.(alphas).==sign(a0)))
    rmap = Dict(r[1]=>r for r in results); marg = Dict{String,NamedTuple}()
    for c in names
        dR=Float64[]; dA=Float64[]
        for r in results
            if c in r[1]
                prev = filter(!=(c), r[1]); p = get(rmap, prev, nothing)
                if p !== nothing; push!(dR, r[4]-p[4]); push!(dA, r[2]-p[2]); end
            end
        end
        marg[c] = (d_r2 = isempty(dR) ? NaN : mean(dR), d_alpha = isempty(dA) ? NaN : mean(dA),
                   corr = cor(y, X[c]))
    end
    mirage_controls = [c for c in names if isfinite(marg[c].d_r2) && marg[c].d_r2>0 && marg[c].d_alpha*sign(a0)<0 && abs(marg[c].corr)>0.3]
    verdict = sign_stable>0.95 && frac_sig>0.6 ? "ROBUST" :
              abs(a0)<0.02 && frac_sig<0.1 ? "NULL (no alpha under any spec)" :
              sign_stable>0.8 ? "FRAGILE (alpha collapses/insignificant under controls; sig in $(round(Int,frac_sig*100))% of specs)" :
              "MIRAGE (alpha sign flips across specs)"
    return (alpha_base=a0, alpha_min=minimum(alphas), alpha_max=maximum(alphas), alpha_sign_stable=sign_stable,
            alpha_frac_significant=frac_sig, n_specs=length(results), marginals=marg,
            mirage_controls=mirage_controls, verdict=verdict)
end

# ============================================================================
# FRICTION — Almgren-Chriss √-impact + dynamic borrow + capacity
# ============================================================================
abstract type FrictionModel end
struct StaticFriction <: FrictionModel; half_spread_bps::Float64; commission_bps::Float64; end
StaticFriction(; half_spread_bps=2.5, commission_bps=1.0) = StaticFriction(half_spread_bps, commission_bps)
struct InstitutionalFriction <: FrictionModel; impact_coeff::Float64; half_spread_bps::Float64; borrow_base_bps::Float64; htb_multiplier::Float64; end
InstitutionalFriction(; impact_coeff=0.3, half_spread_bps=2.5, borrow_base_bps=25.0, htb_multiplier=5.0) =
    InstitutionalFriction(impact_coeff, half_spread_bps, borrow_base_bps, htb_multiplier)

slippage(m::StaticFriction, args...) = (m.half_spread_bps + m.commission_bps)/1e4
slippage(m::InstitutionalFriction, trade_usd, adv_usd, daily_vol) =
    m.half_spread_bps/1e4 + m.impact_coeff * daily_vol * sqrt(trade_usd/max(adv_usd,1.0))
borrow_day(m::InstitutionalFriction; utilization=0.0) = m.borrow_base_bps/1e4/252 * (utilization>0.80 ? m.htb_multiplier : 1.0)

"Gross→net per-trade returns, direction-aware (two legs of slippage; borrow on shorts over the hold)."
function apply_friction(gross::Vector{Float64}, trade_usd, adv_usd, daily_vol, directions, holds, m::InstitutionalFriction; utilization=0.0)
    net = similar(gross)
    for i in eachindex(gross)
        rt = 2*slippage(m, trade_usd[i], adv_usd[i], daily_vol[i])
        bor = directions[i] < 0 ? borrow_day(m; utilization=utilization)*holds[i] : 0.0
        net[i] = (1+gross[i])*(1-rt-bor) - 1
    end
    return net
end

"Net Sharpe vs AUM and the break-even AUM where impact eats the edge."
function capacity_curve(gross_ann_return, gross_ann_vol, annual_turnover, adv_usd, daily_vol, m::InstitutionalFriction;
                        aum_grid=[1e6,5e6,1e7,5e7,1e8,5e8,1e9,5e9], sharpe_floor=0.3)
    rows = NamedTuple[]
    for aum in aum_grid
        trade = aum*annual_turnover/252
        drag = annual_turnover * slippage(m, trade, adv_usd, daily_vol)
        nr = gross_ann_return - drag
        push!(rows, (aum=aum, net_return=nr, net_sharpe=nr/gross_ann_vol, drag=drag))
    end
    below = filter(r->r.net_sharpe<sharpe_floor, rows)
    return (grid=rows, breakeven_aum = isempty(below) ? Inf : below[1].aum)
end

# ============================================================================
# LEDGER — pre-registration + corpus-wide FDR
# ============================================================================
sharpe_pvalue(sr_ann, T; ppy=252) = 1 - _ncdf(sr_ann*sqrt(max(T,1)/ppy))

"Benjamini-Hochberg step-up FDR; returns (survivor mask, threshold)."
function benjamini_hochberg(pvals::Vector{Float64}; q=0.10)
    n = length(pvals); order = sortperm(pvals); ranked = pvals[order]
    thresh = collect(1:n)./n .* q; passed = ranked .<= thresh
    kmax = any(passed) ? maximum(findall(passed)) : 0
    cut = kmax>0 ? ranked[kmax] : 0.0
    return (pvals .<= cut), cut
end

"Corpus-wide FDR + deflated Sharpe. sleeves: Vector of (name, sharpe, T)."
function corpus_fdr(sleeves::Vector{<:NamedTuple}; q=0.10, ppy=252)
    srs = [s.sharpe for s in sleeves]; Ts = [s.T for s in sleeves]; N = length(sleeves)
    pvals = [sharpe_pvalue(sr, T; ppy=ppy) for (sr,T) in zip(srs,Ts)]
    surv, cut = benjamini_hochberg(pvals; q=q)
    g=0.5772156649; sr_var = std(srs)/sqrt(ppy)
    emax = sr_var*((1-g)*_nppf(1-1/N) + g*_nppf(1-1/(N*ℯ)))
    out = [(name=s.name, sharpe=s.sharpe, p=pvals[i], bh_survivor=surv[i],
            dsr = Ts[i]>1 ? _ncdf((s.sharpe/sqrt(ppy)-emax)*sqrt(Ts[i]-1)) : NaN) for (i,s) in enumerate(sleeves)]
    return (threshold=cut, expected_max_sharpe=emax*sqrt(ppy), results=sort(out, by=r->r.p))
end

# ============================================================================
# BREAKTHROUGH — robustness-shrinkage allocator
# ============================================================================
const MIRAGE_PENALTY = Dict("ROBUST"=>1.0, "FRAGILE"=>0.5, "NULL"=>0.0, "MIRAGE"=>0.0)
struct Keeper; name::String; net_expected_return::Float64; returns::Vector{Float64}; blind_p::Float64; eff_n::Int; mirage::String; end

function shrink_returns(keepers::Vector{Keeper}; γ=1.5)
    [(name=k.name, raw=k.net_expected_return,
      shrunk = k.net_expected_return * (1-k.blind_p)^γ * min(1.0, k.eff_n/30) * get(MIRAGE_PENALTY, split(k.mirage)[1], 1.0))
     for k in keepers]
end

function _risk_parity(Σ; iters=500)
    n = size(Σ,1); w = ones(n)/n
    for _ in 1:iters
        rc = w .* (Σ*w); w = w .* (mean(rc)./max.(rc,1e-12)).^0.5; w = max.(w,0); w ./= sum(w)
    end
    return w
end

"Shrink expected returns by robustness, drop ≤0, risk-parity to target vol."
function allocate_capital(keepers::Vector{Keeper}; target_vol=0.10, γ=1.5)
    sh = shrink_returns(keepers; γ=γ); keep = [k for (k,s) in zip(keepers,sh) if s.shrunk>0]
    isempty(keep) && return (weights=Dict{String,Float64}(), shrink=sh)
    L = minimum(length(k.returns) for k in keep); R = reduce(vcat, [k.returns[end-L+1:end]' for k in keep])
    Σ = cov(R', dims=1).*252; w = _risk_parity(Σ); pv = sqrt(w'Σ*w); lev = pv>0 ? target_vol/pv : 1.0
    return (weights=Dict(k.name=>w[i]*lev for (i,k) in enumerate(keep)), shrink=sh)
end

# ============================================================================
# SLEEVEMAP — correlation + factor exposure
# ============================================================================
"Correlation matrix, effective number of bets (1/wρw), average pairwise corr."
function correlation_map(R::Matrix{Float64})   # (N sleeves × T)
    C = cor(R, dims=2); n = size(C,1); w = ones(n)/n
    return (corr=C, eff_bets=1/(w'C*w), avg_corr=(sum(C)-n)/(n^2-n))
end

"Regress the combined book on factors; factor-R² and residual alpha (diversifying part)."
function factor_exposure(book::Vector{Float64}, factors::Dict{String,Vector{Float64}})
    names = collect(keys(factors)); T = minimum(vcat(length(book), [length(factors[f]) for f in names]))
    y = book[end-T+1:end]; X = hcat(ones(T), [factors[f][end-T+1:end] for f in names]...)
    β,_,r2 = _ols(y, X); resid = y - X*β
    return (alpha_ann=β[1]*252, betas=Dict(names[i]=>β[i+1] for i in 1:length(names)),
            factor_r2=r2, resid_sharpe=_sharpe(resid))
end

# ============================================================================
# STRESS — regime filter / inversion wrapper
# ============================================================================
const PASS_THROUGH, FILTER_ONLY, INVERT_ONLY, ASYMMETRIC = :PassThrough, :FilterOnly, :InvertOnly, :Asymmetric
struct RegimeFilter; name::String; regime::Vector{Bool}; mode::Symbol; end

"Transform a raw signal (>0 long, <0 short) by a regime filter without touching alpha logic."
function apply_stress(raw::Vector{Float64}, rf::RegimeFilter)
    s = copy(raw); g = rf.regime[end-length(s)+1:end]
    rf.mode == PASS_THROUGH && return s
    if rf.mode == FILTER_ONLY; s[.!g] .= 0.0
    elseif rf.mode == INVERT_ONLY; s[g] .= -s[g]
    elseif rf.mode == ASYMMETRIC; s[(.!g) .& (s.<0)] .= 0.0; s[g .& (s.>0)] .= 0.0; end
    return s
end

end # module Nullbar
