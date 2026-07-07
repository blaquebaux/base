"""
blaque_baux/run_live.py
────────────────────────
Blaque Baux live / paper trading entry point.

Usage:
    python run_live.py                     # Phase 3: US equity + commodities, PAPER
    python run_live.py --phase 4           # Global deployment, PAPER
    python run_live.py --phase 5           # Full system incl. 0DTE, PAPER
    python run_live.py --live              # *** LIVE TRADING *** (requires --confirm)
    python run_live.py --live --confirm    # Actually enables live trading
    python run_live.py --pool equities_us  # Single pool test
    python run_live.py --dry-run           # Log orders without submitting

Prerequisites:
    1. Phase 1 completed: results/phase1_results.json exists
    2. Factor accuracy >= 58% (Phase 2 gate passed)
    3. IBKR TWS or Gateway running on localhost
    4. POLYGON_API_KEY set in .env

IBKR setup checklist:
    [ ] TWS or IB Gateway installed and running
    [ ] API enabled: Configure → API → Settings → Enable ActiveX and Socket Clients
    [ ] Socket port: 7497 (paper) or 7496 (live)
    [ ] Allow connections from localhost (127.0.0.1)
    [ ] Master API client ID: 0
    [ ] ib_insync installed: pip install ib_insync
    [ ] Paper account funded with test capital
"""

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  [%(name)s]  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


def parse_args():
    p = argparse.ArgumentParser(description="Blaque Baux — Live / Paper Trading")
    p.add_argument("--phase",   type=int, default=3,
                   help="Trading phase (3=US, 4=global, 5=full)")
    p.add_argument("--pool",    type=str, default=None,
                   help="Single pool to run (for testing)")
    p.add_argument("--live",    action="store_true",
                   help="Enable live trading (requires --confirm)")
    p.add_argument("--confirm", action="store_true",
                   help="Confirm live trading (required with --live)")
    p.add_argument("--dry-run", action="store_true",
                   help="Log orders without submitting to IBKR")
    return p.parse_args()


def check_phase1_gate():
    """Verify Phase 1 has completed and accuracy gate was passed."""
    results_path = Path("results/phase1_results.json")
    if not results_path.exists():
        print("\n" + "=" * 60)
        print("  Phase 1 not completed.")
        print("  Run: python run_phase1.py")
        print("  Phase 1 must validate factor accuracy before live trading.")
        print("=" * 60 + "\n")
        sys.exit(1)

    with open(results_path) as f:
        results = json.load(f)

    gate = results.get("phase2_gate", {})
    accuracy = gate.get("realized_accuracy", 0)
    passed   = gate.get("gate_passed", False)

    print(f"\n  Phase 1 results loaded:")
    print(f"  Realized factor accuracy: {accuracy:.1%}")
    print(f"  Phase 2 gate (58%):       {'PASSED ✓' if passed else 'NOT MET ✗'}")

    if not passed:
        print("\n  Factor accuracy below 58% threshold.")
        print("  Review signal_analysis.png and tune config.py before proceeding.")
        sys.exit(1)

    return accuracy


async def main():
    args = parse_args()

    # Safety gate: live trading requires explicit confirmation
    paper_mode = True
    if args.live:
        if not args.confirm:
            print("\n⚠️  LIVE TRADING requires --confirm flag.")
            print("   This will place real orders with real money.")
            print("   Use: python run_live.py --live --confirm")
            sys.exit(1)
        paper_mode = False
        print("\n" + "!" * 60)
        print("  *** LIVE TRADING MODE ENABLED ***")
        print("  Real orders will be placed.")
        print("!" * 60 + "\n")
    else:
        print("\n  Paper trading mode (default)")

    # Phase 1 gate check
    accuracy = check_phase1_gate()
    print(f"\n  Starting Blaque Baux Phase {args.phase}")
    print(f"  Factor accuracy: {accuracy:.1%} (from Phase 1 backtest)")

    # Pool filter
    pool_filter = [args.pool] if args.pool else None

    # Start coordinator
    from orchestration.coordinator import Coordinator
    coordinator = Coordinator(
        phase       = args.phase,
        paper_mode  = paper_mode,
        pool_filter = pool_filter,
    )

    await coordinator.start()

    # Run until signal
    try:
        while True:
            await asyncio.sleep(60)
            status = coordinator.status()
            active_pools = [p for p, s in status["pools"].items() if s == "active"]
            logger.info(
                f"Status | Active pools: {active_pools} | "
                f"Bus: {'online' if status['bus_online'] else 'local'}"
            )
    except asyncio.CancelledError:
        pass
    finally:
        await coordinator.stop()


if __name__ == "__main__":
    asyncio.run(main())
