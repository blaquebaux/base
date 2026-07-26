# ============================================================================
# EXECUTION CONTROLLER — venue-agnostic governed order path
# ----------------------------------------------------------------------------
# Order-path invariants live here, built ONCE against the ExecutionVenue
# interface so every venue (IBKR now, Alpaca later) inherits them:
#
#   REQ-EXEC-001  serial submission per pool      (venue-side lock)
#   REQ-EXEC-002  idempotency across reconnects   [STEP 2 — in-process; cross-restart pending ledger]
#   REQ-EXEC-003  position reconciliation         [STEP 2 — expected-vs-broker + halt]
#   REQ-AUDIT-001 fill lineage                     [STEP 3 — FillRecord fields]
#   REQ-AUDIT-002 reject on incomplete lineage    [STEP 3]
#   REQ-RISK-003  per-pool budget gate            [STEP 4]
#   REQ-RISK-004  per-pool daily loss halt        [STEP 4]
#   REQ-GOV-002   kill switch                      [enforced; bounded-time+audit in STEP 5]
#
# Live-capital use is blocked until every [STEP n] gap is closed (HONEST-ASSESSMENT.md).
# ============================================================================

"""
    ExecutionController(venue; account="", recon_tolerance=0.0)

Single entry point the engine uses to place orders. All governed invariants are
enforced here; the venue only translates to its broker API.
"""
mutable struct ExecutionController{V<:ExecutionVenue}
    venue::V
    halted::Bool                      # global kill switch (REQ-GOV-002)
    halt_reason::Union{String,Nothing}
    account::String
    seen::Dict{String,OrderAck}       # REQ-EXEC-002: client_order_id -> ack (in-process dedup)
    lineage::Dict{String,NamedTuple}  # venue_order_id -> (signal_id, regime, solve_id, client_order_id)
    expected::Dict{String,Float64}    # symbol -> signed qty, driven from FILLS (REQ-EXEC-003)
    recon_tolerance::Float64          # shares; divergence beyond this halts
    # ── per-pool state (step 4) ──
    pool_budgets::Dict{String,Float64}     # pool_id -> max daily gross notional (REQ-RISK-003)
    pool_used::Dict{String,Float64}        # pool_id -> today's cumulative gross notional emitted
    pool_loss_limit::Dict{String,Float64}  # pool_id -> max daily loss, positive (REQ-RISK-004)
    pool_daily_pnl::Dict{String,Float64}   # pool_id -> current daily PnL (engine-supplied)
    halted_pools::Dict{String,String}      # pool_id -> halt reason (per-pool halt)
    symbol_pool::Dict{String,String}       # symbol -> pool_id (for per-pool reconcile halt)
end

# recon_tolerance default is a small epsilon (F4): catches any ≥1-share divergence while
# ignoring float-accumulation noise. Raise it for a deliberate business tolerance.
ExecutionController(v::ExecutionVenue; account::String="", recon_tolerance::Real=1e-6) =
    ExecutionController(v, false, nothing, account,
                        Dict{String,OrderAck}(), Dict{String,NamedTuple}(),
                        Dict{String,Float64}(), float(recon_tolerance),
                        Dict{String,Float64}(), Dict{String,Float64}(),
                        Dict{String,Float64}(), Dict{String,Float64}(),
                        Dict{String,String}(), Dict{String,String}())

# ── Per-pool configuration (step 4) ────────────────────────────────────────────

"Set a pool's max daily gross-notional budget (REQ-RISK-003)."
set_pool_budget!(ctrl::ExecutionController, pool_id::String, cap::Real) =
    (ctrl.pool_budgets[pool_id] = float(cap); nothing)

"Set a pool's max daily loss (positive number; REQ-RISK-004)."
set_pool_loss_limit!(ctrl::ExecutionController, pool_id::String, limit::Real) =
    (ctrl.pool_loss_limit[pool_id] = abs(float(limit)); nothing)

# ── Kill switch (REQ-GOV-002) ──────────────────────────────────────────────────

function halt!(ctrl::ExecutionController, reason::String)
    ctrl.halted = true
    ctrl.halt_reason = reason
    @warn "EXECUTION HALTED (REQ-GOV-002)" reason=reason   # STEP 5: also write to governance audit log
    return nothing
end

function resume!(ctrl::ExecutionController)
    @warn "EXECUTION RESUMED — logged human re-enable" prior_reason=ctrl.halt_reason
    ctrl.halted = false
    ctrl.halt_reason = nothing
    return nothing
end

# ── Per-pool halt & daily loss limit (REQ-RISK-004) ────────────────────────────

"Halt new emission for one pool (per-pool kill). Reason is logged and recorded."
function halt_pool!(ctrl::ExecutionController, pool_id::String, reason::String)
    ctrl.halted_pools[pool_id] = reason
    @warn "POOL HALTED" pool_id=pool_id reason=reason   # STEP 5: also to governance audit log
    return nothing
end

"""
    resume_pool!(ctrl, pool_id)

Explicit, logged human re-enable of a halted pool (REQ-RISK-004 requires the re-enable be
explicit — a new trading day does NOT auto-lift a loss halt).
"""
function resume_pool!(ctrl::ExecutionController, pool_id::String)
    prior = get(ctrl.halted_pools, pool_id, nothing)
    delete!(ctrl.halted_pools, pool_id)
    @warn "POOL RESUMED — logged human re-enable" pool_id=pool_id prior_reason=prior
    return nothing
end

"""
    update_pnl!(ctrl, pool_id, pnl)

Feed a pool's current daily PnL (the engine computes it from marks/cost basis — the
controller does not). If `pnl` breaches the pool's daily loss limit, the pool is halted
until an explicit `resume_pool!` (REQ-RISK-004).
"""
function update_pnl!(ctrl::ExecutionController, pool_id::String, pnl::Real)
    ctrl.pool_daily_pnl[pool_id] = float(pnl)
    if haskey(ctrl.pool_loss_limit, pool_id) && pnl <= -ctrl.pool_loss_limit[pool_id]
        halt_pool!(ctrl, pool_id,
                   "daily loss limit breached (REQ-RISK-004): pnl=$(pnl) limit=-$(ctrl.pool_loss_limit[pool_id])")
    end
    return nothing
end

"""
    reset_daily!(ctrl)

Start-of-day reset: clear per-pool daily turnover (`pool_used`) and PnL counters. Does
NOT lift halts — a loss-halted or manually-halted pool stays halted until `resume_pool!`
(REQ-RISK-004: re-enable must be explicit).
"""
function reset_daily!(ctrl::ExecutionController)
    empty!(ctrl.pool_used)
    empty!(ctrl.pool_daily_pnl)
    @info "daily counters reset (halts NOT lifted — require explicit resume_pool!)"
    return nothing
end

# ── Idempotency rehydration (REQ-EXEC-002, cross-restart) ──────────────────────

"""
    rehydrate!(ctrl; seen, lineage)

Restore controller state on startup so a crash-restart neither re-submits orders that
already went out (`seen`, REQ-EXEC-002) nor loses the ability to tag post-restart fills
for pre-restart orders (`lineage`, REQ-AUDIT-001 — G2).

The caller reconstructs these from the persisted execution ledger: `lineage` (order_id →
signal/regime/solve) is fully derivable from the ledger's lineage columns. Full `seen`
reconstruction additionally needs the broker's open-orders matched by `orderRef`
(client_order_id) — a follow-on to this hook.
"""
function rehydrate!(ctrl::ExecutionController;
                    seen::Dict{String,OrderAck}   = Dict{String,OrderAck}(),
                    lineage::Dict{String,NamedTuple} = Dict{String,NamedTuple}())
    merge!(ctrl.seen, seen)
    merge!(ctrl.lineage, lineage)
    @info "rehydrated controller state" seen=length(seen) lineage=length(lineage)
    return nothing
end

# ── Governed submission ────────────────────────────────────────────────────────

"gate price for notional sizing: the limit price if any, else the decision ref price."
_gate_price(o::VenueOrder) = o.limit_price !== nothing ? o.limit_price : o.ref_price

"""
    submit_governed!(ctrl, order) -> OrderAck

The single governed submission path. Checks run in this order:
idempotency → global kill switch → lineage (AUDIT-002) → per-pool halt → per-pool
budget (RISK-003) → submit. Idempotency is first so a replay of an already-sent order
returns its prior ack even while halted (it is not a new emission).
"""
function submit_governed!(ctrl::ExecutionController, o::VenueOrder)::OrderAck
    # REQ-EXEC-002 — idempotency first: a replay returns the prior ack, never re-submits.
    if haskey(ctrl.seen, o.client_order_id)
        @warn "Idempotent replay — returning prior ack, NOT re-submitting (REQ-EXEC-002)" client_order_id=o.client_order_id
        return ctrl.seen[o.client_order_id]
    end

    # REQ-GOV-002 — global kill switch.
    if ctrl.halted
        return OrderAck(:rejected, "", o.client_order_id,
                        "HALTED (REQ-GOV-002): $(ctrl.halt_reason)")
    end

    # REQ-AUDIT-002 — lineage is a precondition of emission; reject if incomplete.
    missing = [nm for (nm, v) in (("signal_id", o.signal_id), ("regime", o.regime),
                                   ("solve_id", o.solve_id)) if v === nothing || isempty(v)]
    if !isempty(missing)
        return OrderAck(:rejected, "", o.client_order_id,
                        "REJECTED (REQ-AUDIT-002): missing lineage " * join(missing, ", "))
    end

    # REQ-RISK-004 (enforcement) — per-pool halt (loss-limit breach or manual pool halt).
    if haskey(ctrl.halted_pools, o.pool_id)
        return OrderAck(:rejected, "", o.client_order_id,
                        "REJECTED: pool $(o.pool_id) halted — $(ctrl.halted_pools[o.pool_id])")
    end

    # REQ-RISK-003 — per-pool daily gross-notional budget, enforced at the gate before emission.
    notional = 0.0
    if haskey(ctrl.pool_budgets, o.pool_id)
        price = _gate_price(o)
        if price === nothing
            return OrderAck(:rejected, "", o.client_order_id,
                            "REJECTED (REQ-RISK-003): pool $(o.pool_id) has a budget but the order " *
                            "has no price to size against (set limit_price or ref_price)")
        end
        notional = price * o.quantity
        used = get(ctrl.pool_used, o.pool_id, 0.0)
        if used + notional > ctrl.pool_budgets[o.pool_id]
            return OrderAck(:rejected, "", o.client_order_id,
                            "REJECTED (REQ-RISK-003): pool $(o.pool_id) budget breach — " *
                            "used $(used) + $(notional) > $(ctrl.pool_budgets[o.pool_id])")
        end
    end

    ack = submit!(ctrl.venue, o)

    # F2 — lock the client_order_id on :accepted OR :uncertain (may be live). Only a clean
    # :rejected leaves the id free to retry.
    if islocked_id(ack)
        ctrl.seen[o.client_order_id] = ack
        ctrl.symbol_pool[o.symbol]   = o.pool_id            # for per-pool reconcile halt
        ctrl.pool_used[o.pool_id]    = get(ctrl.pool_used, o.pool_id, 0.0) + notional  # RISK-003 turnover
        # Record lineage keyed by venue order id so incoming fills can be tagged (REQ-AUDIT-001).
        # Lineage is guaranteed present by the AUDIT-002 gate; oid present for accepted+uncertain (G1).
        if !isempty(ack.venue_order_id)
            ctrl.lineage[ack.venue_order_id] = (
                signal_id       = o.signal_id,
                regime          = o.regime,
                solve_id        = o.solve_id,
                client_order_id = o.client_order_id,
            )
        end
    end
    return ack
end

# ── Fill processing (F1: expected is FILL-driven, not order-driven) ────────────

"""
    apply_fill!(ctrl, symbol, signed_qty)

Update expected position by an actual FILLED quantity (signed). This is the only
thing that moves `expected` — never submitted order quantity — so reconciliation
compares fills-to-fills against the broker (fixes F1).
"""
function apply_fill!(ctrl::ExecutionController, symbol::String, signed_qty::Float64)
    ctrl.expected[symbol] = get(ctrl.expected, symbol, 0.0) + signed_qty
    return nothing
end

"""
    process_fills!(ctrl; record=(_->nothing)) -> Vector{NamedTuple}

Drain confirmed fills from the venue, tag each with its decision lineage (looked up by
venue order id, REQ-AUDIT-001), persist it via `record`, and only then update expected
positions from it (F1). Returns the successfully-processed fills.

G3 — persistence and the expected-position update are coupled here and ordered
**record-then-apply**: if `record` throws for a fill, `expected` is NOT updated for it, so
the fill surfaces as a broker-vs-expected divergence in `reconcile!` (a halt) rather than
being silently lost. A per-fill failure does not abort the rest of the batch. The default
no-op `record` is for reconcile-only / test use; the daily runner passes a real recorder
that builds a `FillRecord` (which itself rejects missing lineage) and calls `record_fill`.
"""
function process_fills!(ctrl::ExecutionController; record::Function = (_) -> nothing)::Vector{NamedTuple}
    processed = NamedTuple[]
    for f in drain_fills(ctrl.venue)
        # IBKR execution.side is "BOT"/"SLD"; accept BUY/SELL too for other venues.
        is_buy = f.side in ("BOT", "BUY", "buy")
        signed = (is_buy ? 1.0 : -1.0) * abs(float(f.shares))

        lin = get(ctrl.lineage, string(f.order_id), nothing)
        if lin === nothing
            @error "Fill has no known lineage — cannot be recorded (REQ-AUDIT-001)" order_id=f.order_id symbol=f.symbol
        end
        e = (
            symbol          = f.symbol,
            order_id        = string(f.order_id),
            signed_qty      = signed,
            fill_price      = f.fill_price,
            timestamp       = f.timestamp,
            signal_id       = lin === nothing ? nothing : lin.signal_id,
            regime          = lin === nothing ? nothing : lin.regime,
            solve_id        = lin === nothing ? nothing : lin.solve_id,
            client_order_id = lin === nothing ? nothing : lin.client_order_id,
        )
        try
            record(e)                              # persist first
            apply_fill!(ctrl, f.symbol, signed)    # then trust expected
            push!(processed, e)
        catch err
            @error "fill record failed — expected NOT updated; reconcile! will surface it" order_id=e.order_id exception=err
        end
    end
    return processed
end

# ── Reconciliation (REQ-EXEC-003) ──────────────────────────────────────────────

"""
    reconcile!(ctrl) -> Bool

Compare the controller's (fill-driven) expected positions against broker-reported
positions. On divergence beyond `recon_tolerance`, HALT the affected pool(s) and return
false; else true. Call `process_fills!` first so `expected` reflects the latest fills.

Per-pool (step 4): a diverging symbol halts its own pool (via `symbol_pool`); a diverging
symbol with no known pool triggers a controller-wide halt (fail-safe — we can't scope it).
"""
function reconcile!(ctrl::ExecutionController)::Bool
    broker = positions(ctrl.venue, ctrl.account)
    by_pool = Dict{String,Vector{String}}()   # pool_id -> divergence messages
    unscoped = String[]                        # symbols with no known pool
    for s in union(keys(ctrl.expected), keys(broker))
        exp = get(ctrl.expected, s, 0.0)
        act = get(broker, s, 0.0)
        if abs(exp - act) > ctrl.recon_tolerance
            msg = "$s: expected $(exp), broker $(act)"
            pool = get(ctrl.symbol_pool, s, nothing)
            if pool === nothing
                push!(unscoped, msg)
            else
                push!(get!(by_pool, pool, String[]), msg)
            end
        end
    end

    if isempty(by_pool) && isempty(unscoped)
        @info "reconciliation ok" symbols_checked=length(union(keys(ctrl.expected), keys(broker)))
        return true
    end

    for (pool, msgs) in by_pool
        halt_pool!(ctrl, pool, "position reconciliation divergence (REQ-EXEC-003): " * join(msgs, "; "))
    end
    if !isempty(unscoped)
        # Can't attribute to a pool → conservative controller-wide halt.
        halt!(ctrl, "unscoped reconciliation divergence (REQ-EXEC-003): " * join(unscoped, "; "))
    end
    return false
end
