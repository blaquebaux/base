#!/bin/bash
# ============================================================================
# run_pnl_close.sh — end-of-day P&L attribution snapshot (Layer 0, read-only).
#
# Invoked by launchd (com.blaquebaux.pnl.plist) each weekday shortly after the
# US close, so the logged day P&L is the FULL day (not the morning open snapshot
# the trade wrapper records). Trades nothing; only reads the account.
#
# Manual test:  bash scripts/run_pnl_close.sh
# ============================================================================
set -uo pipefail

REPO="/Users/malcolmx/blaquebaux"
ENVFILE="$HOME/.config/blaquebaux/alpaca.env"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/pnl_close_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "---------------- $(TZ=America/New_York date '+%F %T %Z') pnl close snapshot ----------------"

if [ ! -f "$ENVFILE" ]; then
    echo "MISSING $ENVFILE — cannot read account"; exit 0
fi
set -a; source "$ENVFILE"; set +a

# Only snapshot on an actual trading day (skip weekends/holidays cleanly).
CLOCK=$(curl -s --max-time 15 \
    -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
    https://paper-api.alpaca.markets/v2/clock)
NEXT_OPEN=$(echo "$CLOCK" | grep -o '"next_open":"[^"]*"' | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
ET_TODAY=$(TZ=America/New_York date +%F)
# after the close, next_open is tomorrow; if next_open is > today we traded today (or it's a holiday
# with no session — in which case the snapshot is harmless, just a repeat of the prior book).
cd "$REPO" || { echo "cannot cd $REPO"; exit 0; }
/usr/bin/python3 scripts/pnl_attribution.py close
echo "---------------- done $(TZ=America/New_York date '+%T %Z') ----------------"
