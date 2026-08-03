#!/bin/bash
# ============================================================================
# run_spine_split_daily.sh — autonomous daily job for the SPLIT-UNIVERSE spine,
# on a SECOND, isolated Alpaca paper account (true live A/B vs the single spine).
#
# Reads its keys from ~/.config/blaquebaux/alpaca_split.env (the 2nd paper account),
# NOT the single-spine env file. If that file doesn't exist yet, it skips cleanly —
# so you can install the launchd agent now and it activates the day you create the
# account + drop the keys in.
#
# Manual test:  bash scripts/run_spine_split_daily.sh
# ============================================================================
set -uo pipefail

REPO="/Users/malcolmx/blaquebaux"
ENVFILE="$HOME/.config/blaquebaux/alpaca_split.env"    # <- SECOND paper account keys
JULIA="/Users/malcolmx/.juliaup/bin/julia"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/spine_split_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') spine SPLIT daily run ================"

# 1) keys for the 2nd paper account — kept OUT of the repo, chmod 600. Skip cleanly if not set up yet.
if [ ! -f "$ENVFILE" ]; then
    echo "no $ENVFILE yet — split A/B not activated (create the 2nd paper account and add its keys). skipping."
    exit 0
fi
set -a; source "$ENVFILE"; set +a
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
    echo "ALPACA_KEY_ID / ALPACA_SECRET_KEY not set by $ENVFILE"; exit 1
fi

# 2) trading-day gate (same logic as the single job)
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

# 2b) catch-up guard (see run_spine_daily.sh): skip if this account already placed a book today, so
#     multiple morning fire times give at-most-once trading whenever the Mac is next awake.
ORDERS_TODAY=$(curl -s --max-time 15 \
    -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
    "https://paper-api.alpaca.markets/v2/orders?status=all&limit=10&after=${ET_TODAY}T00:00:00Z" \
    | grep -o '"id"' | wc -l | tr -d ' ')
if [ "${ORDERS_TODAY:-0}" -gt 0 ]; then
    echo "already placed $ORDERS_TODAY order(s) today — skipping (catch-up no-op)"; exit 0
fi

# 3) the split-universe spine through the same Layer-3 safety gate (own state/ledger/hwm files).
cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }
"$JULIA" --project=. scripts/spine_live_split.jl
RC=$?

# 4) read-only P&L attribution snapshot, tagged as the "split" strategy/account.
BB_STRATEGY=split /usr/bin/python3 "$REPO/scripts/pnl_attribution.py" open || true

echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
