#!/bin/bash
# ============================================================================
# run_spine_multi_daily.sh — THIRD paper account: the SINGLE 6-asset universe with the
# MULTI-HORIZON trend (BB_TREND_MODE=multi). The clean A/B leg vs account #1 (single, sign):
# same universe, only the trend construction differs. Own keys + fully isolated state / ledger /
# audit / HWM / equity files (env-overridden on the shared spine_live.jl driver). Skips cleanly
# until ~/.config/blaquebaux/alpaca_multi.env exists.
#
# Manual test:  bash scripts/run_spine_multi_daily.sh
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
ENVFILE="$HOME/.config/blaquebaux/alpaca_multi.env"   # <- THIRD paper account keys
JULIA="/Users/malcolmx/.juliaup/bin/julia"
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/spine_multi_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') spine MULTI (single+multi) daily run ================"

if [ ! -f "$ENVFILE" ]; then
    echo "no $ENVFILE yet — single-multi A/B not activated (create the 3rd paper account, add its keys). skipping."
    exit 0
fi
set -a; source "$ENVFILE"; set +a
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
    echo "ALPACA_KEY_ID / ALPACA_SECRET_KEY not set by $ENVFILE"; exit 1
fi

# this leg's flags + fully isolated persistence (so it can't touch accounts #1/#2 state)
export BB_TREND_MODE=multi
export BB_STRATEGY=multi
export BB_STATE_PATH="$REPO/spine_state_multi.jls"
export BB_LEDGER_PATH="$REPO/alpaca_ledger_multi.sqlite"
export BB_AUDIT_PATH="$REPO/alpaca_audit_multi.jsonl"
export BB_HWM_PATH="$HOME/.config/blaquebaux/equity_hwm_multi.txt"
export BB_EQUITY_PATH="$HOME/.config/blaquebaux/equity_last_multi.txt"

# trading-day gate
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

# catch-up guard: no-op if this account already placed a book today
ORDERS_TODAY=$(curl -s --max-time 15 \
    -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
    "https://paper-api.alpaca.markets/v2/orders?status=all&limit=10&after=${ET_TODAY}T00:00:00Z" \
    | grep -o '"id"' | wc -l | tr -d ' ')
if [ "${ORDERS_TODAY:-0}" -gt 0 ]; then
    echo "already placed $ORDERS_TODAY order(s) today — skipping (catch-up no-op)"; exit 0
fi

cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }
"$JULIA" --project=. scripts/spine_live.jl
RC=$?
BB_STRATEGY=multi /usr/bin/python3 "$REPO/scripts/pnl_attribution.py" open || true
echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
