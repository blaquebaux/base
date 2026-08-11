#!/usr/bin/env julia
# =============================================================================
# keeper_sleeves.jl — the PURE sleeve math shared by keeper_ingredients.jl (research) and
# keeper_book_live.jl (the governed driver), so the two can never drift.
#
# No engine deps: just array math (Base + Statistics + LinearAlgebra). Each `compute_*` returns
# the sleeve's full daily return SERIES (for covariance / risk-parity); the `*_today` helpers
# return the sleeve's CURRENT instrument weights (for the live driver's per-symbol netting).
# The engine-coupled Gamma-ARMA detector (compute_gamma_regime) stays in keeper_ingredients.jl.
# =============================================================================
using Statistics, LinearAlgebra

ewma_vol(R, hl) = begin
    lam = 0.5^(1/hl); T, N = size(R); o = zeros(T, N); v = R[1, :].^2
    for t in 1:T
        v = t == 1 ? R[t, :].^2 : lam .* v .+ (1 - lam) .* R[t, :].^2
        o[t, :] = sqrt.(max.(v, 1e-16))
    end
    o
end

# ---- CRACK: crude->refiner (long CRAK when crude up) ----
function compute_crack(uso, crak, Tr)
    crack = zeros(Tr); for t in 1:Tr-1; crack[t+1] = (uso[t] > 0 ? 1.0 : 0.0) * crak[t+1]; end; crack
end
crack_signal(uso) = uso[end] > 0 ? 1.0 : 0.0                     # today's CRAK weight (0 or 1)

# ---- BORE: beta-hedged momentum-neutral over the basket ----
function compute_bore(B, spy, Tr)
    N = size(B, 2); k = max(1, round(Int, N * 0.2)); mom = fill(NaN, Tr, N)
    for t in 253:Tr; mom[t, :] = vec(prod(1 .+ B[t-252:t-21, :], dims=1)) .- 1; end
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
        if sum(m) > 20 && var(x[m]) > 0; bore[t] = cut[t] - (cov(y[m], x[m]) / var(x[m])) * spy[t]; end
    end
    bore
end
function bore_weights_today(B, spy)                              # long/short weights (sum 0) + SPY beta hedge
    T, N = size(B); k = max(1, round(Int, N * 0.2)); t = T
    mom = vec(prod(1 .+ B[t-252:t-21, :], dims=1)) .- 1
    o = sortperm(mom); w = zeros(N); w[o[end-k+1:end]] .= 1/k; w .-= 1/N
    cut = fill(NaN, T); mm = fill(NaN, T, N); ww = zeros(N)      # recompute the monthly cut for the beta
    for tt in 253:T; mm[tt, :] = vec(prod(1 .+ B[tt-252:tt-21, :], dims=1)) .- 1; end
    for tt in 253:T-1
        if (tt - 253) % 21 == 0; oo = sortperm(mm[tt, :]); ww = zeros(N); ww[oo[end-k+1:end]] .= 1/k; ww .-= 1/N; end
        cut[tt+1] = dot(ww, B[tt+1, :])
    end
    y = cut[max(1, t-59):t]; x = spy[max(1, t-59):t]; m = .!isnan.(y)
    beta = (sum(m) > 20 && var(x[m]) > 0) ? cov(y[m], x[m]) / var(x[m]) : 0.0
    w, beta
end

# ---- TREND: vol-scaled multi-horizon trend over the spine ----
function compute_trend(B, Tr)
    N = size(B, 2); sv = ewma_vol(B, 32); horizons = (63, 126, 252); tr = fill(NaN, Tr)
    for t in 253:Tr-1
        strength = zeros(N)
        for h in horizons; strength .+= sign.(vec(prod(1 .+ B[t-h+1:t, :], dims=1)) .- 1); end
        strength ./= length(horizons)
        raw = strength ./ (sv[t, :] .* sqrt(252) .+ 1e-12); g = sum(abs.(raw))
        w = g > 0 ? raw ./ g : zeros(N); tr[t+1] = dot(w, B[t+1, :])
    end
    tr
end
function trend_weights_today(B)                                 # gross-1 signed weights at the last bar
    T, N = size(B); sv = ewma_vol(B, 32); horizons = (63, 126, 252); t = T
    strength = zeros(N); for h in horizons; strength .+= sign.(vec(prod(1 .+ B[t-h+1:t, :], dims=1)) .- 1); end
    strength ./= length(horizons); raw = strength ./ (sv[t, :] .* sqrt(252) .+ 1e-12)
    g = sum(abs.(raw)); g > 0 ? raw ./ g : zeros(N)
end

# ---- CAMPROT / DDBOUNCE / REGIME / BARBELL / CURVEBALL (series only; used by the research build) ----
function compute_camprot(brown, blue, Tr)
    lb = cumprod(1 .+ brown); lu = cumprod(1 .+ blue); cr = fill(NaN, Tr)
    for t in 127:Tr-1; cr[t+1] = (lb[t]/lb[t-126]-1) >= (lu[t]/lu[t-126]-1) ? brown[t+1] : blue[t+1]; end
    cr
end
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
function compute_regime(spy, bil, Tr; thr=-0.08)
    lvl = cumprod(1 .+ spy); peak = copy(lvl); for t in 2:Tr; peak[t] = max(peak[t-1], lvl[t]); end
    reg = fill(NaN, Tr); for t in 2:Tr; reg[t] = (lvl[t-1]/peak[t-1] - 1) < thr ? bil[t] : spy[t]; end; reg
end
function compute_barbell(bil, vixy, rdates, Tr; wsafe=0.9)
    port = zeros(Tr); sub = [wsafe, 1-wsafe]; V = 1.0
    for t in 1:Tr
        sub = sub .* (1 .+ [bil[t], vixy[t]]); nV = sum(sub); port[t] = nV/V - 1; V = nV
        if t < Tr && rdates[t+1][1:7] != rdates[t][1:7]; sub = [wsafe, 1-wsafe] .* V; end
    end
    port
end
function compute_curveball(bil, vixy, spy, Tr)
    rv = fill(NaN, Tr); for t in 21:Tr; rv[t] = std(spy[t-20:t]) * sqrt(252); end
    pct = fill(0.5, Tr); for t in 272:Tr; pct[t] = mean(rv[t-251:t] .<= rv[t]); end
    port = zeros(Tr); V = 1.0
    for t in 1:Tr
        tgt = (t >= 272 && pct[t] < 0.33) ? [0.1, 0.9] : [1.0, 0.0]
        sub = tgt .* V; sub = sub .* (1 .+ [bil[t], vixy[t]]); nV = sum(sub); port[t] = nV/V - 1; V = nV
    end
    port
end
