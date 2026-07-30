#!/bin/bash
# ============================================================================
# run_spine_daily.sh — the autonomous daily trade job (Layer 1, no LLM).
#
# Invoked by the launchd agent (com.blaquebaux.spine.plist) each weekday pre-open.
#   1. loads Alpaca keys from a chmod-600 env file (NEVER in the repo)
#   2. gates on the Alpaca calendar — skips cleanly on holidays
#   3. runs the deterministic Julia spine; logs everything to logs/spine_<date>.log
#
# Manual test:  bash scripts/run_spine_daily.sh   (then read the logfile it prints)
# ============================================================================
set -uo pipefail   # NOT -e: we always want to log, even on failure

REPO="/Users/malcolmx/blaquebaux"
ENVFILE="$HOME/.config/blaquebaux/alpaca.env"
JULIA="/Users/malcolmx/.juliaup/bin/julia"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/spine_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') spine daily run ================"

# 1) keys — kept OUT of the repo, in a chmod-600 file that exports the two vars.
if [ ! -f "$ENVFILE" ]; then
    echo "MISSING $ENVFILE — create it (chmod 600) exporting ALPACA_KEY_ID / ALPACA_SECRET_KEY"; exit 1
fi
set -a; source "$ENVFILE"; set +a
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
    echo "ALPACA_KEY_ID / ALPACA_SECRET_KEY not set by $ENVFILE"; exit 1
fi

# 2) trading-day gate: proceed if the market is OPEN now (is_open) OR the next open is TODAY
#    (the pre-open scheduled case). Skip only on a genuine non-trading day (weekend/holiday).
#    (Idempotency also protects us, but this avoids noise.)
CLOCK=$(curl -s --max-time 15 \
    -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
    https://paper-api.alpaca.markets/v2/clock)
IS_OPEN=$(echo "$CLOCK" | grep -Eo '"is_open":(true|false)' | grep -Eo 'true|false' | head -1)
NEXT_OPEN=$(echo "$CLOCK" | grep -o '"next_open":"[^"]*"' | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
ET_TODAY=$(TZ=America/New_York date +%F)
if [ -z "$IS_OPEN" ] && [ -z "$NEXT_OPEN" ]; then
    echo "WARN: could not read Alpaca clock ($CLOCK) — proceeding (idempotency still protects)"
elif [ "$IS_OPEN" != "true" ] && [ "$NEXT_OPEN" != "$ET_TODAY" ]; then
    echo "not a trading day (is_open=$IS_OPEN, next_open=$NEXT_OPEN, et_today=$ET_TODAY) — skipping"; exit 0
fi

# 3) the deterministic spine through the Layer-3 safety gate (paper unless BB_LIVE_CONFIRM set).
#    Every pre-trade guard runs; on a trip it halts + alerts and places nothing.
cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }
"$JULIA" --project=. scripts/spine_live.jl
RC=$?
echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
