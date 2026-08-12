#!/bin/bash
# ============================================================================
# run_tactical_book_daily.sh — daily driver for the TACTICAL SLEEVE BOOK (non-keepers: cost-push / beige /
# bulgar), used as designed: small + regime-gated + time-boxed + combined.
#
# Default is DRY-RUN: it checks each sleeve's regime, applies the three rules (10% cap / regime gate /
# time-box), builds the combined market-neutral book, runs the safety gate, and LOGS the netted targets —
# placing NOTHING, and NOT advancing the time-box clock. Uses the shared read-only data keys
# (~/.config/blaquebaux/alpaca.env). To graduate to PAPER, create ~/.config/blaquebaux/alpaca_tactical.env
# with that account's OWN keys and `export BB_TACTICAL_MODE=paper`; the trading-day gate + catch-up
# idempotency guard then apply (same as the keeper/spine wrappers). Real money is out of scope for this wrapper.
#
# Manual test:  bash scripts/run_tactical_book_daily.sh
# ============================================================================
set -uo pipefail
REPO="/Users/malcolmx/blaquebaux"
JULIA="/Users/malcolmx/.juliaup/bin/julia"
DATAENV="$HOME/.config/blaquebaux/alpaca.env"            # shared read-only data keys (dry-run)
TACTICALENV="$HOME/.config/blaquebaux/alpaca_tactical.env" # paper account keys + BB_TACTICAL_MODE=paper (optional)
LOGDIR="$REPO/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/tactical_book_$(TZ=America/New_York date +%Y%m%d).log"

exec >> "$LOG" 2>&1
echo "================ $(TZ=America/New_York date '+%F %T %Z') tactical-book daily run ================"

# tactical-specific, fully isolated persistence (never touches spine or keeper accounts)
export BB_TACTICAL_LEDGER="$REPO/alpaca_ledger_tactical.sqlite"
export BB_TACTICAL_AUDIT="$REPO/alpaca_audit_tactical.jsonl"
export BB_TACTICAL_STATE="$HOME/.config/blaquebaux/tactical_state.jls"   # the time-box clock (per-sleeve)
export BB_TACTICAL_HWM="$HOME/.config/blaquebaux/equity_hwm_tactical.txt"
export BB_TACTICAL_EQUITY="$HOME/.config/blaquebaux/equity_last_tactical.txt"

if [ -f "$TACTICALENV" ]; then
    set -a; source "$TACTICALENV"; set +a       # paper keys + BB_TACTICAL_MODE (expected: paper)
else
    [ -f "$DATAENV" ] && { set -a; source "$DATAENV"; set +a; }
    export BB_TACTICAL_MODE="dryrun"             # no paper account yet -> dry-run (log only, clock not advanced)
fi
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
    echo "no ALPACA keys (need read-only data keys even for dry-run) — skipping"; exit 0
fi
MODE="${BB_TACTICAL_MODE:-dryrun}"
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
"$JULIA" --project=. scripts/tactical_book_live.jl
RC=$?
echo "================ done rc=$RC $(TZ=America/New_York date '+%T %Z') ================"
exit $RC
