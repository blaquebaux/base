#!/bin/bash
# ============================================================================
# run_carry_book_daily.sh — PHASE 1 daily DRY-RUN logger for the crypto funding-carry sleeve.
#
# Computes the delta-neutral spot/perp carry book against LIVE PUBLIC funding data (OKX, no keys), runs the
# funding gate + every tail circuit breaker (venue cap / basis / stablecoin / kill switch), runs the safety-gate
# preflight, and LOGS — placing NOTHING. This is Phase 1: no venue, no capital, no orders. It exists so the
# carry book + its tail governance can be watched day-to-day before any venue/entity/capital commitment.
# Paper/live (Phase 2/3) require the PerpVenue adapter and are blocked in the driver itself.
#
# Manual test:  bash scripts/run_carry_book_daily.sh
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
JULIA="/Users/malcolmx/.juliaup/bin/julia"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/carry_book_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') carry-book Phase 1 dry-run ================"
export BB_CARRY_MODE="dryrun"          # Phase 1 is dry-run only; the driver blocks paper/live without a PerpVenue
cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }
"$JULIA" --project=. scripts/carry_book_live.jl
RC=$?
echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
