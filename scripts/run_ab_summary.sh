#!/bin/bash
# ============================================================================
# run_ab_summary.sh — weekly Monday cross-family A/B check-in (read-only). Invoked by
# com.blaquebaux.ab_summary.plist ~09:45 ET Mon, after the books fill at 9:30. Runs
# family_summary.py, which snapshots EVERY leg (spine family + Blunt + Boom + any
# future sleeve with keys in ~/.config/blaquebaux) and writes logs/family_summary_<date>.txt.
# The Python reads each account key file itself (never printed); no keys here.
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/ab_summary_run_$(TZ=America/New_York date +%Y%m%d).log"
exec >> "$LOG" 2>&1
echo "---------------- $(TZ=America/New_York date '+%F %T %Z') A/B summary ----------------"
cd "$REPO" || { echo "cannot cd $REPO"; exit 0; }
/usr/bin/python3 scripts/family_summary.py
echo "---------------- done $(TZ=America/New_York date '+%T %Z') ----------------"
