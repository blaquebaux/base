# =============================================================================
# robust.jl — Monte Carlo tools for the estimation-error problem
#
# Point estimates of μ and Σ are noisy, and mean–variance is notoriously eager
# to overfit that noise. `resampled_frontier` averages the optimizer over many
# resampled inputs (Michaud); the resampling distribution is a pluggable
# data-generating process so you are not locked into a thin-tailed Gaussian.
# =============================================================================

# -----------------------------------------------------------------------------
# Data-generating processes (DGPs) for resampling
#
# Each constructor returns a closure `(R, T_sim) -> (T_sim x N)` simulated
# return matrix. Pass one as the `sampler` keyword to `resampled_frontier`.
# -----------------------------------------------------------------------------

"""
    gaussian_dgp()

Draw from `N(μ̂, Σ̂)` fit to the data. The thin-tailed baseline (original
Michaud). Understates tail co-movement — fine for broad equity sleeves, wrong
for anything with fat tails.
"""
function gaussian_dgp()
    return (R, T_sim) -> begin
        μ = vec(mean(R, dims = 1))
        Σ = Matrix(nearest_psd(cov(R)))
        permutedims(rand(MvNormal(μ, Σ), T_sim))
    end
end

"""
    iid_bootstrap()

Resample whole rows with replacement. Fully nonparametric: keeps each asset's
empirical (fat-tailed) marginal and the cross-sectional dependence exactly;
discards serial dependence.
"""
iid_bootstrap() = (R, T_sim) -> R[rand(1:size(R, 1), T_sim), :]

"""
    block_bootstrap(; block=21)

Circular block bootstrap with fixed block length `block`. Like the IID bootstrap
but also preserves within-block serial dependence (volatility clustering,
short-horizon autocorrelation). No distributional assumption at all.
"""
function block_bootstrap(; block::Int = 21)
    return (R, T_sim) -> begin
        T, N = size(R)
        out = Matrix{eltype(R)}(undef, T_sim, N)
        i = 1
        while i <= T_sim
            start = rand(1:T)
            for k in 0:(block - 1)
                i > T_sim && break
                out[i, :] = @view R[mod1(start + k, T), :]
                i += 1
            end
        end
        out
    end
end

"""
    stationary_bootstrap(; meanblock=21)

Politis–Romano stationary bootstrap: geometric block lengths with mean
`meanblock`. The robust default when the serial-dependence structure is unknown,
since it does not impose a single block size.
"""
function stationary_bootstrap(; meanblock::Int = 21)
    p = 1 / meanblock
    return (R, T_sim) -> begin
        T, N = size(R)
        out = Matrix{eltype(R)}(undef, T_sim, N)
        idx = rand(1:T)
        for i in 1:T_sim
            out[i, :] = @view R[idx, :]
            idx = rand() < p ? rand(1:T) : mod1(idx + 1, T)
        end
        out
    end
end

"""
    student_t_dgp(; ν=5.0)

Multivariate Student-t with `ν` degrees of freedom, scaled so the simulated
covariance matches `Σ̂`. Elliptical fat tails — heavier joint extremes than
Gaussian, controlled by ν (smaller ν ⇒ fatter). Requires ν > 2.
"""
function student_t_dgp(; ν::Real = 5.0)
    ν > 2 || error("need ν > 2 for a finite covariance")
    return (R, T_sim) -> begin
        μ = vec(mean(R, dims = 1))
        C = Matrix(nearest_psd(cov(R)))
        scale = C .* ((ν - 2) / ν)            # so Cov(MvT) = ν/(ν-2)·scale = C
        permutedims(rand(MvTDist(ν, μ, scale), T_sim))
    end
end

"""
    t_copula_dgp(; ν=5.0)

t-copula dependence glued to the **empirical marginals**. The copula correlation
is recovered from Kendall's τ (`ρ = sin(πτ/2)`, robust to the marginals); each
draw shares one χ²(ν) mixing variable, producing joint tail dependence; the
resulting uniforms are mapped back through each asset's inverse empirical CDF.

This is the fat-tailed, tail-dependent generator that matches the t-copula
assumptions in the crypto sleeve: it preserves every asset's realized return
distribution (skew, kurtosis, jumps) while injecting co-crashing behavior the
Gaussian and even the elliptical-t DGPs miss.
"""
function t_copula_dgp(; ν::Real = 5.0)
    return (R, T_sim) -> begin
        T, N = size(R)
        τ = corkendall(R)
        P = cov2cor(Matrix(nearest_psd(sin.((π / 2) .* τ))))   # PD correlation, unit diag
        L = cholesky(Symmetric(P)).L
        td = TDist(ν)
        cols = [sort(R[:, j]) for j in 1:N]                    # empirical quantile grids
        out = Matrix{Float64}(undef, T_sim, N)
        for i in 1:T_sim
            z = L * randn(N)
            g = rand(Chisq(ν))
            tvec = z .* sqrt(ν / g)                            # multivariate-t latent
            @inbounds for j in 1:N
                u = cdf(td, tvec[j])                           # → uniform (t-copula)
                out[i, j] = quantile(cols[j], u; sorted = true)
            end
        end
        out
    end
end

# -----------------------------------------------------------------------------
# Feasible-set Monte Carlo
# -----------------------------------------------------------------------------

"""
    random_portfolios(μ, Σ; n=10_000, long_only=true, ppy=252) -> NamedTuple

Sample `n` random fully-invested portfolios and return their annualized
`(returns, risks)` plus the best Sharpe weight vector found. Long-only samples
are drawn uniformly on the simplex (Dirichlet); otherwise from a normalized
standard normal. Handy as a feasible-set backdrop behind an efficient frontier
and as a coarse check that the optimizer sits on the upper envelope.
"""
function random_portfolios(μ::AbstractVector, Σ::AbstractMatrix; n::Int = 10_000,
                           long_only::Bool = true, ppy::Int = 252)
    N = length(μ)
    A = Matrix(nearest_psd(Σ))
    rets = zeros(n); risks = zeros(n)
    best_sharpe = -Inf; best_w = fill(1 / N, N)
    dir = Dirichlet(ones(N))
    for k in 1:n
        w = long_only ? rand(dir) : (g = randn(N); g ./ sum(g))
        r = dot(μ, w) * ppy
        v = sqrt(max(dot(w, A * w), 0)) * sqrt(ppy)
        rets[k] = r; risks[k] = v
        s = v == 0 ? -Inf : r / v
        if s > best_sharpe
            best_sharpe = s; best_w = w
        end
    end
    return (; returns = rets, risks = risks, best_sharpe_weights = best_w)
end

# -----------------------------------------------------------------------------
# Resampled (Michaud) efficient frontier
# -----------------------------------------------------------------------------

"""
    resampled_frontier(R; n_resample=100, n_points=25, T_sim=size(R,1),
                       sampler=gaussian_dgp(), estimator=default, α=0.95,
                       long_only=true, w_min=nothing, w_max=nothing,
                       optimizer=Clarabel.Optimizer) -> NamedTuple

Resampled efficient frontier. For each of `n_resample` draws: simulate `T_sim`
returns from `sampler`, re-estimate moments with `estimator`, and trace an
`n_points` efficient frontier. Averaging the weight vectors at each frontier
*rank* yields weights far steadier — and usually more diversified — than the
single-sample frontier.

The `sampler` is the resampling DGP (see `gaussian_dgp`, `iid_bootstrap`,
`block_bootstrap`, `stationary_bootstrap`, `student_t_dgp`, `t_copula_dgp`).
Choosing a fat-tailed DGP makes the averaged weights robust to the tail behavior
that actually shows up out of sample, not just to Gaussian sampling noise.

Output `(; weights, returns, risks, cvars)`: `returns`/`risks` evaluate the
averaged weights under the original `estimator` moments (comparable to
`efficient_frontier`), while `cvars` is the **historical** Expected Shortfall of
each averaged portfolio on `R` — the tail-aware risk number to read alongside
the Gaussian volatility. Solves `n_resample × n_points` QPs, so keep defaults
modest while iterating.
"""
function resampled_frontier(R::AbstractMatrix; n_resample::Int = 100,
                            n_points::Int = 25, T_sim::Int = size(R, 1),
                            sampler = gaussian_dgp(),
                            estimator = X -> (mean_returns(X), shrinkage_cov(X)[1]),
                            α::Real = 0.95, long_only::Bool = true,
                            w_min = nothing, w_max = nothing,
                            optimizer = Clarabel.Optimizer)
    μ0, Σ0 = estimator(R)
    N = length(μ0)
    Σ0psd = Matrix(nearest_psd(Σ0))

    Wsum = zeros(N, n_points)
    for _ in 1:n_resample
        Xb = sampler(R, T_sim)
        μb, Σb = estimator(Xb)
        ef = efficient_frontier(μb, Σb; n = n_points, long_only, w_min, w_max, optimizer)
        Wsum .+= ef.weights
    end
    W = Wsum ./ n_resample

    rets  = [dot(μ0, view(W, :, k)) for k in 1:n_points]
    risks = [sqrt(max(dot(view(W, :, k), Σ0psd * view(W, :, k)), 0)) for k in 1:n_points]
    cvars = [expected_shortfall(R * view(W, :, k); α = α) for k in 1:n_points]
    return (; weights = W, returns = rets, risks = risks, cvars = cvars)
end
