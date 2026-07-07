module CVLayer
include("purged_kfold.jl")
using .PurgedKFold
export PurgedKFold
export PurgedKFoldConfig, CPCVConfig, CVFold,
       acf_half_life, compute_embargo_size,
       purged_kfold_split, cpcv_split,
       cross_val_score_purged, cross_val_score_cpcv
end
