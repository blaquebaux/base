# ============================================================================
# LIVE EXECUTION INTEGRATION (draft)
# ----------------------------------------------------------------------------
# Wires the venue-agnostic ExecutionController (module_7) to the live stack:
#   - a venue (IBKRVenue by default)
#   - the execution ledger (module_10 FeedbackLayer) for fill recording (AUDIT-001)
#   - a governance audit sink for halt/resume events (GOV-002)
# and drives the per-rebalance lifecycle: submit governed orders → drain+record fills →
# reconcile against the broker.
#
# NOT a module — include AFTER `using .ExecutionLayer, .FeedbackLayer` are in scope
# (the runner and the integration test both do this). Keeps module_7 decoupled from
# module_8/10: this orchestration file is the only place they meet.
#
# The sizing→targets mapping is the RUNNER's job; this layer consumes `targets`
# (desired signed share positions per symbol) and enforces every order-path invariant.
# ============================================================================

using Dates

# ── Governance audit sink (GOV-002) ────────────────────────────────────────────
# module_8 has no general event log yet, so halt/resume events are appended to a durable
# JSONL. Point this at a module_8 events table when that API exists.
_event_json(e) = "{" * join(["\"$(k)\":\"$(v)\"" for (k, v) in pairs(e)], ",") * "}"
function _audit_sink(path::String)
    mkpath(dirname(path))
    return function (event)
        open(path, "a") do io
            println(io, _event_json(event))
        end
    end
end

"""
    build_live_controller(; venue=nothing, config, ledger_config, audit_path)
      -> (ctrl, ledger, venue)

Construct a fully-wired controller: venue (IBKRVenue unless one is supplied — tests pass a
mock), an open execution ledger, and the governance audit sink. The caller owns lifecycle
(remember `close_ledger(ledger)` on shutdown).
"""
function build_live_controller(; venue = nothing,
                               config::IBKRConfig = IBKRConfig(),
                               ledger_config::LedgerConfig = LedgerConfig(),
                               audit_path::String = joinpath(homedir(), ".blaquebaux", "governance_audit.jsonl"))
    v = venue === nothing ? IBKRVenue(config) : venue
    ledger = open_ledger(ledger_config)
    acct = venue === nothing ? config.account : ""
    ctrl = ExecutionController(v; account = acct, audit = _audit_sink(audit_path))
    return (ctrl = ctrl, ledger = ledger, venue = v)
end

"""
    make_recorder(ledger; mid_prices, adv, sigma) -> Function

Build the `record` callback for `process_fills!`. Maps an enriched fill tuple to a
`FillRecord` (which itself rejects missing lineage — AUDIT-001) and persists it. The
market-impact inputs (mid_price_before, ADV, σ) drive the module_10 cascade-feedback
layer; here they default to safe proxies until real market data is threaded in.
"""
function make_recorder(ledger;
                       mid_prices::AbstractDict = Dict{String,Float64}(),
                       adv::AbstractDict        = Dict{String,Float64}(),
                       sigma::AbstractDict      = Dict{String,Float64}())
    return function (e)
        (e.signal_id === nothing || e.regime === nothing || e.solve_id === nothing) &&
            error("fill missing lineage — refusing to record (REQ-AUDIT-001): order $(e.order_id)")
        fill_id = isempty(e.exec_id) ? "$(e.order_id)-$(abs(hash((e.symbol, e.signed_qty, e.timestamp))))" : e.exec_id
        rec = FillRecord(fill_id, e.symbol, e.timestamp, e.signed_qty, e.fill_price,
                         get(mid_prices, e.symbol, e.fill_price),      # proxy: fill price if no mid available
                         get(adv, e.symbol, 1.0), get(sigma, e.symbol, 0.0);
                         signal_id = e.signal_id, regime = e.regime,
                         solve_id = e.solve_id, order_id = e.order_id)
        record_fill(ledger, rec)
    end
end

"""
    feed_staleness!(ctrl, pool_id; stale, ts=now(UTC))

Feed the DATA-003 gate: mark the pool's data fresh only when it is NOT stale (a stale feed
leaves the timestamp old, so the gate blocks emission for that pool). Requires the pool to
have a staleness threshold set via `set_pool_staleness!`.
"""
function feed_staleness!(ctrl, pool_id::String; stale::Bool, ts::DateTime = now(UTC))
    stale || mark_data_fresh!(ctrl, pool_id; ts = ts)
    return nothing
end

"""
    execute_rebalance!(ctrl, ledger; targets, prices, signal_id, regime, solve_id,
                       pool_id="us", settle_secs=3, recorder=make_recorder(ledger))
      -> (acks, fills, reconciled)

Drive one governed rebalance: for each symbol, order the delta between the target and the
(fill-driven) current position through `submit_governed!`; then drain+record fills and
reconcile against the broker. Idempotency key is `pool|symbol|solve_id`, so re-running the
same solve does not double-submit.
"""
function execute_rebalance!(ctrl, ledger;
                            targets::AbstractDict,
                            prices::AbstractDict = Dict{String,Float64}(),
                            signal_id::String, regime::String, solve_id::String,
                            pool_id::String = "us", settle_secs::Real = 3,
                            recorder = make_recorder(ledger))
    acks = OrderAck[]
    for (sym, tgt) in targets
        cur   = get(ctrl.expected, sym, 0.0)
        delta = tgt - cur
        abs(delta) < 1 && continue                       # whole-share dead zone
        side  = delta > 0 ? :buy : :sell
        qty   = abs(round(Int, delta))
        cid   = "$(pool_id)|$(sym)|$(solve_id)"          # idempotency key: one order per (pool,symbol,solve)
        o = VenueOrder(; client_order_id = cid, symbol = sym, side = side, quantity = qty,
                       order_type = :market, ref_price = get(prices, sym, nothing),
                       pool_id = pool_id, signal_id = signal_id, regime = regime, solve_id = solve_id)
        ack = submit_governed!(ctrl, o)
        push!(acks, ack)
        @info "rebalance order" symbol=sym delta=delta status=ack.status error=ack.error
    end
    settle_secs > 0 && sleep(settle_secs)
    fills = process_fills!(ctrl; record = recorder)
    reconciled = reconcile!(ctrl)
    return (acks = acks, fills = fills, reconciled = reconciled)
end
