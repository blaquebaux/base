# =============================================================================
# riskbased.jl — allocations driven by risk structure rather than return forecasts
# =============================================================================

"""
    max_diversification(Σ; long_only=true, w_min=nothing, w_max=nothing,
                        optimizer=Clarabel.Optimizer) -> Vector

Most-diversified portfolio (Choueifaty–Coignard): maximize the diversification
ratio `(wᵀσ) / √(wᵀΣw)` where `σ` are asset volatilities. Solved by the same
scale-free reformulation used for the tangency portfolio, substituting `σ` for
expected returns.
"""
function max_diversification(Σ::AbstractMatrix; long_only::Bool = true,
                             w_min = nothing, w_max = nothing,
                             optimizer = Clarabel.Optimizer)
    N = size(Σ, 1)
    σ = sqrt.(diag(Σ))
    A = _psd(Σ)
    model = Model(optimizer); set_silent(model)
    @variable(model, y[1:N])
    long_only && @constraint(model, y .>= 0)
    @constraint(model, dot(σ, y) == 1)
    if w_min !== nothing || w_max !== nothing
        @variable(model, κ >= 1e-8)
        @constraint(model, sum(y) == κ)
        w_min !== nothing && @constraint(model, y .>= (w_min isa Number ? fill(float(w_min), N) : collect(w_min)) .* κ)
        w_max !== nothing && @constraint(model, y .<= (w_max isa Number ? fill(float(w_max), N) : collect(w_max)) .* κ)
    end
    @objective(model, Min, y' * A * y)
    optimize!(model); _check(model)
    yv = value.(y)
    return yv ./ sum(yv)
end

"""
    risk_contributions(w, Σ) -> Vector

Marginal-times-weight risk contributions `wᵢ·(Σw)ᵢ / √(wᵀΣw)`. They sum to the
portfolio volatility, so `rc ./ sum(rc)` gives each asset's share of total risk.
"""
function risk_contributions(w::AbstractVector, Σ::AbstractMatrix)
    Σw = Symmetric(Matrix(Σ)) * w
    vol = sqrt(max(dot(w, Σw), 0))
    return (w .* Σw) ./ vol
end

"""
    risk_parity(Σ; budget=nothing, maxiter=10_000, tol=1e-10) -> Vector

Equal-risk-contribution portfolio (long-only) via cyclical coordinate descent on
the convex problem `min ½wᵀΣw − Σ bᵢ log wᵢ`. `budget` is an optional vector of
target risk shares (defaults to equal); the result is normalized to sum to 1.

Solver-free and numerically robust, which is convenient inside a backtest loop.
"""
function risk_parity(Σ::AbstractMatrix; budget = nothing,
                     maxiter::Int = 10_000, tol::Real = 1e-10)
    N = size(Σ, 1)
    b = budget === nothing ? fill(1 / N, N) : collect(budget) ./ sum(budget)
    A = Matrix(Symmetric((Matrix(Σ) + Matrix(Σ)') / 2))
    w = ones(N) ./ N
    for _ in 1:maxiter
        wprev = copy(w)
        @inbounds for i in 1:N
            # solve aᵢᵢ wᵢ² + (Σ_{j≠i} aᵢⱼ wⱼ) wᵢ − bᵢ = 0 for wᵢ > 0
            cross = dot(view(A, i, :), w) - A[i, i] * w[i]
            a = A[i, i]
            w[i] = (-cross + sqrt(cross^2 + 4 * a * b[i])) / (2 * a)
        end
        maximum(abs.(w .- wprev)) < tol && break
    end
    return w ./ sum(w)
end

# Inverse-variance "risk" of a cluster, used by HRP's recursive bisection.
function _cluster_var(Σ::AbstractMatrix, idx::Vector{Int})
    sub = Matrix(Σ)[idx, idx]
    ivp = 1 ./ diag(sub)
    ivp ./= sum(ivp)
    return dot(ivp, sub * ivp)
end

"""
    hrp_weights(Σ; linkage=:single) -> Vector

Hierarchical Risk Parity (López de Prado, 2016): cluster assets on a
correlation-distance metric, quasi-diagonalize using the dendrogram leaf order,
then split risk top-down by inverse cluster variance. Needs no return forecasts
and no matrix inversion, so it stays well-behaved when `N` is large relative to
the sample length. `linkage` is passed through to `Clustering.hclust`.
"""
function hrp_weights(Σ::AbstractMatrix; linkage::Symbol = :single)
    N = size(Σ, 1)
    σ = sqrt.(diag(Σ))
    corr = Matrix(Σ) ./ (σ * σ')
    dist = sqrt.(clamp.((1 .- corr) ./ 2, 0, 1))      # correlation distance
    hc = hclust(dist; linkage = linkage)
    order = hc.order                                  # quasi-diagonal leaf ordering

    w = ones(N)
    clusters = [order]
    while !isempty(clusters)
        nxt = Vector{Vector{Int}}()
        for cl in clusters
            length(cl) <= 1 && continue
            half = div(length(cl), 2)
            c1, c2 = cl[1:half], cl[half+1:end]
            v1, v2 = _cluster_var(Σ, c1), _cluster_var(Σ, c2)
            α = 1 - v1 / (v1 + v2)
            w[c1] .*= α
            w[c2] .*= (1 - α)
            push!(nxt, c1); push!(nxt, c2)
        end
        clusters = nxt
    end
    return w ./ sum(w)
end

"""
    inverse_variance(Σ) -> Vector

Naive risk parity: weights proportional to `1/σᵢ²`, ignoring correlations.
A cheap baseline and the within-leaf rule HRP reduces to.
"""
function inverse_variance(Σ::AbstractMatrix)
    iv = 1 ./ diag(Σ)
    return iv ./ sum(iv)
end
