#!/usr/bin/env julia
# ============================================================================
# IBKR PAPER GATEWAY SMOKE TEST
# ----------------------------------------------------------------------------
# Verifies the Jib adapter end-to-end against a running IB Gateway / TWS PAPER
# session — the runtime half of #4 that cannot be checked offline. Exercises the
# REAL governed path: connect → submit_governed! → process_fills! → reconcile!.
#
# SAFETY: refuses to run unless
#   (1) env BB_PAPER_SMOKE_CONFIRM=yes, and
#   (2) the configured port is a known PAPER port (7497 TWS-paper / 4002 GW-paper).
# It places ONE tiny market order (default 1 share of a liquid ETF) on PAPER only.
#
# Usage:
#   export BB_PAPER_SMOKE_CONFIRM=yes
#   export IBKR_PORT=7497            # or 4002 for IB Gateway paper
#   export IBKR_ACCOUNT=DU1234567    # your paper account id
#   julia --project=. scripts/ibkr_paper_smoke.jl [SYMBOL] [QTY]
# ============================================================================

using Dates

include("../src/module_7_execution/module_7_execution.jl")
using .ExecutionLayer

const PAPER_PORTS = (7497, 4002)
const SYMBOL = length(ARGS) >= 1 ? ARGS[1] : "SPY"
const QTY    = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1

function main()
    get(ENV, "BB_PAPER_SMOKE_CONFIRM", "") == "yes" ||
        error("Refusing to run: set BB_PAPER_SMOKE_CONFIRM=yes to confirm this is a PAPER test.")
    cfg = IBKRConfig()
    cfg.port in PAPER_PORTS ||
        error("Refusing to run: IBKR_PORT=$(cfg.port) is not a known paper port $(PAPER_PORTS). " *
              "This smoke test is PAPER-ONLY.")
    @info "Paper smoke test starting" host=cfg.host port=cfg.port account=cfg.account symbol=SYMBOL qty=QTY

    venue = IBKRVenue(cfg)
    ctrl  = ExecutionController(venue; account = cfg.account)

    # 1. connect
    connect!(venue) || error("connect! failed — is IB Gateway/TWS running with the API enabled on port $(cfg.port)?")
    @info "✓ connected"

    # 2. broker positions (verifies reqPositions + the position callback)
    pos = positions(venue, cfg.account)
    @info "✓ positions snapshot" n=length(pos) positions=pos

    # 3. one tiny governed order (budget + lineage set so the gates pass)
    set_pool_budget!(ctrl, "smoke", 1_000_000.0)
    o = VenueOrder(; client_order_id = "smoke-$(Dates.format(now(UTC), "yyyymmddHHMMSS"))",
                   symbol = SYMBOL, side = :buy, quantity = QTY, order_type = :market,
                   ref_price = 1000.0, pool_id = "smoke",
                   signal_id = "smoke", regime = "smoke", solve_id = "smoke")
    ack = submit_governed!(ctrl, o)
    @info "submit_governed! returned" status=ack.status venue_order_id=ack.venue_order_id error=ack.error
    ack.status == :accepted || @warn "order not accepted — check the reason above"

    # 4. wait for the fill, then drain + reconcile
    sleep(5)
    fills = process_fills!(ctrl)
    @info "✓ fills drained" n=length(fills) fills=fills
    ok = reconcile!(ctrl)
    @info (ok ? "✓ reconciliation OK" : "⚠ reconciliation halted (expected if the fill just landed and broker snapshot lags)") halted=ctrl.halted

    disconnect!(venue)
    @info "✓ disconnected — smoke test complete"
    println("\nSMOKE TEST DONE. Review the log above: connect, positions, order status, fill, reconcile.")
end

main()
