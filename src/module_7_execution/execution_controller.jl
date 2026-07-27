# ============================================================================
# EXECUTION CONTROLLER — venue-agnostic governed order path
# ----------------------------------------------------------------------------
# Order-path invariants live here, built ONCE against the ExecutionVenue interface
# so every venue (IBKR now, Alpaca later) inherits them: EXEC-001/002/003,
# AUDIT-001/002, RISK-003/004, DATA-003, GOV-002.
#
# Concurrency (I2): the controller is safe for concurrent pool coroutines. `_lock`
# guards all shared state. It is NEVER held across I/O — venue submit!/positions,
# the ledger `record` callback, or the audit sink — so the kill switch (halt!) can
# never be blocked by an in-flight order (preserves GOV-002 bounded time). Submission
# uses reserve→submit→finalize: the budget is reserved under the lock, the network
# submit runs lock-free, then the reservation is confirmed or rolled back under the lock.
#
# Live-capital use is blocked until the tests (step 6) pass + integration wiring lands.
# ============================================================================

"""
    ExecutionController(venue; account="", recon_tolerance=1e-6, audit=(_->nothing))

Single entry point the engine uses to place orders. All governed invariants are
enforced here; the venue only translates to its broker API. Concurrency-safe.
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
    pool_budgets::Dict{String,Float64}     # pool_id -> max daily gross notional (REQ-RISK-003)
    pool_used::Dict{String,Float64}        # pool_id -> today's reserved/emitted gross notional
    pool_loss_limit::Dict{String,Float64}  # pool_id -> max daily loss, positive (REQ-RISK-004)
    pool_daily_pnl::Dict{String,Float64}   # pool_id -> current daily PnL (engine-supplied)
    halted_pools::Dict{String,String}      # pool_id -> halt reason (per-pool halt)
    symbol_pool::Dict{String,String}       # symbol -> pool_id (for per-pool reconcile halt)
    audit::Function                        # halt/resume audit sink (REQ-GOV-002)
    pool_max_staleness::Dict{String,Millisecond}  # pool_id -> max feed age (REQ-DATA-003)
    pool_data_ts::Dict{String,DateTime}    # pool_id -> last time the pool's feed was fresh
    _lock::ReentrantLock                   # guards all of the above (I2)
end

ExecutionController(v::ExecutionVenue; account::String="", recon_tolerance::Real=1e-6,
                    audit::Function = (_) -> nothing) =
    ExecutionController(v, false, nothing, account,
                        Dict{String,OrderAck}(), Dict{String,NamedTuple}(),
                        Dict{String,Float64}(), float(recon_tolerance),
                        Dict{String,Float64}(), Dict{String,Float64}(),
                        Dict{String,Float64}(), Dict{String,Float64}(),
                        Dict{String,String}(), Dict{String,String}(),
                        audit, Dict{String,Millisecond}(), Dict{String,DateTime}(),
                        ReentrantLock())

# ── Audit (I1: best-effort — a failing sink must never compromise a halt) ───────

function _audit(ctrl::ExecutionController, event)
    try
        ctrl.audit(event)
    catch e
        @error "audit sink threw — halt/resume state still applied (I1)" event=event exception=e
    end
    return nothing
end

# ── Configuration (all short, lock-guarded) ────────────────────────────────────

set_audit_sink!(ctrl::ExecutionController, f::Function) =
    (lock(() -> (ctrl.audit = f), ctrl._lock); nothing)

"Set a pool's max daily gross-notional budget (REQ-RISK-003)."
set_pool_budget!(ctrl::ExecutionController, pool_id::String, cap::Real) =
    (lock(() -> (ctrl.pool_budgets[pool_id] = float(cap)), ctrl._lock); nothing)

"Set a pool's max daily loss (positive number; REQ-RISK-004)."
set_pool_loss_limit!(ctrl::ExecutionController, pool_id::String, limit::Real) =
    (lock(() -> (ctrl.pool_loss_limit[pool_id] = abs(float(limit))), ctrl._lock); nothing)

"Set a pool's maximum acceptable feed staleness (REQ-DATA-003). `max_age` is any Period."
set_pool_staleness!(ctrl::ExecutionController, pool_id::String, max_age::Period) =
    (lock(() -> (ctrl.pool_max_staleness[pool_id] = convert(Millisecond, max_age)), ctrl._lock); nothing)

"Record that a pool's market-data feed is fresh as of `ts` (REQ-DATA-003)."
mark_data_fresh!(ctrl::ExecutionController, pool_id::String; ts::DateTime = now(UTC)) =
    (lock(() -> (ctrl.pool_data_ts[pool_id] = ts), ctrl._lock); nothing)

"""
    rebind_symbol!(ctrl, symbol, pool_id)

Admin override for the durable symbol→pool assignment (H1/J2). A symbol's home pool is set
on its first submission and is intentionally sticky (durable, concurrency-safe). Use this to
correct a mistaken binding — e.g. a symbol first submitted under the wrong pool. Only safe
when no order for `symbol` is in flight.
"""
rebind_symbol!(ctrl::ExecutionController, symbol::String, pool_id::String) =
    (lock(() -> (ctrl.symbol_pool[symbol] = pool_id), ctrl._lock); nothing)

# ── Kill switch (REQ-GOV-002) ──────────────────────────────────────────────────

"""
    halt!(ctrl, reason)  — REQ-GOV-002 kill switch

Stops all new emission. **Bounded time:** sets a flag that `submit_governed!` checks
under the lock, and the lock is never held across I/O — so `halt!` cannot be blocked by an
in-flight order; at most one already-submitted order completes, then no new order starts.
The halt event is sent (best-effort) to the audit sink outside the lock.
"""
function halt!(ctrl::ExecutionController, reason::String)
    lock(ctrl._lock) do
        ctrl.halted = true
        ctrl.halt_reason = reason
    end
    @warn "EXECUTION HALTED (REQ-GOV-002)" reason=reason
    _audit(ctrl, (event=:halt, scope=:global, reason=reason, ts=now(UTC)))
    return nothing
end

function resume!(ctrl::ExecutionController)
    prior = lock(ctrl._lock) do
        p = ctrl.halt_reason
        ctrl.halted = false
        ctrl.halt_reason = nothing
        p
    end
    @warn "EXECUTION RESUMED — logged human re-enable" prior_reason=prior
    _audit(ctrl, (event=:resume, scope=:global, prior_reason=prior, ts=now(UTC)))
    return nothing
end

# ── Per-pool halt & daily loss limit (REQ-RISK-004) ────────────────────────────

"Halt new emission for one pool (per-pool kill). Reason is logged and audited."
function halt_pool!(ctrl::ExecutionController, pool_id::String, reason::String)
    lock(() -> (ctrl.halted_pools[pool_id] = reason), ctrl._lock)
    @warn "POOL HALTED" pool_id=pool_id reason=reason
    _audit(ctrl, (event=:halt, scope=:pool, pool_id=pool_id, reason=reason, ts=now(UTC)))
    return nothing
end

"""
    resume_pool!(ctrl, pool_id)

Explicit, logged human re-enable of a halted pool (REQ-RISK-004 requires the re-enable be
explicit — a new trading day does NOT auto-lift a loss halt).
"""
function resume_pool!(ctrl::ExecutionController, pool_id::String)
    prior = lock(ctrl._lock) do
        p = get(ctrl.halted_pools, pool_id, nothing)
        delete!(ctrl.halted_pools, pool_id)
        p
    end
    @warn "POOL RESUMED — logged human re-enable" pool_id=pool_id prior_reason=prior
    _audit(ctrl, (event=:resume, scope=:pool, pool_id=pool_id, prior_reason=prior, ts=now(UTC)))
    return nothing
end

"""
    update_pnl!(ctrl, pool_id, pnl)

Feed a pool's current daily PnL (the engine computes it from marks/cost basis). If `pnl`
breaches the pool's daily loss limit, the pool is halted until an explicit `resume_pool!`
(REQ-RISK-004).
"""
function update_pnl!(ctrl::ExecutionController, pool_id::String, pnl::Real)
    breach, lim = lock(ctrl._lock) do
        ctrl.pool_daily_pnl[pool_id] = float(pnl)
        l = get(ctrl.pool_loss_limit, pool_id, nothing)
        (l !== nothing && pnl <= -l, l)
    end
    breach && halt_pool!(ctrl, pool_id,
        "daily loss limit breached (REQ-RISK-004): pnl=$(pnl) limit=-$(lim)")
    return nothing
end

"""
    reset_daily!(ctrl)

Start-of-day reset: clear per-pool daily turnover (`pool_used`) and PnL counters. Does NOT
lift halts — a loss-halted or manually-halted pool stays halted until `resume_pool!`.
"""
function reset_daily!(ctrl::ExecutionController)
    lock(ctrl._lock) do
        empty!(ctrl.pool_used)
        empty!(ctrl.pool_daily_pnl)
    end
    @info "daily counters reset (halts NOT lifted — require explicit resume_pool!)"
    return nothing
end

# ── Idempotency / lineage rehydration (REQ-EXEC-002 / AUDIT-001 cross-restart) ──

"""
    rehydrate!(ctrl; seen, lineage)

Restore controller state on startup so a crash-restart neither re-submits orders that
already went out (`seen`) nor loses the ability to tag post-restart fills for pre-restart
orders (`lineage`, G2). The caller reconstructs both from the persisted ledger; full `seen`
reconstruction also needs broker open-orders by `orderRef` (a follow-on).
"""
function rehydrate!(ctrl::ExecutionController;
                    seen::AbstractDict    = Dict{String,OrderAck}(),
                    lineage::AbstractDict = Dict{String,NamedTuple}())
    # AbstractDict (not Dict{String,NamedTuple}): a caller's naturally-built
    # Dict("oid" => (signal_id=...,)) infers a *concrete* NamedTuple value type, which is
    # NOT <: Dict{String,NamedTuple} under Julia's invariant typing. merge! into the
    # controller's Dict{String,NamedTuple}/Dict{String,OrderAck} fields converts fine.
    lock(ctrl._lock) do
        merge!(ctrl.seen, seen)
        merge!(ctrl.lineage, lineage)
    end
    @info "rehydrated controller state" seen=length(seen) lineage=length(lineage)
    return nothing
end

# ── Governed submission ────────────────────────────────────────────────────────

"gate price for notional sizing: the limit price if any, else the decision ref price."
_gate_price(o::VenueOrder) = o.limit_price !== nothing ? o.limit_price : o.ref_price

"""
    submit_governed!(ctrl, order) -> OrderAck

The single governed submission path. Checks (idempotency → global kill → lineage
AUDIT-002 → disjoint-symbol → per-pool halt → staleness DATA-003 → budget RISK-003) and the
budget reservation run atomically under the lock; the network submit runs lock-free; then
the reservation is confirmed (accepted/uncertain) or rolled back (rejected) under the lock.

`liquidation=true` (via `submit_liquidation!`) is a risk-REDUCING emission: it bypasses the
kill switch, per-pool halt, staleness, and budget gates — you must be able to flatten even
when halted / over budget / on stale data — but STILL enforces idempotency and lineage.
"""
function submit_governed!(ctrl::ExecutionController, o::VenueOrder; liquidation::Bool=false)::OrderAck
    # Phase 1 — checks + reservation, atomic under the lock (NO I/O).
    # Returns (ack, _) to short-circuit, or (nothing, notional) to proceed.
    decision = lock(ctrl._lock) do
        # REQ-EXEC-002 — idempotency first: a replay returns its prior ack, never re-submits.
        haskey(ctrl.seen, o.client_order_id) && return (ctrl.seen[o.client_order_id], 0.0)

        # REQ-GOV-002 — global kill switch (bypassed for risk-reducing liquidation).
        !liquidation && ctrl.halted && return (OrderAck(:rejected, "", o.client_order_id,
                                        "HALTED (REQ-GOV-002): $(ctrl.halt_reason)"), 0.0)

        # REQ-AUDIT-002 — lineage is a precondition of emission (always, even liquidation).
        ml = [nm for (nm, v) in (("signal_id", o.signal_id), ("regime", o.regime),
                                 ("solve_id", o.solve_id)) if v === nothing || isempty(v)]
        isempty(ml) || return (OrderAck(:rejected, "", o.client_order_id,
                                        "REJECTED (REQ-AUDIT-002): missing lineage " * join(ml, ", ")), 0.0)

        # H1 — pool-disjoint symbols (check-and-reserve atomically).
        (haskey(ctrl.symbol_pool, o.symbol) && ctrl.symbol_pool[o.symbol] != o.pool_id) &&
            return (OrderAck(:rejected, "", o.client_order_id,
                             "REJECTED: symbol $(o.symbol) already assigned to pool " *
                             "$(ctrl.symbol_pool[o.symbol]); cross-pool symbol reuse is unsupported."), 0.0)

        # REQ-RISK-004 — per-pool halt (bypassed for liquidation).
        !liquidation && haskey(ctrl.halted_pools, o.pool_id) &&
            return (OrderAck(:rejected, "", o.client_order_id,
                             "REJECTED: pool $(o.pool_id) halted — $(ctrl.halted_pools[o.pool_id])"), 0.0)

        # REQ-DATA-003 — stale-feed gate (bypassed for liquidation).
        if !liquidation && haskey(ctrl.pool_max_staleness, o.pool_id)
            age = now(UTC) - get(ctrl.pool_data_ts, o.pool_id, DateTime(0))
            age > ctrl.pool_max_staleness[o.pool_id] &&
                return (OrderAck(:rejected, "", o.client_order_id,
                                 "REJECTED (REQ-DATA-003): pool $(o.pool_id) feed stale — " *
                                 "age $(age) > $(ctrl.pool_max_staleness[o.pool_id])"), 0.0)
        end

        # REQ-RISK-003 — per-pool daily gross-notional budget (bypassed for liquidation).
        notional = 0.0
        if !liquidation && haskey(ctrl.pool_budgets, o.pool_id)
            price = _gate_price(o)
            price === nothing &&
                return (OrderAck(:rejected, "", o.client_order_id,
                                 "REJECTED (REQ-RISK-003): pool $(o.pool_id) has a budget but the order " *
                                 "has no price to size against (set limit_price or ref_price)"), 0.0)
            notional = price * o.quantity
            used = get(ctrl.pool_used, o.pool_id, 0.0)
            used + notional > ctrl.pool_budgets[o.pool_id] &&
                return (OrderAck(:rejected, "", o.client_order_id,
                                 "REJECTED (REQ-RISK-003): pool $(o.pool_id) budget breach — " *
                                 "used $(used) + $(notional) > $(ctrl.pool_budgets[o.pool_id])"), 0.0)
        end

        # Reserve: claim the symbol for its pool and reserve the budget so concurrent
        # submissions can't over-commit. Rolled back below if the venue rejects.
        ctrl.symbol_pool[o.symbol] = o.pool_id
        ctrl.pool_used[o.pool_id]  = get(ctrl.pool_used, o.pool_id, 0.0) + notional
        return (nothing, notional)
    end

    decision[1] !== nothing && return decision[1]::OrderAck
    notional = decision[2]

    # Phase 2 — submit (network I/O; NO controller lock, so the kill switch stays responsive).
    ack = submit!(ctrl.venue, o)

    # Phase 3 — confirm or roll back the reservation, under the lock.
    lock(ctrl._lock) do
        if islocked_id(ack)   # :accepted or :uncertain (may be live) — F2
            ctrl.seen[o.client_order_id] = ack
            if !isempty(ack.venue_order_id)   # oid present for accepted+uncertain (G1)
                ctrl.lineage[ack.venue_order_id] = (
                    signal_id       = o.signal_id,
                    regime          = o.regime,
                    solve_id        = o.solve_id,
                    client_order_id = o.client_order_id,
                )
            end
        else
            # Clean :rejected by the venue — release the budget reservation (a transient
            # daily counter). J2: the symbol_pool binding is NOT rolled back — it is a
            # DURABLE assignment (a symbol's home pool), not a per-order reservation, and
            # rolling it back would be unsafe under concurrency (a parallel same-symbol order
            # may already rely on it). Use rebind_symbol! to correct a mistaken binding.
            ctrl.pool_used[o.pool_id] = get(ctrl.pool_used, o.pool_id, 0.0) - notional
        end
    end
    return ack
end

"""
    submit_liquidation!(ctrl, o) -> OrderAck

Risk-REDUCING emission for emergency flattening. Bypasses the kill switch, per-pool halt,
staleness, and budget gates (you must be able to close positions even when halted / over
budget / on stale data) while still enforcing idempotency and lineage. Use only to reduce
exposure toward zero.
"""
submit_liquidation!(ctrl::ExecutionController, o::VenueOrder)::OrderAck =
    submit_governed!(ctrl, o; liquidation = true)

# ── Locked state accessors (use these instead of reaching into controller fields — L2) ──

"Current fill-driven position for a symbol (locked read)."
expected_position(ctrl::ExecutionController, symbol::String)::Float64 =
    lock(() -> get(ctrl.expected, symbol, 0.0), ctrl._lock)

"Snapshot copy of all fill-driven positions (locked read)."
positions_snapshot(ctrl::ExecutionController)::Dict{String,Float64} =
    lock(() -> copy(ctrl.expected), ctrl._lock)

"The pool a symbol is bound to, or `default` if unbound (locked read)."
pool_of(ctrl::ExecutionController, symbol::String, default::String="")::String =
    lock(() -> get(ctrl.symbol_pool, symbol, default), ctrl._lock)

# ── Fill processing (F1: expected is FILL-driven, not order-driven) ────────────

"""
    apply_fill!(ctrl, symbol, signed_qty)

Update expected position by an actual FILLED quantity (signed). The only thing that moves
`expected` — never submitted order quantity — so reconciliation compares fills-to-fills.
"""
function apply_fill!(ctrl::ExecutionController, symbol::String, signed_qty::Float64)
    lock(ctrl._lock) do
        ctrl.expected[symbol] = get(ctrl.expected, symbol, 0.0) + signed_qty
    end
    return nothing
end

"""
    process_fills!(ctrl; record=(_->nothing)) -> Vector{NamedTuple}

Drain confirmed fills from the venue, tag each with its decision lineage (REQ-AUDIT-001),
persist it via `record`, then update expected from it (F1). Returns the processed fills.

G3 — ordered record-then-apply: if `record` throws for a fill, `expected` is NOT updated,
so the fill surfaces as a `reconcile!` divergence rather than being silently lost; a
per-fill failure does not abort the batch. `record` runs outside the lock (I2). The default
no-op `record` is for reconcile-only / test use.
"""
function process_fills!(ctrl::ExecutionController; record::Function = (_) -> nothing)::Vector{NamedTuple}
    processed = NamedTuple[]
    for f in drain_fills(ctrl.venue)   # venue drains under its own lock; no controller lock here
        is_buy = f.side in ("BOT", "BUY", "buy")   # IBKR side is "BOT"/"SLD"
        signed = (is_buy ? 1.0 : -1.0) * abs(float(f.shares))

        lin = lock(() -> get(ctrl.lineage, string(f.order_id), nothing), ctrl._lock)
        lin === nothing && @error "Fill has no known lineage — cannot be recorded (REQ-AUDIT-001)" order_id=f.order_id symbol=f.symbol
        e = (
            symbol          = f.symbol,
            order_id        = string(f.order_id),
            exec_id         = hasproperty(f, :exec_id) ? string(f.exec_id) : "",  # unique fill id (AUDIT-001 ledger)
            signed_qty      = signed,
            fill_price      = f.fill_price,
            timestamp       = f.timestamp,
            signal_id       = lin === nothing ? nothing : lin.signal_id,
            regime          = lin === nothing ? nothing : lin.regime,
            solve_id        = lin === nothing ? nothing : lin.solve_id,
            client_order_id = lin === nothing ? nothing : lin.client_order_id,
        )
        try
            record(e)                              # persist first (outside the lock — I/O)
            apply_fill!(ctrl, f.symbol, signed)    # then trust expected (self-locks)
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

Compare the controller's (fill-driven) expected positions against broker-reported positions.
On divergence beyond `recon_tolerance`, HALT the affected pool(s) and return false; else true.
A diverging symbol halts its own pool (via `symbol_pool`); an unattributable symbol triggers
a fail-safe controller-wide halt. Broker positions are fetched lock-free; the comparison runs
under the lock; halts happen outside it.

⚠️ Ordering: call `process_fills!` first (or use `process_and_reconcile!`) so `expected`
reflects the latest fills — a stale `expected` will false-halt (fail-safe, but a nuisance).
"""
function reconcile!(ctrl::ExecutionController)::Bool
    broker = positions(ctrl.venue, ctrl.account)   # I/O — no controller lock

    by_pool, unscoped, nchecked = lock(ctrl._lock) do
        bp = Dict{String,Vector{String}}()
        un = String[]
        allkeys = union(keys(ctrl.expected), keys(broker))
        for s in allkeys
            exp = get(ctrl.expected, s, 0.0)
            act = get(broker, s, 0.0)
            if abs(exp - act) > ctrl.recon_tolerance
                msg  = "$s: expected $(exp), broker $(act)"
                pool = get(ctrl.symbol_pool, s, nothing)
                pool === nothing ? push!(un, msg) : push!(get!(bp, pool, String[]), msg)
            end
        end
        (bp, un, length(allkeys))
    end

    if isempty(by_pool) && isempty(unscoped)
        @info "reconciliation ok" symbols_checked=nchecked
        return true
    end
    for (pool, msgs) in by_pool   # halts happen outside the comparison lock
        halt_pool!(ctrl, pool, "position reconciliation divergence (REQ-EXEC-003): " * join(msgs, "; "))
    end
    isempty(unscoped) ||
        halt!(ctrl, "unscoped reconciliation divergence (REQ-EXEC-003): " * join(unscoped, "; "))
    return false
end

"""
    process_and_reconcile!(ctrl; record=(_->nothing)) -> Bool

Convenience: apply the latest fills, then reconcile — the correct order (H3).
"""
function process_and_reconcile!(ctrl::ExecutionController; record::Function = (_) -> nothing)::Bool
    process_fills!(ctrl; record=record)
    return reconcile!(ctrl)
end
