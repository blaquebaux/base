#!/bin/bash
# ============================================================================
# run_keeper_book_daily.sh — daily driver for the diversified KEEPER BOOK.
#
# Default is DRY-RUN: it computes the book (spine + CRACK/BORE/TREND, risk-parity), runs the
# safety gate, and LOGS the netted targets — placing NOTHING. It uses the shared read-only data
# keys (~/.config/blaquebaux/alpaca.env) so the book is logged daily even before a paper account
# exists. To graduate to PAPER, create ~/.config/blaquebaux/alpaca_keeper.env with that account's
# OWN keys and `export BB_KEEPER_MODE=paper`; the trading-day gate + catch-up idempotency guard
# then apply (same as the spine wrappers). Real money is out of scope for this wrapper.
#
# Manual test:  bash scripts/run_keeper_book_daily.sh
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
JULIA="/Users/malcolmx/.juliaup/bin/julia"
DATAENV="$HOME/.config/blaquebaux/alpaca.env"          # shared read-only data keys (dry-run)
KEEPERENV="$HOME/.config/blaquebaux/alpaca_keeper.env" # paper account keys + BB_KEEPER_MODE=paper (optional)
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/keeper_book_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') keeper-book daily run ================"

# keeper-specific, fully isolated persistence (never touches spine accounts)
export BB_KEEPER_LEDGER="$REPO/alpaca_ledger_keeper.sqlite"
export BB_KEEPER_AUDIT="$REPO/alpaca_audit_keeper.jsonl"
export BB_KEEPER_HWM="$HOME/.config/blaquebaux/equity_hwm_keeper.txt"
export BB_KEEPER_EQUITY="$HOME/.config/blaquebaux/equity_last_keeper.txt"

if [ -f "$KEEPERENV" ]; then
    set -a; source "$KEEPERENV"; set +a       # paper keys + BB_KEEPER_MODE (expected: paper)
else
    [ -f "$DATAENV" ] && { set -a; source "$DATAENV"; set +a; }
    export BB_KEEPER_MODE="dryrun"             # no paper account yet -> dry-run (log only)
fi
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
    echo "no ALPACA keys (need read-only data keys even for dry-run) — skipping"; exit 0
fi
MODE="${BB_KEEPER_MODE:-dryrun}"
echo "mode=$MODE"

# trading-day gate + catch-up idempotency guard apply only when actually placing paper orders
if [ "$MODE" = "paper" ]; then
    CLOCK=$(curl -s --max-time 15 -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
        https://paper-api.alpaca.markets/v2/clock)
    IS_OPEN=$(echo "$CLOCK" | grep -Eo '"is_open":(true|false)' | grep -Eo 'true|false' | head -1)
    NEXT_OPEN=$(echo "$CLOCK" | grep -o '"next_open":"[^"]*"' | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    ET_TODAY=$(TZ=America/New_York date +%F)
    if [ -z "$IS_OPEN" ] && [ -z "$NEXT_OPEN" ]; then
        echo "WARN: could not read Alpaca clock — proceeding (idempotency still protects)"
    elif [ "$IS_OPEN" != "true" ] && [ "$NEXT_OPEN" != "$ET_TODAY" ]; then
        echo "not a trading day (is_open=$IS_OPEN, next_open=$NEXT_OPEN) — skipping"; exit 0
    fi
    ORDERS_TODAY=$(curl -s --max-time 15 -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
        "https://paper-api.alpaca.markets/v2/orders?status=all&limit=10&after=${ET_TODAY}T00:00:00Z" \
        | grep -o '"id"' | wc -l | tr -d ' ')
    if [ "${ORDERS_TODAY:-0}" -gt 0 ]; then
        echo "already placed $ORDERS_TODAY order(s) today — skipping (catch-up no-op)"; exit 0
    fi
fi

cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }
"$JULIA" --project=. scripts/keeper_book_live.jl
RC=$?
echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
