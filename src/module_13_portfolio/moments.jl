# =============================================================================
# moments.jl — return transforms and moment estimation
#
# Convention used throughout the package: a return matrix `R` is T x N,
# rows are observations (time), columns are assets.
# =============================================================================

"""
    simple_returns(prices) -> Matrix

Period-over-period simple returns from a `T x N` price matrix (or `T`-vector).
Output has `T-1` rows.
"""
function simple_returns(prices::AbstractMatrix)
    P = prices
    return P[2:end, :] ./ P[1:end-1, :] .- 1
end
simple_returns(p::AbstractVector) = vec(simple_returns(reshape(p, :, 1)))

"""
    log_returns(prices) -> Matrix

Continuously-compounded (log) returns from a price matrix or vector.
"""
function log_returns(prices::AbstractMatrix)
    return log.(prices[2:end, :] ./ prices[1:end-1, :])
end
log_returns(p::AbstractVector) = vec(log_returns(reshape(p, :, 1)))

# -----------------------------------------------------------------------------
# Mean estimation
# -----------------------------------------------------------------------------

"""
    mean_returns(R; method=:sample, halflife=nothing) -> Vector

Per-asset mean return.

- `:sample`  — arithmetic mean of each column.
- `:ewma`    — exponentially weighted mean; supply `halflife` (in periods).
"""
function mean_returns(R::AbstractMatrix; method::Symbol = :sample, halflife = nothing)
    T, N = size(R)
    if method === :sample
        return vec(mean(R, dims = 1))
    elseif method === :ewma
        halflife === nothing && error("`halflife` is required for :ewma means")
        λ = 0.5^(1 / halflife)                      # decay per step
        w = λ .^ collect(T-1:-1:0)                  # most-recent obs gets weight 1
        w ./= sum(w)
        return vec(w' * R)
    else
        error("unknown mean method $method")
    end
end

# -----------------------------------------------------------------------------
# Covariance estimation
# -----------------------------------------------------------------------------

"""
    sample_cov(R) -> Symmetric

Unbiased (`1/(T-1)`) sample covariance.
"""
sample_cov(R::AbstractMatrix) = Symmetric(cov(R))

"""
    ewma_cov(R; halflife) -> Symmetric

Exponentially weighted covariance (RiskMetrics-style). More recent observations
receive more weight; `halflife` is expressed in periods.
"""
function ewma_cov(R::AbstractMatrix; halflife::Real)
    T, N = size(R)
    λ = 0.5^(1 / halflife)
    w = λ .^ collect(T-1:-1:0)
    w ./= sum(w)
    μ = vec(w' * R)
    Xc = R .- μ'
    Σ = (Xc .* w)' * Xc                              # weighted cross products
    return Symmetric((Σ + Σ') / 2)
end

"""
    shrinkage_cov(R; target=:constant_correlation, delta=nothing) -> (Σ, δ)

Linear shrinkage covariance estimator. Returns the shrunk covariance and the
shrinkage intensity actually used.

- `target = :constant_correlation` implements the analytic optimal intensity of
  Ledoit & Wolf (2003), "Honey, I shrunk the sample covariance matrix", whose
  target preserves the sample variances and imposes the average sample
  correlation across all off-diagonal pairs.
- `target = :identity` shrinks toward a scaled identity (average-variance
  diagonal); supply `delta` in `[0,1]` or let it default to a mild 0.1.

Pass `delta` explicitly to override the analytic intensity for either target.
"""
function shrinkage_cov(R::AbstractMatrix; target::Symbol = :constant_correlation,
                       delta = nothing)
    T, N = size(R)
    Xc = R .- mean(R, dims = 1)
    S = (Xc' * Xc) / T                               # MLE (1/T) sample cov
    s = diag(S)
    sd = sqrt.(s)

    if target === :identity
        F = Diagonal(fill(mean(s), N))
        δ = delta === nothing ? 0.1 : clamp(delta, 0, 1)
        Σ = δ .* Matrix(F) .+ (1 - δ) .* S
        return Symmetric((Σ + Σ') / 2), δ

    elseif target === :constant_correlation
        # constant-correlation target F
        corr = S ./ (sd * sd')
        rbar = (sum(corr) - N) / (N * (N - 1))       # mean off-diagonal correlation
        F = rbar .* (sd * sd')
        F[diagind(F)] .= s

        if delta !== nothing
            δ = clamp(delta, 0, 1)
            Σ = δ .* F .+ (1 - δ) .* S
            return Symmetric((Σ + Σ') / 2), δ
        end

        # π̂ : sum of asymptotic variances of the sample covariance entries
        X2 = Xc .^ 2
        piMat = (X2' * X2) / T .- S .^ 2
        pihat = sum(piMat)

        # ρ̂ : covariances between target and sample covariance entries
        # diagonal contribution
        rho_diag = sum(diag(piMat))
        # off-diagonal contribution via A[i,j] = (1/T) Σ_t Xc_ti^3 Xc_tj
        A = ((Xc .^ 3)' * Xc) / T
        rho_off = 0.0
        @inbounds for i in 1:N, j in 1:N
            i == j && continue
            theta_ii = A[i, j] - s[i] * S[i, j]      # ϑ_{ii,ij}
            theta_jj = A[j, i] - s[j] * S[i, j]      # ϑ_{jj,ij}
            rho_off += (rbar / 2) *
                       (sqrt(s[j] / s[i]) * theta_ii + sqrt(s[i] / s[j]) * theta_jj)
        end
        rhohat = rho_diag + rho_off

        # γ̂ : misspecification of the target
        gammahat = sum((F .- S) .^ 2)

        kappa = (pihat - rhohat) / gammahat
        δ = clamp(kappa / T, 0, 1)
        Σ = δ .* F .+ (1 - δ) .* S
        return Symmetric((Σ + Σ') / 2), δ
    else
        error("unknown shrinkage target $target")
    end
end

"""
    cov2cor(Σ) -> Matrix

Convert a covariance matrix to a correlation matrix.
"""
function cov2cor(Σ::AbstractMatrix)
    d = sqrt.(diag(Σ))
    return Matrix(Σ) ./ (d * d')
end

"""
    nearest_psd(Σ; eps=1e-10) -> Symmetric

Project a symmetric matrix onto the PSD cone by flooring its eigenvalues. Useful
when an estimated/edited covariance has tiny negative eigenvalues.
"""
function nearest_psd(Σ::AbstractMatrix; eps::Real = 1e-10)
    A = Symmetric((Matrix(Σ) + Matrix(Σ)') / 2)
    vals, vecs = eigen(A)
    vals = max.(vals, eps)
    B = vecs * Diagonal(vals) * vecs'
    return Symmetric((B + B') / 2)
end
