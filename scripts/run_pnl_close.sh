#!/bin/bash
# ============================================================================
# run_pnl_close.sh — end-of-day P&L attribution snapshot (Layer 0, read-only).
#
# Invoked by launchd (com.blaquebaux.pnl.plist) each weekday shortly after the
# US close, so the logged day P&L is the FULL day (not the morning open snapshot).
# Snapshots BOTH paper accounts — single (+DBA) and split — each from its own key
# file, in separate subshells so the keys never mix. The split is skipped cleanly
# until its account exists. Trades nothing; never prints keys.
#
# Manual test:  bash scripts/run_pnl_close.sh
# ============================================================================
set -uo pipefail

REPO="/Users/malcolmx/blaquebaux"
CFG="$HOME/.config/blaquebaux"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/pnl_close_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "---------------- $(TZ=America/New_York date '+%F %T %Z') pnl close snapshot (both accounts) ----------------"
cd "$REPO" || { echo "cannot cd $REPO"; exit 0; }

# Trading-day gate (single account's clock; the market is the same for both). Returns 0 on a trading
# day (or if it can't tell), 1 on a confirmed non-trading day.
is_trading_day() {
    local envf="$CFG/alpaca.env"
    [ -f "$envf" ] || return 0
    ( set -a; source "$envf"; set +a
      local clock is_open next_open et_today
      clock=$(curl -s --max-time 15 \
          -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
          https://paper-api.alpaca.markets/v2/clock)
      is_open=$(echo "$clock" | grep -Eo '"is_open":(true|false)' | grep -Eo 'true|false' | head -1)
      next_open=$(echo "$clock" | grep -o '"next_open":"[^"]*"' | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
      et_today=$(TZ=America/New_York date +%F)
      { [ -z "$is_open" ] && [ -z "$next_open" ]; } && exit 0          # unknown → proceed
      { [ "$is_open" != "true" ] && [ "$next_open" != "$et_today" ]; } && exit 1
      exit 0 )
}

# Snapshot one account in an isolated subshell.  $1 = key file  $2 = strategy tag
snapshot() {
    if [ ! -f "$1" ]; then echo "  ($2: no $1 — not active, skipping)"; return; fi
    ( set -a; source "$1"; set +a
      BB_STRATEGY="$2" /usr/bin/python3 scripts/pnl_attribution.py close )
}

if is_trading_day; then
    snapshot "$CFG/alpaca.env"        single
    snapshot "$CFG/alpaca_split.env"  split
    snapshot "$CFG/alpaca_multi.env"  multi
else
    echo "not a trading day — skipping both accounts"
fi
echo "---------------- done $(TZ=America/New_York date '+%T %Z') ----------------"
