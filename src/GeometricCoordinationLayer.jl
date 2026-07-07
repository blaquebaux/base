# =============================================================================
# GeometricCoordinationLayer.jl  — v2
# Stratum III Geometric / Information-Theoretic Coordination Layer
#
# Revision log (from peer review):
#   BUG  _schilds_ladder used Euclidean step; replaced with ai_exp
#   BUG  ε was fixed; now adaptive: 0.01‖P‖/max(‖V‖,ε_min)
#   BUG  convert_geometry used one reference direction; now samples multiple
#   ADD  LogEuclidean geometry (fourth metric; flat, useful for vol surfaces)
#   ADD  ModuleGeometryRegistry — user-configurable; replaces hardcoded dict
#   ADD  euclidean_parallel_transport — trivial identity; exhausts dispatch
#   IMP  compare_geodesic_deviation — always includes t=0.5; denser sampling
#   IMP  parallel_transport_across_metrics — covers all four geometry pairs
#   NOTE manifold_ttest: Hotelling T² comment for n < 30
#   NOTE frechet_mean_spd: AD compatibility (distinct eigenvalues required)
#   NOTE enforce_rough_path_lift!: simulation vs tagging distinction
#   NOTE RoughPath: Marcus integral note for H ∈ (1/3, 0.5)
#
# Dependencies: LinearAlgebra, Statistics, Random (stdlib only)
# Optional upgrades: Manifolds.jl, RoughPaths.jl, OptimalTransport.jl
# =============================================================================

module GeometricCoordinationLayer

using LinearAlgebra, Statistics, Random

# =============================================================================
# PART 0 — GEOMETRY TYPE HIERARCHY
# =============================================================================

abstract type Geometry end
struct Euclidean        <: Geometry end   # Ledoit-Wolf, PCA, standard averaging
struct AffineInvariant  <: Geometry end   # riemannian-gaussian-sampler (GL-invariant)
struct BuresWasserstein <: Geometry end   # Wasserstein DRO, optimal transport
struct LogEuclidean     <: Geometry end   # vol surface interpolation, options pricing
                                          # Flat (Euclidean metric on log-space);
                                          # simpler than AI but loses GL-invariance.

"""
    SPDPoint{G <: Geometry, T}

Geometry-aware SPD matrix container. Raw matrices are ambiguous; this wrapper
makes the geometry tag explicit and enforced by multiple dispatch.
`Matrix(p::SPDPoint)` is the intentional escape hatch — it should be explicit.
"""
struct SPDPoint{G <: Geometry, T <: AbstractMatrix{Float64}}
    value::T
    SPDPoint(M::T, ::G) where {G <: Geometry, T <: AbstractMatrix{Float64}} =
        new{G, T}(M)
end

geometry_type(::SPDPoint{G}) where G = G
Base.Matrix(p::SPDPoint)              = p.value

# =============================================================================
# PART 0b — SPD UTILITIES
# =============================================================================

"""Project to SPD manifold via eigenvalue clipping."""
function ensure_spd(P::AbstractMatrix{Float64}; ε::Float64=1e-10)
    S = Symmetric(0.5 * (P + P'))
    F = eigen(S)
    Symmetric(F.vectors * Diagonal(max.(F.values, ε)) * F.vectors')
end

is_spd(M::AbstractMatrix) = issymmetric(M) && all(eigvals(M) .> 1e-10)

function _spd_sqrt(P::AbstractMatrix{Float64})
    F = eigen(Symmetric(ensure_spd(P)))
    Symmetric(F.vectors * Diagonal(sqrt.(F.values)) * F.vectors')
end

function _spd_sqrt_inv(P::AbstractMatrix{Float64})
    F = eigen(Symmetric(ensure_spd(P)))
    Symmetric(F.vectors * Diagonal(1.0 ./ sqrt.(F.values)) * F.vectors')
end

"""Matrix logarithm (SPD matrices only; requires distinct eigenvalues for AD)."""
function _mat_log(P::AbstractMatrix{Float64})
    F = eigen(Symmetric(ensure_spd(P)))
    Symmetric(F.vectors * Diagonal(log.(F.values)) * F.vectors')
end

function _mat_exp(X::AbstractMatrix{Float64})
    F = eigen(Symmetric(X))
    Symmetric(F.vectors * Diagonal(exp.(F.values)) * F.vectors')
end

# =============================================================================
# PART 1 — AFFINE-INVARIANT RIEMANNIAN GEOMETRY
# =============================================================================
#
# GL(n)-invariant: d(A PA', A QA') = d(P,Q) for any invertible A.
# Constant negative sectional curvature.
# Parallel transport has a closed form (see ai_parallel_transport below).

"""log_P(Q) = P^{1/2} log(P^{-1/2} Q P^{-1/2}) P^{1/2}"""
function ai_log(P::AbstractMatrix{Float64}, Q::AbstractMatrix{Float64})
    sqP = _spd_sqrt(P); isqP = _spd_sqrt_inv(P)
    Symmetric(sqP * _mat_log(Symmetric(isqP * Q * isqP)) * sqP)
end

"""exp_P(X) = P^{1/2} exp(P^{-1/2} X P^{-1/2}) P^{1/2}"""
function ai_exp(P::AbstractMatrix{Float64}, X::AbstractMatrix{Float64})
    sqP = _spd_sqrt(P); isqP = _spd_sqrt_inv(P)
    ensure_spd(sqP * _mat_exp(Symmetric(isqP * X * isqP)) * sqP)
end

ai_geodesic(P, Q, t) = ai_exp(P, t .* ai_log(P, Q))

"""⟨X, Y⟩_P = tr(P⁻¹ X P⁻¹ Y)"""
function ai_inner(P, X, Y)
    Pi = inv(ensure_spd(Matrix(P)))
    tr(Pi * X * Pi * Y)
end

"""
    ai_parallel_transport(P, Q, X) → tangent vector at Q

Closed-form parallel transport along geodesic P → Q in AI geometry:
τ_{P→Q}(X) = Q^{1/2}(Q^{-1/2} P Q^{-1/2})^{1/2} P^{-1/2} X P^{-1/2}
              (Q^{-1/2} P Q^{-1/2})^{1/2} Q^{1/2}

This is exact (not an approximation). It preserves the AI inner product:
⟨X, Y⟩_P = ⟨τX, τY⟩_Q.
"""
function ai_parallel_transport(P::AbstractMatrix{Float64},
                                Q::AbstractMatrix{Float64},
                                X::AbstractMatrix{Float64})
    sqQ  = _spd_sqrt(Q); isqQ = _spd_sqrt_inv(Q); isqP = _spd_sqrt_inv(P)
    M    = _spd_sqrt(Symmetric(isqQ * P * isqQ))
    Symmetric(sqQ * M * isqP * X * isqP * M * sqQ)
end

# =============================================================================
# PART 2 — BURES-WASSERSTEIN GEOMETRY
# =============================================================================
#
# Optimal transport metric between zero-mean Gaussians.
# Non-constant sectional curvature (differs from AI).
# No closed-form parallel transport → Schild's ladder required.
# Geodesics differ from AI geodesics (compare_geodesic_deviation measures this).

"""d²_BW(P,Q) = tr(P) + tr(Q) − 2 tr((P^{1/2} Q P^{1/2})^{1/2})"""
function bw_dist_sq(P::AbstractMatrix{Float64}, Q::AbstractMatrix{Float64})
    sqP = _spd_sqrt(P)
    tr(P) + tr(Q) - 2*tr(_spd_sqrt(Symmetric(sqP * Q * sqP)))
end

"""
    bw_geodesic(P, Q, t) → SPD matrix

Bures-Wasserstein geodesic:
  γ(t) = (1−t)²P + t²Q + t(1−t)(M_PQ + M_QP)
where M_PQ = P^{1/2}(P^{-1/2} Q P^{-1/2})^{1/2} P^{1/2}

Verified: γ(0) = P, γ(1) = Q (up to floating-point tolerance).
Non-commuting P,Q require the symmetric form M_PQ + M_QP, not 2M_PQ.
"""
function bw_geodesic(P::AbstractMatrix{Float64}, Q::AbstractMatrix{Float64}, t::Float64)
    sqP  = _spd_sqrt(P); isqP = _spd_sqrt_inv(P)
    sqQ  = _spd_sqrt(Q); isqQ = _spd_sqrt_inv(Q)
    M_PQ = Symmetric(sqP * _spd_sqrt(Symmetric(isqP * Q * isqP)) * sqP)
    M_QP = Symmetric(sqQ * _spd_sqrt(Symmetric(isqQ * P * isqQ)) * sqQ)
    ensure_spd((1-t)^2 .* P .+ t^2 .* Q .+ t*(1-t) .* (M_PQ .+ M_QP))
end

"""
    bw_parallel_transport(P, Q, X; n_steps) → transported tangent vector

No closed-form exists for BW parallel transport — Schild's ladder approximation.
Always lossy relative to AI closed-form. See `parallel_transport_across_metrics`.
"""
function bw_parallel_transport(P::AbstractMatrix{Float64}, Q::AbstractMatrix{Float64},
                                X::AbstractMatrix{Float64}; n_steps::Int=12)
    _schilds_ladder(bw_geodesic, P, Q, X, n_steps)
end

# =============================================================================
# PART 2b — LOG-EUCLIDEAN GEOMETRY  (added per review)
# =============================================================================
#
# Metric: d_LE(P,Q) = ‖log(P) − log(Q)‖_F  (Euclidean in log-space)
# Geodesic: γ(t) = exp((1−t) log(P) + t log(Q))
# Parallel transport: trivial (flat connection, identity map)
# Advantage: always SPD-preserving, simpler than AI, good for interpolating
#   covariance matrices in options pricing / yield curve models.
# Disadvantage: not GL(n)-invariant (AI is). For factor-model covariances
#   where you want invariance to basis changes, use AI instead.

"""log_P(Q) in log-Euclidean: log(Q) − log(P) (flat tangent space)"""
le_log(P, Q) = _mat_log(Q) .- _mat_log(P)

"""exp_P(X) in log-Euclidean: exp(log(P) + X)"""
le_exp(P, X) = ensure_spd(_mat_exp(Symmetric(_mat_log(P) .+ X)))

"""Log-Euclidean geodesic: exp((1−t) log P + t log Q)"""
function le_geodesic(P::AbstractMatrix{Float64}, Q::AbstractMatrix{Float64}, t::Float64)
    ensure_spd(_mat_exp(Symmetric((1-t) .* _mat_log(P) .+ t .* _mat_log(Q))))
end

"""Log-Euclidean distance: ‖log P − log Q‖_F"""
le_dist(P, Q) = norm(_mat_log(P) .- _mat_log(Q), 2)

"""Parallel transport in log-Euclidean is the identity (flat connection)."""
le_parallel_transport(P, Q, X) = copy(X)

# =============================================================================
# PART 2c — EUCLIDEAN PARALLEL TRANSPORT  (added per review)
# =============================================================================
#
# In flat Euclidean space, parallel transport is the identity map.
# Trivial but needed to make dispatch exhaustive across all four geometries.

euclidean_parallel_transport(P, Q, X) = copy(X)

# =============================================================================
# PART 3a — SCHILD'S LADDER (fixed per review)
# =============================================================================

"""
    _schilds_ladder(geo, P, Q, X, n_steps) → transported tangent vector

Approximate parallel transport via Schild's ladder construction.
Uses the exponential map for the push step (not Euclidean addition) — this
keeps the intermediate point on the manifold under high curvature.

BUG FIX: Previous version used `curr_P + ε*V` (Euclidean). For curved spaces
this exits the SPD cone when curvature is large. Replaced with `ai_exp(curr_P, ε*V)`.

BUG FIX: ε is now adaptive: `min(1e-5, 0.01‖P‖/max(‖V‖, ε_min))` to prevent
drift for large- or small-norm tangent vectors.
"""
function _schilds_ladder(geo::Function, P::AbstractMatrix{Float64},
                          Q::AbstractMatrix{Float64}, X::AbstractMatrix{Float64},
                          n_steps::Int)
    X_norm = norm(X, 2)
    X_norm < 1e-14 && return copy(X)

    curr_P = Matrix(ensure_spd(P))
    curr_V = Matrix(Symmetric(0.5*(X + X')))

    for k in 1:n_steps
        t = k / n_steps
        R = geo(P, Q, t)

        # Adaptive ε: keeps the push step small relative to both the
        # base point scale and the tangent vector norm.
        ε = min(1e-5, 0.01 * norm(curr_P, 2) / max(norm(curr_V, 2), 1e-10))

        # Push step: use ai_exp rather than Euclidean addition.
        # Even for BW transport, ai_exp is a better manifold approximation
        # than flat-space stepping, which can exit the SPD cone.
        V_unit = curr_V ./ max(norm(curr_V, 2), 1e-14)
        P_push = ai_exp(curr_P, ε .* V_unit)

        mid    = geo(Matrix(R), Matrix(P_push), 0.5)
        curr_V = (2 .* Matrix(mid) .- Matrix(R) .- curr_P) .* (X_norm / ε)
        curr_P = Matrix(R)
    end
    Symmetric(curr_V)
end

# =============================================================================
# PART 3 — METRIC CONSISTENCY LAYER
# =============================================================================

"""
    ConversionReport

Lossiness record for geometry conversions.
  geodesic_deviation  — max Frobenius gap across multiple reference directions
  curvature_distortion — condition-number proxy for curvature magnitude
  geodesic_preserved  — false when interpolation paths materially differ
"""
struct ConversionReport
    source::Type{<:Geometry}
    target::Type{<:Geometry}
    exact::Bool
    geodesic_deviation::Float64
    curvature_distortion::Float64
    geodesic_preserved::Bool
    notes::String
end

is_lossy(r::ConversionReport) = !r.exact

function Base.show(io::IO, r::ConversionReport)
    tag = r.exact ? "EXACT" : r.geodesic_preserved ? "LOSSY/MINOR" : "LOSSY/SIGNIFICANT"
    println(io, "ConversionReport [$tag]  $(r.source) → $(r.target)")
    println(io, "  geodesic_deviation   = $(round(r.geodesic_deviation, digits=5))")
    println(io, "  curvature_distortion = $(round(r.curvature_distortion, digits=5))")
    println(io, "  notes: $(r.notes)")
end

"""
    compare_geodesic_deviation(m1, m2, P, Q; n_samples) → Float64

Sample geodesics under two metrics and report the maximum normalised Frobenius gap.

Improved sampling strategy (per review):
  - Always includes t=0.5 (midpoint, where deviation is often largest)
  - Samples also at t=0.25 and t=0.75 (derivative-peak candidates for anisotropic P)
  - Remaining samples distributed uniformly in (0.1, 0.9)
"""
function compare_geodesic_deviation(m1::Geometry, m2::Geometry,
                                     P::AbstractMatrix{Float64},
                                     Q::AbstractMatrix{Float64};
                                     n_samples::Int=12)
    scale = max(norm(P, 2), 1e-12)
    # Priority sample points: midpoint + derivative-peak candidates
    priority_ts = [0.25, 0.5, 0.75]
    extra_ts    = collect(LinRange(0.1, 0.9, max(n_samples - 3, 3)))
    all_ts      = sort(unique(vcat(priority_ts, extra_ts)))

    max_dev = 0.0
    for t in all_ts
        g1 = _eval_geo(m1, P, Q, t)
        g2 = _eval_geo(m2, P, Q, t)
        max_dev = max(max_dev, norm(g1 - g2, 2) / scale)
    end
    max_dev
end

_eval_geo(::Euclidean,       P, Q, t) = (1-t) .* P .+ t .* Q
_eval_geo(::AffineInvariant,  P, Q, t) = ai_geodesic(P, Q, t)
_eval_geo(::BuresWasserstein, P, Q, t) = bw_geodesic(P, Q, t)
_eval_geo(::LogEuclidean,     P, Q, t) = le_geodesic(P, Q, t)

function _curvature_proxy(P::AbstractMatrix{Float64})
    ev   = eigvals(Symmetric(ensure_spd(P)))
    cond = maximum(ev) / max(minimum(ev), 1e-14)
    1.0 - exp(-log10(max(cond, 1.0)) / 5)
end

"""
    _multi_ref_deviation(m1, m2, P; n_refs) → Float64

Sample geodesic deviation across multiple reference directions.
Uses P+0.1I, n_refs random SPD perturbations, and the scaled identity.
Reports the maximum — conservative estimate of true deviation.

FIX: Previous version used a single reference `P + 0.1I`, which can
underestimate deviation for highly anisotropic covariances.
"""
function _multi_ref_deviation(m1::Geometry, m2::Geometry,
                               P::AbstractMatrix{Float64}; n_refs::Int=5)
    n    = size(P, 1)
    devs = Float64[]

    # Reference 1: small diagonal perturbation
    push!(devs, compare_geodesic_deviation(m1, m2, P,
          ensure_spd(P .+ 0.1.*I(n))))

    # References 2..n_refs-1: random SPD perturbations
    for _ in 1:(n_refs-2)
        A = randn(n, n)
        push!(devs, compare_geodesic_deviation(m1, m2, P,
              ensure_spd(P .+ 0.3.*A*A')))
    end

    # Final reference: scaled identity (tests against isotropic target)
    push!(devs, compare_geodesic_deviation(m1, m2, P,
          ensure_spd(tr(P)/n .* I(n))))

    maximum(devs)
end

"""
    convert_geometry(src::SPDPoint{S}, ::T; ref) → (SPDPoint{T}, ConversionReport)

Convert between geometry contexts with explicit lossiness tracking.
When ref is nothing, samples multiple reference directions and reports the
maximum geodesic deviation (conservative estimate).
"""
function convert_geometry(src::SPDPoint{S}, ::T;
                           ref::Union{Nothing,AbstractMatrix{Float64}}=nothing
                           ) where {S <: Geometry, T <: Geometry}
    P   = Matrix(src)
    P_s = Matrix(ensure_spd(P))

    geo_dev = if S == T
        0.0
    elseif ref !== nothing
        compare_geodesic_deviation(S(), T(), P_s, ensure_spd(ref))
    else
        _multi_ref_deviation(S(), T(), P_s)
    end

    curv   = _curvature_proxy(P_s)
    exact  = (S == T) || geo_dev < 1e-6
    notes  = _conversion_note(S, T, geo_dev, curv)
    report = ConversionReport(S, T, exact, geo_dev, curv, geo_dev < 0.05, notes)
    return SPDPoint(P_s, T()), report
end

function _conversion_note(::Type{S}, ::Type{T}, dev, curv) where {S, T}
    S == T && return "Identity — no geometry change."
    dstr = "geodesic_deviation=$(round(dev, digits=4))"
    if S <: AffineInvariant && T <: BuresWasserstein
        return "AI → BW: same point, different curvature tensors. AI has constant " *
               "negative sectional curvature; BW has non-constant. Parallel transport " *
               "and interpolation paths diverge. $dstr"
    elseif S <: BuresWasserstein && T <: AffineInvariant
        return "BW → AI: curvature tensors incompatible. $dstr"
    elseif S <: LogEuclidean
        return "LE → $(T): LE is flat (no GL-invariance). $(T) adds curvature. $dstr"
    elseif T <: LogEuclidean
        return "$(S) → LE: dropping curvature to flat log-space. " *
               "Geodesics simplify but GL-invariance is lost. $dstr"
    elseif S <: Euclidean
        return "Euclidean → Riemannian: operations now manifold-aware. " *
               "Euclidean mean can exit SPD cone; Riemannian mean cannot. $dstr"
    elseif T <: Euclidean
        return "Riemannian → Euclidean: manifold structure discarded. " *
               "curvature_proxy=$(round(curv,digits=3)). $dstr"
    else
        return "Conversion applied. Inspect geodesic_deviation. $dstr"
    end
end

"""
    parallel_transport_across_metrics(src, tgt, P, Q, X; n_steps)
    → (transported, lossy::Bool, method::Symbol, note::String)

Dispatch table:
  AI  → AI  : closed-form exact (ZAI formula)         lossy = false
  LE  → LE  : identity (flat connection)               lossy = false
  EU  → EU  : identity (flat)                          lossy = false
  any → any : Schild's ladder approximation            lossy = true

Cross-metric transport is always lossy because the Levi-Civita connections differ.
"""
function parallel_transport_across_metrics(src::Geometry, tgt::Geometry,
                                            P::AbstractMatrix{Float64},
                                            Q::AbstractMatrix{Float64},
                                            X::AbstractMatrix{Float64};
                                            n_steps::Int=12)
    # Exact paths
    if src isa AffineInvariant && tgt isa AffineInvariant
        V = ai_parallel_transport(P, Q, X)
        return (transported=V, lossy=false, method=:closed_form_ai,
                note="Exact closed-form AI parallel transport (ZAI).")
    elseif src isa LogEuclidean && tgt isa LogEuclidean
        V = le_parallel_transport(P, Q, X)
        return (transported=V, lossy=false, method=:flat_le,
                note="Log-Euclidean is flat — transport is identity.")
    elseif src isa Euclidean && tgt isa Euclidean
        V = euclidean_parallel_transport(P, Q, X)
        return (transported=V, lossy=false, method=:flat_euclidean,
                note="Euclidean is flat — transport is identity.")
    else
        # Cross-metric or BW: Schild's ladder
        geo_fn = _eval_geo_fn(src)
        V      = _schilds_ladder(geo_fn, P, Q, X, n_steps)
        return (transported=V, lossy=true, method=:schilds_ladder,
                note="Cross-metric Schild's ladder. Levi-Civita connections differ " *
                     "between $(typeof(src)) and $(typeof(tgt)) — transport is always lossy.")
    end
end

_eval_geo_fn(::AffineInvariant)  = ai_geodesic
_eval_geo_fn(::BuresWasserstein) = bw_geodesic
_eval_geo_fn(::LogEuclidean)     = le_geodesic
_eval_geo_fn(::Euclidean)        = (P, Q, t) -> (1-t).*P .+ t.*Q

# =============================================================================
# PART 3b — MODULE GEOMETRY REGISTRY  (added per review)
# =============================================================================
#
# The previous `detect_metric_context` used a hardcoded symbol set — brittle.
# This replaces it with a user-configurable registry that the PipelineAuditor
# owns. Hardcoded defaults are kept as a fallback for known library names.

"""
    ModuleGeometryRegistry

User-configurable map from module names to their assumed geometry.
The PipelineAuditor owns one instance. Users call `set_geometry!` to
override or extend the built-in defaults.
"""
mutable struct ModuleGeometryRegistry
    user_defs::Dict{Symbol, Geometry}
    ModuleGeometryRegistry() = new(Dict())
end

function set_geometry!(reg::ModuleGeometryRegistry, name::Symbol, geom::Geometry)
    reg.user_defs[name] = geom
    reg
end

const _AI_DEFAULTS   = Set([:riemannian_gaussian_sampler, :manifolds_jl, :manopt,
                              :frechet_mean, :intrinsic_wald, :geomstats])
const _BW_DEFAULTS   = Set([:wasserstein_dro, :optimal_transport, :ot_jl, :pot,
                              :bures_metric, :distributionally_robust])
const _LE_DEFAULTS   = Set([:log_euclidean, :log_euclidean_mean, :vol_surface_interp])
const _EU_DEFAULTS   = Set([:ledoit_wolf, :pca, :shrinkage, :sample_cov, :sklearn,
                              :kalman_filter, :black_scholes, :garch, :gas_model])

"""
    detect_metric_context(name; registry) → Geometry

Detect geometry from module name. Checks user registry first, then built-in
defaults. Unknown names default to Euclidean with a warning — override via
`set_geometry!(registry, :mymodule, AffineInvariant())`.
"""
function detect_metric_context(name::Symbol;
                                registry::Union{Nothing,ModuleGeometryRegistry}=nothing)
    if registry !== nothing && haskey(registry.user_defs, name)
        return registry.user_defs[name]
    end
    name ∈ _AI_DEFAULTS   && return AffineInvariant()
    name ∈ _BW_DEFAULTS   && return BuresWasserstein()
    name ∈ _LE_DEFAULTS   && return LogEuclidean()
    name ∈ _EU_DEFAULTS   && return Euclidean()
    @warn "Unknown module :$name — defaulting to Euclidean. " *
          "Override with set_geometry!(registry, :$name, <Geometry>)."
    return Euclidean()
end

"""
    tag_object(value, geometry, label; is_path) → NamedTuple

Attach provenance metadata to an SPD estimate before it leaves a module.
`is_path=true` means the object is a geodesic path rather than a point — cross-metric
path conversion is more lossy than point conversion.
"""
function tag_object(value::AbstractMatrix{Float64}, geometry::G, label::String;
                    is_path::Bool=false) where {G <: Geometry}
    (value=Matrix(ensure_spd(value)), geometry=G, label=label,
     is_path=is_path, timestamp=time())
end

# --- Module registry for audit ---

struct ModuleConfig
    name::Symbol
    geometry::Geometry
    space_dim::Int
end

mutable struct MetricRegistry
    modules::Dict{Symbol, ModuleConfig}
    geom_registry::ModuleGeometryRegistry
    MetricRegistry() = new(Dict(), ModuleGeometryRegistry())
end

function register_module!(r::MetricRegistry, name::Symbol, geom::Geometry, dim::Int)
    r.modules[name] = ModuleConfig(name, geom, dim)
    set_geometry!(r.geom_registry, name, geom)
    r
end

function audit_metric_consistency(reg::MetricRegistry)
    issues = String[]
    mods   = collect(values(reg.modules))
    isempty(mods) && return issues
    geom_types = Set(typeof(m.geometry) for m in mods)

    if length(geom_types) >= 3
        push!(issues, "Three or more geometries in simultaneous use: $geom_types. " *
                      "Every cross-metric boundary compounds lossiness.")
    end
    if AffineInvariant ∈ geom_types && BuresWasserstein ∈ geom_types
        n = mods[1].space_dim
        P = ensure_spd(Matrix{Float64}(I,n,n) .+ 0.3.*randn(n,n))
        Q = ensure_spd(Matrix{Float64}(I,n,n) .+ 0.3.*randn(n,n))
        d = compare_geodesic_deviation(AffineInvariant(), BuresWasserstein(), P, Q)
        push!(issues, "AI ↔ BW boundary present. " *
                      "Geodesic deviation ≈ $(round(d,digits=4)). " *
                      "Verify which geometry is correct for each interpolation step.")
    end
    if Euclidean ∈ geom_types && (AffineInvariant ∈ geom_types ||
                                   BuresWasserstein ∈ geom_types)
        push!(issues, "Euclidean averaging mixed with Riemannian geometry. " *
                      "Euclidean mean can exit SPD cone; Riemannian mean cannot. " *
                      "Ledoit-Wolf (Euclidean) and riemannian-gaussian-sampler (AI) " *
                      "use incompatible notions of 'average covariance'.")
    end
    if LogEuclidean ∈ geom_types && AffineInvariant ∈ geom_types
        push!(issues, "LogEuclidean and AffineInvariant both present. " *
                      "LE is not GL(n)-invariant; AI is. For factor-model covariances " *
                      "where basis-change invariance matters, prefer AI throughout.")
    end
    issues
end

# =============================================================================
# PART 4 — INTEGRATION CONVENTION RESOLVER
# =============================================================================

abstract type IntegralConvention end
struct ItoCalculus          <: IntegralConvention end
struct StratonovichCalculus <: IntegralConvention end

"""
    RoughPath{H}

For H < 0.5: standard Itô/Stratonovich calculus is ill-posed (quadratic variation
diverges). A lift must be chosen and held fixed across all modules.

Lift options:
  :geometric  (default) — Stratonovich-type chain rule preserved. For H ∈ (1/3, 0.5),
                          this is the Marcus integral: the canonical extension of
                          Stratonovich to rough paths. The :error severity in the
                          auditor can be downgraded to :warning if all connected
                          modules use the same geometric lift with matching H.
  :branched   — used for non-geometric rough paths (e.g. KPZ equation); rare in finance.

For H ≤ 1/3, truncation_level ≥ 3 is required (third-order rough path theory).
For H > 1/3, truncation_level = 2 suffices.
"""
struct RoughPath{H} <: IntegralConvention
    hurst::Float64
    lift::Symbol
    truncation_level::Int
    function RoughPath(H::Float64; lift::Symbol=:geometric, trunc::Int=2)
        H ≥ 0.5 && @warn "H=$H ≥ 0.5: standard Itô/Stratonovich calculus is valid."
        H ≤ 1/3 && trunc < 3 && @warn "H=$H ≤ 1/3: truncation_level ≥ 3 required."
        new{H}(H, lift, trunc)
    end
end

struct SDESpec
    name::Symbol
    convention::IntegralConvention
    drift::Function         # b(t, X) → Vector
    diffusion::Function     # σ(t, X) → Matrix
    state_dim::Int
    noise_dim::Int
    description::String
end

struct ConventionConflict
    from::Symbol
    to::Symbol
    severity::Symbol        # :error | :warning
    message::String
end

mutable struct SDERegistry
    specs::Dict{Symbol, SDESpec}
    edges::Vector{Tuple{Symbol,Symbol}}
    SDERegistry() = new(Dict(), [])
end

register_sde!(r::SDERegistry, spec::SDESpec) = (r.specs[spec.name] = spec; r)
connect_sdes!(r::SDERegistry, a::Symbol, b::Symbol) = (push!(r.edges, (a,b)); r)

"""
    stratonovich_to_ito(spec) → SDESpec

Itô drift = Stratonovich drift + ½ Σᵢ σᵢ(X) · ∂σᵢ/∂X.
Correction via finite-difference Jacobian.

For manifold-valued processes on SPD(n), the AI-metric closed-form correction is:
    −½ Σₖ σₖ X⁻¹ σₖ
This is more numerically stable — use it when σ is known analytically.
"""
function stratonovich_to_ito(spec::SDESpec)
    isa(spec.convention, ItoCalculus) && return spec
    if isa(spec.convention, RoughPath)
        error("RoughPath cannot be converted to Itô without a lift. " *
              "Call enforce_rough_path_lift! first.")
    end

    σ_fn = spec.diffusion; n = spec.state_dim; m = spec.noise_dim; h = 1e-6

    correction = (t, X) -> begin
        corr = zeros(n); σ0 = σ_fn(t, X)
        for i in 1:m
            σᵢ = σ0[:, i]
            J  = hcat([(σ_fn(t, X .+ h .* eachcol(I(n))[j])[:,i] .- σᵢ) ./ h
                        for j in 1:n]...)
            corr .+= 0.5 .* (J * σᵢ)
        end
        corr
    end

    SDESpec(spec.name, ItoCalculus(),
            (t, X) -> spec.drift(t, X) .+ correction(t, X), spec.diffusion,
            spec.state_dim, spec.noise_dim, spec.description * " [Strat→Itô]")
end

"""ito_to_stratonovich: subtract the same correction term."""
function ito_to_stratonovich(spec::SDESpec)
    isa(spec.convention, StratonovichCalculus) && return spec
    isa(spec.convention, RoughPath) &&
        error("RoughPath → Stratonovich undefined without lift.")

    σ_fn = spec.diffusion; n = spec.state_dim; m = spec.noise_dim; h = 1e-6

    correction = (t, X) -> begin
        corr = zeros(n); σ0 = σ_fn(t, X)
        for i in 1:m
            σᵢ = σ0[:,i]
            J  = hcat([(σ_fn(t, X .+ h.*eachcol(I(n))[j])[:,i] .- σᵢ)./h for j in 1:n]...)
            corr .+= 0.5.*(J*σᵢ)
        end
        corr
    end

    SDESpec(spec.name, StratonovichCalculus(),
            (t, X) -> spec.drift(t, X) .- correction(t, X), spec.diffusion,
            spec.state_dim, spec.noise_dim, spec.description * " [Itô→Strat]")
end

"""
    enforce_rough_path_lift!(registry, name, H; lift, trunc)

Register a geometric rough path lift for H < 0.5 and update the SDE convention.

SIMULATION NOTE: This function enforces *tagging* consistency — it guarantees
that the pipeline auditor will correctly identify convention conflicts. It does NOT
implement actual rough path simulation. For numerical simulation of rough SDEs
(including Lévy area computation), you need either:
  (a) `RoughPaths.jl` (external dependency), or
  (b) A Milstein-type scheme with explicit Lévy area approximation.
The audit will correctly flag convention mixing, but a passing audit does not
guarantee simulation correctness for H < 0.5.
"""
function enforce_rough_path_lift!(registry::SDERegistry, name::Symbol, H::Float64;
                                   lift::Symbol=:geometric, trunc::Int=2)
    H ≥ 0.5 && @warn "H=$H ≥ 0.5: standard calculus applies."
    spec = get(registry.specs, name, nothing)
    spec === nothing && error("SDE :$name not registered.")
    registry.specs[name] = SDESpec(spec.name, RoughPath(H; lift=lift, trunc=trunc),
                                    spec.drift, spec.diffusion, spec.state_dim,
                                    spec.noise_dim,
                                    spec.description * " [RoughPath H=$H lift=$lift]")
    registry
end

"""
    audit_sde_conventions(registry) → Vector{ConventionConflict}

:error   — RoughPath + Itô/Stratonovich: undefined without lift unification.
:warning — Itô ↔ Stratonovich: convertible via stratonovich_to_ito.

Note on Marcus integral: For H ∈ (1/3, 0.5) with lift=:geometric,
conversion to Stratonovich is well-defined (geometric = Stratonovich analogue).
The severity can be downgraded to :warning when both modules use matching
geometric lifts. This refinement is not yet automated here.
"""
function audit_sde_conventions(registry::SDERegistry)
    conflicts = ConventionConflict[]
    for (a, b) in registry.edges
        sa = get(registry.specs, a, nothing)
        sb = get(registry.specs, b, nothing)
        (sa === nothing || sb === nothing) && continue
        ca, cb = sa.convention, sb.convention
        typeof(ca) == typeof(cb) && continue

        if isa(ca, RoughPath) || isa(cb, RoughPath)
            rp  = isa(ca, RoughPath) ? ca : cb
            msg = "RoughPath (H=$(rp.hurst), lift=$(rp.lift)) mixed with " *
                  "$(typeof(isa(ca, RoughPath) ? cb : ca)). Integration is undefined. " *
                  "Call enforce_rough_path_lift! on all connected modules."
            if rp.hurst > 1/3 && rp.lift == :geometric
                msg *= " [Note: H ∈ (1/3, 0.5) + geometric lift = Marcus integral — " *
                       "Stratonovich analogue. Severity may be downgraded if target " *
                       "also uses geometric lift.]"
            end
            push!(conflicts, ConventionConflict(a, b, :error, msg))
        else
            push!(conflicts, ConventionConflict(a, b, :warning,
                "$(typeof(ca)) → $(typeof(cb)): apply stratonovich_to_ito or " *
                "ito_to_stratonovich at this boundary."))
        end
    end
    conflicts
end

# =============================================================================
# PART 5 — MANIFOLD-AWARE INFERENCE ENGINE
# =============================================================================

"""
    FrechetMeanResult

Convergence-annotated Fréchet mean with residual history.
"""
struct FrechetMeanResult
    mean::Matrix{Float64}
    converged::Bool
    iterations::Int
    final_residual::Float64
    history::Vector{Float64}
end

"""
    frechet_mean_spd(matrices; max_iter, tol, init) → FrechetMeanResult

Karcher flow on SPD(n) with affine-invariant metric.
Minimises Σᵢ d²_AI(Pᵢ, M) over M ∈ SPD(n).

AD COMPATIBILITY: `ai_log`, `ai_exp`, `_mat_log`, `_mat_exp` are differentiable
via ForwardDiff.jl or Zygote.jl through `eigen()`, provided eigenvalues are
distinct. For degenerate covariances (repeated eigenvalues), the gradient of
the matrix logarithm is not uniquely defined — a known limitation of matrix
function AD. Add regularisation `P + ε*I` before passing to frechet_mean_spd
if your covariance samples may be ill-conditioned.
"""
function frechet_mean_spd(matrices::Vector{<:AbstractMatrix{Float64}};
                           max_iter::Int=150, tol::Float64=1e-10,
                           init::Union{Nothing,AbstractMatrix{Float64}}=nothing)
    N = length(matrices)
    M = init !== nothing ? Matrix(ensure_spd(init)) :
                           Matrix(ensure_spd(sum(matrices) ./ N))
    history = Float64[]

    for k in 1:max_iter
        grad = sum(ai_log(M, P) for P in matrices) ./ N
        res  = norm(grad, 2)
        push!(history, res)
        M = Matrix(ensure_spd(ai_exp(M, grad)))
        res < tol && return FrechetMeanResult(M, true, k, res, history)
    end
    FrechetMeanResult(M, false, max_iter, history[end], history)
end

"""Empirical covariance of log-mapped vectors in tangent space at base."""
function _tangent_cov(base::AbstractMatrix{Float64},
                       matrices::Vector{<:AbstractMatrix{Float64}})
    vecs = [vec(ai_log(base, P)) for P in matrices]
    N    = length(vecs)
    μ    = sum(vecs) ./ N
    cov  = sum((v .- μ) * (v .- μ)' for v in vecs) ./ (N-1)
    Symmetric(cov .+ 1e-8 .* I(length(μ)))
end

spd_dof(n::Int) = n*(n+1) ÷ 2

# --- Distribution-free chi-squared (no external deps) ---

function _norm_sf(z::Float64)
    a = (0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429)
    p = 0.3275911
    s = z < 0 ? -1 : 1
    t = 1.0 / (1.0 + p*abs(z))
    y = 1.0 - ((((a[5]*t + a[4])*t + a[3])*t + a[2])*t + a[1])*t*exp(-z^2/2)
    0.5*(1.0 + s*y)
end

function _gamma_sf(a::Float64, x::Float64)
    x < 0 && return 1.0
    if x < a + 1.0
        t = s = 1.0
        for n in 1:200
            t *= x/(a+n); s += t
            abs(t) < abs(s)*1e-12 && break
        end
        return max(0.0, min(1.0, 1.0 - s*exp(-x + a*log(x) - lgamma(a))))
    else
        b = x+1-a; c = 1e30; d = 1.0/(x+1-a); h = d
        for i in 1:200
            an = -Float64(i)*(i-a); b += 2.0
            d  = 1.0/(an*d + b); c = b + an/c
            Δ  = d*c; h *= Δ
            abs(Δ - 1.0) < 1e-12 && break
        end
        return max(0.0, min(1.0, exp(-x + a*log(x) - lgamma(a))*h))
    end
end

function _chi2_sf(x::Float64, df::Int)
    x ≤ 0 && return 1.0
    df > 30 && return _norm_sf(((x/df)^(1/3) - (1 - 2/(9df))) / sqrt(2/(9df)))
    return _gamma_sf(df/2.0, x/2.0)
end

function _chi2_quantile(p::Float64, df::Int)
    z = _norm_quantile(p)
    max(0.0, df*(1 - 2/(9df) + z*sqrt(2/(9df)))^3)
end

function _norm_quantile(p::Float64)
    p ≤ 0 && return -Inf; p ≥ 1 && return Inf
    p < 0.5 && return -_norm_quantile(1-p)
    t = sqrt(-2log(1-p))
    t - (2.515517 + 0.802853t + 0.010328t^2) /
        (1 + 1.432788t + 0.189269t^2 + 0.001308t^3)
end

"""
    intrinsic_wald_test(samples, null_point; alpha) → NamedTuple

Riemannian Wald test on SPD(n):
    1. Compute Fréchet mean μ̂
    2. Project samples to T_{μ̂} via log map; form empirical covariance Ŝ
    3. W = n · v₀ᵀ Ŝ⁻¹ v₀   where v₀ = vec(log_{μ̂}(μ₀))
    4. W ~ χ²(d),  d = n(n+1)/2
"""
function intrinsic_wald_test(samples::Vector{<:AbstractMatrix{Float64}},
                              null_point::AbstractMatrix{Float64};
                              alpha::Float64=0.05)
    N  = length(samples)
    fm = frechet_mean_spd(samples)
    μ̂ = fm.mean
    μ₀ = Matrix(ensure_spd(null_point))
    d  = spd_dof(size(μ̂, 1))

    S    = _tangent_cov(μ̂, samples)
    v₀   = vec(ai_log(μ̂, μ₀))
    W    = N * dot(v₀, pinv(Matrix(S)) * v₀)
    pval = _chi2_sf(W, d)

    (statistic=W, df=d, p_value=pval, reject=pval < alpha,
     frechet_mean=μ̂, converged=fm.converged)
end

"""
    manifold_ttest(group1, group2; alpha) → NamedTuple

Two-sample intrinsic t-test on SPD(n).
H₀: Fréchet means of group1 and group2 are equal.

Uses pooled tangent-space variance at the joint Fréchet mean. The t-statistic
squared is compared to χ²(1), which is the asymptotic distribution for large
degrees of freedom. For small samples (n < 30), the exact distribution is
Hotelling's T², which transforms to F(d, N−d) where d = spd_dof(n). This
approximation is adequate for most financial use cases (regime windows typically
have ≥ 60 daily observations).
"""
function manifold_ttest(group1::Vector{<:AbstractMatrix{Float64}},
                         group2::Vector{<:AbstractMatrix{Float64}};
                         alpha::Float64=0.05)
    n1, n2 = length(group1), length(group2)
    (n1 < 30 || n2 < 30) && @warn "Small sample (n₁=$n1, n₂=$n2 < 30). " *
        "t² ~ χ²(1) is asymptotic; consider Hotelling's T² for finite-sample correction."

    fm1 = frechet_mean_spd(group1)
    fm2 = frechet_mean_spd(group2)
    fmp = frechet_mean_spd(vcat(group1, group2),
                            init=0.5.*(fm1.mean .+ fm2.mean))
    μp  = fmp.mean

    δ1   = vec(ai_log(μp, fm1.mean))
    δ2   = vec(ai_log(μp, fm2.mean))
    dist = norm(δ1 .- δ2)

    v1   = [vec(ai_log(μp, P)) for P in group1]
    v2   = [vec(ai_log(μp, P)) for P in group2]
    μv1  = sum(v1)./n1; μv2 = sum(v2)./n2
    var1 = sum(dot(v.-μv1, v.-μv1) for v in v1)/(n1-1)
    var2 = sum(dot(v.-μv2, v.-μv2) for v in v2)/(n2-1)
    pv   = ((n1-1)*var1 + (n2-1)*var2)/(n1+n2-2)
    se   = sqrt(pv*(1/n1 + 1/n2))
    t    = se > 1e-14 ? dist/se : Inf
    pval = _chi2_sf(t^2, 1)

    (statistic=t, df=n1+n2-2, p_value=pval, reject=pval < alpha,
     riemannian_distance=dist, mean1=fm1.mean, mean2=fm2.mean,
     converged=fm1.converged && fm2.converged && fmp.converged)
end

"""One-sample test: H₀: Fréchet mean = null_point."""
function one_sample_manifold_test(samples::Vector{<:AbstractMatrix{Float64}},
                                   null_point::AbstractMatrix{Float64};
                                   alpha::Float64=0.05)
    N   = length(samples)
    fm  = frechet_mean_spd(samples)
    μ₀  = Matrix(ensure_spd(null_point))
    δ   = ai_log(μ₀, fm.mean)
    dist = sqrt(max(0.0, ai_inner(μ₀, δ, δ)))
    norms = [sqrt(max(0.0, ai_inner(μ₀, ai_log(μ₀, P), ai_log(μ₀, P)))) for P in samples]
    se    = std(norms) / sqrt(N)
    t     = se > 1e-14 ? dist/se : Inf
    pval  = _chi2_sf(t^2, 1)
    (statistic=t, df=N-1, p_value=pval, reject=pval < alpha,
     distance=dist, frechet_mean=fm.mean, converged=fm.converged)
end

"""
    intrinsic_confidence_region(samples; alpha) → NamedTuple

Geodesic confidence ball on SPD(n).
Returns Fréchet mean, χ² quantile radius, and geodesic boundary points
along principal axes of tangent-space covariance.
"""
function intrinsic_confidence_region(samples::Vector{<:AbstractMatrix{Float64}};
                                      alpha::Float64=0.95)
    N  = length(samples); fm = frechet_mean_spd(samples)
    μ̂ = fm.mean; n = size(μ̂, 1); d = spd_dof(n)
    χ²q   = _chi2_quantile(alpha, d)
    S     = Matrix(_tangent_cov(μ̂, samples))
    F     = eigen(Symmetric(S))
    radii = sqrt.(χ²q ./ max.(F.values, 1e-10))
    bdy   = [ensure_spd(ai_exp(μ̂, reshape(r.*F.vectors[:,i], n, n)))
             for (i,r) in enumerate(radii)]
    (center=μ̂, chi2_quantile=χ²q, radii=radii, boundary_points=bdy,
     converged=fm.converged, alpha=alpha)
end

# =============================================================================
# PART 6 — PIPELINE AUDITOR
# =============================================================================

"""
    PipelineAuditReport

Severity-annotated audit across all three coordination layers.
  :ok      — geometrically consistent; safe for production
  :warning — issues present; must resolve before production
  :error   — critical misspecifications; invalidates inference
"""
struct PipelineAuditReport
    metric_issues::Vector{String}
    convention_conflicts::Vector{ConventionConflict}
    summary::String
    severity::Symbol
end

function Base.show(io::IO, r::PipelineAuditReport)
    bar = "=" ^ 65
    println(io, bar); println(io, "STRATUM III AUDIT  [$(r.severity)]"); println(io, bar)
    if !isempty(r.metric_issues)
        println(io, "\n[Metric Consistency Layer]")
        foreach(i -> println(io, "  • $i"), r.metric_issues)
    end
    if !isempty(r.convention_conflicts)
        println(io, "\n[Integration Convention Resolver]")
        for c in r.convention_conflicts
            println(io, "  [$(c.severity)] $(c.from) → $(c.to)")
            println(io, "    $(c.message[1:min(120,end)])")
        end
    end
    println(io, "\n[Summary]\n  $(r.summary)"); println(io, bar)
end

"""
    PipelineAuditor

Master coordination object. Owns a MetricRegistry, SDERegistry, and
ModuleGeometryRegistry. Register all modules and SDEs, then call audit().
"""
mutable struct PipelineAuditor
    metric_reg::MetricRegistry
    sde_reg::SDERegistry
    geom_reg::ModuleGeometryRegistry    # user-configurable geometry overrides
    PipelineAuditor() = new(MetricRegistry(), SDERegistry(), ModuleGeometryRegistry())
end

function audit(pa::PipelineAuditor)
    m_issues = audit_metric_consistency(pa.metric_reg)
    c_issues = audit_sde_conventions(pa.sde_reg)
    has_err  = any(c.severity == :error   for c in c_issues)
    has_warn = !isempty(m_issues) || any(c.severity == :warning for c in c_issues)
    sev      = has_err ? :error : has_warn ? :warning : :ok
    n        = length(m_issues) + length(c_issues)
    summary  = "$n issue(s). " * (
        sev == :ok      ? "Pipeline is geometrically consistent. Safe for production." :
        sev == :warning ? "Warnings present. Address before production deployment." :
                          "CRITICAL: Errors invalidate inference. Resolve first.")
    PipelineAuditReport(m_issues, c_issues, summary, sev)
end

# =============================================================================
# PART 7 — DEMONSTRATION
# =============================================================================

function run_demo()
    println("\n" * "=" ^ 65)
    println("GeometricCoordinationLayer v2 — Demonstration")
    println("=" ^ 65)
    Random.seed!(42); n = 4

    A = randn(n,n); P = ensure_spd(A*A' .+ 2I(n))
    B = randn(n,n); Q = ensure_spd(B*B' .+ 3I(n))

    println("\n--- Layer 1: Metric Consistency ---")
    println("AI ↔ BW geodesic deviation : $(round(compare_geodesic_deviation(AffineInvariant(),BuresWasserstein(),P,Q), digits=5))")
    println("EU ↔ AI geodesic deviation : $(round(compare_geodesic_deviation(Euclidean(),AffineInvariant(),P,Q), digits=5))")
    println("LE ↔ AI geodesic deviation : $(round(compare_geodesic_deviation(LogEuclidean(),AffineInvariant(),P,Q), digits=5))")

    src = SPDPoint(P, AffineInvariant())
    tgt, rep = convert_geometry(src, BuresWasserstein())
    display(rep)

    geom_reg = ModuleGeometryRegistry()
    set_geometry!(geom_reg, :my_custom_module, AffineInvariant())
    ctx = detect_metric_context(:my_custom_module; registry=geom_reg)
    println("Custom module geometry: $ctx")

    println("\nParallel transport dispatch table:")
    V = Symmetric(randn(n,n) |> M -> 0.5*(M+M'))
    for (s,t) in [(AffineInvariant(),AffineInvariant()), (AffineInvariant(),BuresWasserstein()),
                   (LogEuclidean(),LogEuclidean()), (Euclidean(),Euclidean())]
        r = parallel_transport_across_metrics(s, t, P, Q, Matrix(V))
        println("  $(typeof(s)) → $(typeof(t)): lossy=$(r.lossy), method=$(r.method)")
    end

    println("\n--- Layer 2: Convention Resolver ---")
    reg = SDERegistry()
    register_sde!(reg, SDESpec(:kalman, ItoCalculus(), (t,X)->X, (t,X)->0.1I(1), 1,1,""))
    register_sde!(reg, SDESpec(:riem,  StratonovichCalculus(), (t,X)->X, (t,X)->0.05I(1), 1,1,""))
    register_sde!(reg, SDESpec(:roughvol, ItoCalculus(), (t,X)->X, (t,X)->0.1I(1), 1,1,""))
    enforce_rough_path_lift!(reg, :roughvol, 0.1)
    connect_sdes!(reg, :kalman, :riem); connect_sdes!(reg, :roughvol, :kalman)
    conflicts = audit_sde_conventions(reg)
    println("Conflicts: $(length(conflicts))")
    for c in conflicts; println("  [$(c.severity)] $(c.from)→$(c.to)"); end

    println("\n--- Layer 3: Manifold Inference ---")
    tc = [2.0 0.8 0.3; 0.8 1.5 0.4; 0.3 0.4 1.0]
    s1 = [ensure_spd(tc .+ 0.3.*randn(3,3)|>M->0.5*(M+M')) for _ in 1:60]
    s2 = [ensure_spd([3.0 1.0 0.5;1.0 2.0 0.6;0.5 0.6 1.5] .+ 0.3.*randn(3,3)|>M->0.5*(M+M')) for _ in 1:60]
    fm = frechet_mean_spd(s1)
    println("Fréchet mean: converged=$(fm.converged), iter=$(fm.iterations)")
    w  = intrinsic_wald_test(s1, tc)
    println("Wald test: W=$(round(w.statistic,digits=3)) p=$(round(w.p_value,digits=4)) reject=$(w.reject)")
    tt = manifold_ttest(s1, s2)
    println("t-test: t=$(round(tt.statistic,digits=3)) p=$(round(tt.p_value,digits=4)) reject=$(tt.reject)")

    println("\n--- Full Pipeline Audit ---")
    pa = PipelineAuditor()
    set_geometry!(pa.geom_reg, :my_vol_module, LogEuclidean())
    register_module!(pa.metric_reg, :ledoit_wolf,              Euclidean(),       3)
    register_module!(pa.metric_reg, :riemannian_gaussian_sampler, AffineInvariant(),3)
    register_module!(pa.metric_reg, :wasserstein_dro,          BuresWasserstein(),3)
    register_module!(pa.metric_reg, :vol_surface,              LogEuclidean(),    3)
    register_sde!(pa.sde_reg, SDESpec(:kf, ItoCalculus(), (t,X)->X, (t,X)->0.1I(3),3,3,""))
    register_sde!(pa.sde_reg, SDESpec(:ms, StratonovichCalculus(),(t,X)->X,(t,X)->0.05X,3,9,""))
    connect_sdes!(pa.sde_reg, :kf, :ms)
    register_sde!(pa.sde_reg, SDESpec(:rv, ItoCalculus(),(t,X)->X,(t,X)->0.1I(3),3,3,""))
    enforce_rough_path_lift!(pa.sde_reg, :rv, 0.1)
    connect_sdes!(pa.sde_reg, :rv, :kf)
    display(audit(pa))
    println("Demonstration complete.")
end

end # module GeometricCoordinationLayer
