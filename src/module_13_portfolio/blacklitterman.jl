# =============================================================================
# blacklitterman.jl — equilibrium-anchored return blending
# =============================================================================

"""
    implied_equilibrium_returns(Σ, w_mkt; δ=2.5) -> Vector

Reverse-optimize the CAPM-implied excess returns `Π = δ Σ w_mkt` from market-cap
weights `w_mkt` and a risk-aversion coefficient `δ`. These serve as the
Black–Litterman prior mean.
"""
implied_equilibrium_returns(Σ::AbstractMatrix, w_mkt::AbstractVector; δ::Real = 2.5) =
    δ .* (Matrix(Σ) * w_mkt)

"""
    black_litterman(Σ, Π, P, Q; Ω=nothing, τ=0.05) -> (μ_bl, Σ_bl)

Black–Litterman posterior. Inputs:

- `Π`  — prior (equilibrium) excess returns, length `N`.
- `P`  — `K x N` view "picking" matrix; each row selects the assets in a view.
- `Q`  — length-`K` vector of view-implied returns.
- `Ω`  — `K x K` view-uncertainty covariance. Defaults to He–Litterman's
         `diag(P (τΣ) Pᵀ)`, i.e. view confidence proportional to prior variance.
- `τ`  — scalar scaling the prior covariance (typically 0.01–0.05).

Returns the posterior mean and covariance

    μ_bl = M⁻¹ [ (τΣ)⁻¹ Π + Pᵀ Ω⁻¹ Q ],   M = (τΣ)⁻¹ + Pᵀ Ω⁻¹ P,   Σ_bl = M⁻¹.

Feed `μ_bl` (and optionally `Σ + Σ_bl`) into any mean-variance optimizer.
"""
function black_litterman(Σ::AbstractMatrix, Π::AbstractVector,
                         P::AbstractMatrix, Q::AbstractVector;
                         Ω = nothing, τ::Real = 0.05)
    τΣ = τ .* Matrix(Σ)
    Ωm = Ω === nothing ? Diagonal(diag(P * τΣ * P')) : Matrix(Ω)
    inv_τΣ = inv(Symmetric((τΣ + τΣ') / 2))
    inv_Ω = inv(Symmetric((Matrix(Ωm) + Matrix(Ωm)') / 2))
    M = inv_τΣ .+ P' * inv_Ω * P
    Minv = inv(Symmetric((M + M') / 2))
    μ_bl = Minv * (inv_τΣ * Π .+ P' * inv_Ω * Q)
    return μ_bl, Symmetric((Minv + Minv') / 2)
end

"""
    make_view(N, assets, q; weights=nothing) -> (P_row, q)

Helper to build one Black–Litterman view row over `N` assets.

- Absolute view ("asset 3 returns 4%"): `make_view(N, [3], 0.04)`.
- Relative view ("asset 1 outperforms asset 2 by 2%"):
  `make_view(N, [1, 2], 0.02; weights=[1.0, -1.0])`.
"""
function make_view(N::Int, assets::AbstractVector{<:Integer}, q::Real;
                   weights = nothing)
    row = zeros(N)
    wv = weights === nothing ? fill(1.0, length(assets)) : collect(weights)
    for (a, wi) in zip(assets, wv)
        row[a] = wi
    end
    return row, float(q)
end
