#!/usr/bin/env bash
# =============================================================================
# launch_dashboard.sh — Start both the Julia portfolio server and Dash dashboard
#
# Usage:
#   chmod +x scripts/launch_dashboard.sh
#   ./scripts/launch_dashboard.sh
#
# Environment variables:
#   MASSIVE_API_KEY   — Massive.com API key (falls back to yfinance if unset)
#   JULIA_PORT        — Julia server port (default: 8766)
#   DASH_PORT         — Dashboard port   (default: 8050)
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
JULIA_PORT="${JULIA_PORT:-8766}"
DASH_PORT="${DASH_PORT:-8050}"

echo "╔══════════════════════════════════════════════════════╗"
echo "║       BLAQUE BAUX  —  Portfolio Dashboard            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Julia API  → http://127.0.0.1:${JULIA_PORT}               ║"
echo "║  Dashboard  → http://127.0.0.1:${DASH_PORT}               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_DIR"

# ── 1. Start Julia portfolio server in background ────────────────────────────
echo "[1/2] Starting Julia portfolio server on port ${JULIA_PORT}…"
julia --project=. scripts/portfolio_server.jl --port "$JULIA_PORT" &
JULIA_PID=$!
echo "      Julia PID: $JULIA_PID"

# Wait for Julia to be ready (warm-up takes ~15s first run, ~5s after precompile)
echo "      Waiting for Julia server to warm up…"
for i in $(seq 1 60); do
    if curl -s "http://127.0.0.1:${JULIA_PORT}/health" > /dev/null 2>&1; then
        echo "      Julia server ready ✓"
        break
    fi
    sleep 2
done

# ── 2. Start Dash dashboard ──────────────────────────────────────────────────
echo "[2/2] Starting Dash dashboard on port ${DASH_PORT}…"
conda run -n ml \
    env JULIA_URL="http://127.0.0.1:${JULIA_PORT}" DASH_PORT="$DASH_PORT" \
    python scripts/dashboard.py &
DASH_PID=$!
echo "      Dash PID: $DASH_PID"

echo ""
echo "Dashboard running at http://127.0.0.1:${DASH_PORT}"
echo "Press Ctrl+C to stop both servers."
echo ""

# ── Trap Ctrl+C to cleanly shut down both processes ─────────────────────────
trap "echo ''; echo 'Shutting down…'; kill $JULIA_PID $DASH_PID 2>/dev/null; exit 0" INT TERM

wait
