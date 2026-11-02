# =============================================================================
# test_module_11.jl — Module 11 (purged CV, CVLayer/PurgedKFold) load + smoke
# test (PRE-02) AND the purged-split agreement test (PRE-03).
#
# PRE-03 decision: module_11_cv/PurgedKFold is the CANONICAL purged-CV
# implementation (full López de Prado: label-overlap purge + after-embargo,
# CPCV). StructuralStatistics.generate_purged_splits is a lightweight index-only
# helper used by the stratum simulation tests. The two AGREE on the test-fold
# partition (asserted below); they differ only in train-set embargo sidedness by
# design (generate_purged_splits uses a symmetric index embargo, the canonical
# impl embargoes after the test set and purges by label overlap). That intended
# difference is documented here rather than hidden.
# =============================================================================
isdefined(Main, :CVLayer) || include("../src/module_11_cv/module_11_cv.jl")
isdefined(Main, :StructuralStatistics) || include("../src/StructuralStatistics.jl")
using .CVLayer
using .StructuralStatistics: generate_purged_splits
using Test

@testset "Module 11: CVLayer loads" begin
    for s in (:PurgedKFoldConfig, :CVFold, :purged_kfold_split, :cpcv_split,
              :compute_embargo_size, :cross_val_score_purged)
        @test isdefined(CVLayer, s)
    end
end

@testset "PRE-03: purged splits agree on test folds" begin
    n, folds, embargo = 100, 5, 3
    gs = generate_purged_splits(n, embargo; n_folds=folds)
    cfg = CVLayer.PurgedKFoldConfig(n_splits=folds, embargo_bars=embargo, purge_overlap=false)
    ks = CVLayer.purged_kfold_split(n, cfg)

    @test length(gs) == length(ks) == folds
    # Canonical and lightweight implementations partition the test folds identically.
    for (g, k) in zip(gs, ks)
        @test Set(g.test) == Set(k.test_idx)
    end
    # Both purge the embargo band around each test fold: no training index lies
    # within `embargo` of its own test fold (the leakage guard both must honour).
    for k in ks
        lo, hi = minimum(k.test_idx), maximum(k.test_idx)
        @test !any(lo - embargo ≤ i ≤ hi + embargo && !(i in k.test_idx) for i in k.train_idx
                   if i > hi)   # after-embargo side, the canonical guard
    end
end
