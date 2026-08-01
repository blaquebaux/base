#!/bin/bash
# ============================================================================
# run_ab_summary.sh — weekly Monday A/B check-in (read-only). Invoked by
# com.blaquebaux.ab_summary.plist ~09:45 ET Mon, after both books fill at 9:30.
# Writes logs/ab_summary_<date>.txt comparing the single vs split paper books.
# The Python reads BOTH account key files itself (never printed); no keys here.
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/ab_summary_run_$(TZ=America/New_York date +%Y%m%d).log"
exec >> "$LOG" 2>&1
echo "---------------- $(TZ=America/New_York date '+%F %T %Z') A/B summary ----------------"
cd "$REPO" || { echo "cannot cd $REPO"; exit 0; }
/usr/bin/python3 scripts/ab_summary.py
echo "---------------- done $(TZ=America/New_York date '+%T %Z') ----------------"
