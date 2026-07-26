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
    halted::Bool
    halt_reason::Union{String,Nothing}
    account::String
    seen::Dict{String,OrderAck}       # REQ-EXEC-002: client_order_id -> ack (in-process dedup)
    lineage::Dict{String,NamedTuple}  # venue_order_id -> (signal_id, regime, solve_id, client_order_id)
    expected::Dict{String,Float64}    # symbol -> signed qty, driven from FILLS (REQ-EXEC-003)
    recon_tolerance::Float64          # shares; divergence beyond this halts
    # STEP 4: pool_budgets / daily_pnl (REQ-RISK-003/004) — per-pool state, incl. per-pool halt
end

# recon_tolerance default is a small epsilon (F4): catches any ≥1-share divergence while
# ignoring float-accumulation noise. Raise it for a deliberate business tolerance.
ExecutionController(v::ExecutionVenue; account::String="", recon_tolerance::Real=1e-6) =
    ExecutionController(v, false, nothing, account,
                        Dict{String,OrderAck}(), Dict{String,NamedTuple}(),
                        Dict{String,Float64}(), float(recon_tolerance))

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

# ── Idempotency rehydration (REQ-EXEC-002, cross-restart) ──────────────────────

"""
    rehydrate!(ctrl, prior::Dict{String,OrderAck})

Restore the seen-set on startup so a crash-restart does not re-submit orders that
already went out. STEP 2 provides the hook; STEP 3 populates `prior` from the
persisted execution ledger (client_order_id ⇔ orderRef ⇔ fill lineage).
"""
function rehydrate!(ctrl::ExecutionController, prior::Dict{String,OrderAck})
    merge!(ctrl.seen, prior)
    @info "rehydrated idempotency set" n=length(prior)
    return nothing
end

# ── Governed submission ────────────────────────────────────────────────────────

"""
    submit_governed!(ctrl, order) -> OrderAck

The single governed submission path. STEP 2 enforces the kill switch and
idempotency; lineage (STEP 3) and budget/loss (STEP 4) gaps are marked below.
"""
function submit_governed!(ctrl::ExecutionController, o::VenueOrder)::OrderAck
    # REQ-GOV-002 — kill switch
    if ctrl.halted
        return OrderAck(:rejected, "", o.client_order_id,
                        "HALTED (REQ-GOV-002): $(ctrl.halt_reason)")
    end

    # REQ-EXEC-002 — idempotency: never re-submit a client_order_id already accepted.
    # A retry after a reconnect/uncertain ack returns the prior ack instead of a
    # second order. (In-process; cross-restart via rehydrate! from the ledger, step 3.)
    if haskey(ctrl.seen, o.client_order_id)
        @warn "Idempotent replay — returning prior ack, NOT re-submitting (REQ-EXEC-002)" client_order_id=o.client_order_id
        return ctrl.seen[o.client_order_id]
    end

    # REQ-AUDIT-002 — lineage is a precondition of emission, not an annotation. Reject any
    # order missing signal_id/regime/solve_id at the gate; never log-and-send. (Completes
    # the enforcement complement to REQ-AUDIT-001's fill-lineage requirement.)
    missing = [nm for (nm, v) in (("signal_id", o.signal_id), ("regime", o.regime),
                                   ("solve_id", o.solve_id)) if v === nothing || isempty(v)]
    if !isempty(missing)
        return OrderAck(:rejected, "", o.client_order_id,
                        "REJECTED (REQ-AUDIT-002): missing lineage " * join(missing, ", "))
    end

    # ───────────── GOVERNANCE GAPS (hard blockers to going live) ─────────────
    #   REQ-RISK-003  [STEP 4]: reject if o would breach o.pool_id's budget.
    #   REQ-RISK-004  [STEP 4]: halt o.pool_id if its daily loss limit is breached.
    # ─────────────────────────────────────────────────────────────────────────

    ack = submit!(ctrl.venue, o)

    # F2 — lock the client_order_id if the order is accepted OR uncertain (may be live).
    # Only a clean :rejected leaves the id free to retry. This closes the within-session
    # ack-loss double-submit, not just the cross-restart case.
    if islocked_id(ack)
        ctrl.seen[o.client_order_id] = ack
        # Record lineage keyed by venue order id so incoming fills can be tagged
        # (REQ-AUDIT-001). Lineage is guaranteed present here by the AUDIT-002 gate above.
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
    process_fills!(ctrl) -> Vector{NamedTuple}

Drain confirmed fills from the venue, update expected positions from them (F1), and
return each fill tagged with its decision lineage (looked up by venue order id). The
caller records these to the execution ledger — and because `FillRecord` requires
non-empty lineage (REQ-AUDIT-001), a fill whose lineage is missing here (logged as an
error) cannot be silently recorded.
"""
function process_fills!(ctrl::ExecutionController)::Vector{NamedTuple}
    enriched = NamedTuple[]
    for f in drain_fills(ctrl.venue)
        # IBKR execution.side is "BOT"/"SLD"; accept BUY/SELL too for other venues.
        is_buy = f.side in ("BOT", "BUY", "buy")
        signed = (is_buy ? 1.0 : -1.0) * abs(float(f.shares))
        apply_fill!(ctrl, f.symbol, signed)

        lin = get(ctrl.lineage, string(f.order_id), nothing)
        if lin === nothing
            @error "Fill has no known lineage — cannot be recorded (REQ-AUDIT-001)" order_id=f.order_id symbol=f.symbol
        end
        push!(enriched, (
            symbol          = f.symbol,
            order_id        = string(f.order_id),
            signed_qty      = signed,
            fill_price      = f.fill_price,
            timestamp       = f.timestamp,
            signal_id       = lin === nothing ? nothing : lin.signal_id,
            regime          = lin === nothing ? nothing : lin.regime,
            solve_id        = lin === nothing ? nothing : lin.solve_id,
            client_order_id = lin === nothing ? nothing : lin.client_order_id,
        ))
    end
    return enriched
end

# ── Reconciliation (REQ-EXEC-003) ──────────────────────────────────────────────

"""
    reconcile!(ctrl) -> Bool

Compare the controller's (fill-driven) expected positions against broker-reported
positions. On any divergence beyond `recon_tolerance`, HALT and return false; else true.

Call `process_fills!` first so `expected` reflects the latest fills. Halt is currently
controller-wide; per-pool halt arrives with the per-pool state in step 4.
"""
function reconcile!(ctrl::ExecutionController)::Bool
    broker = positions(ctrl.venue, ctrl.account)
    divergences = String[]
    for s in union(keys(ctrl.expected), keys(broker))
        exp = get(ctrl.expected, s, 0.0)
        act = get(broker, s, 0.0)
        if abs(exp - act) > ctrl.recon_tolerance
            push!(divergences, "$s: expected $(exp), broker $(act)")
        end
    end
    if !isempty(divergences)
        halt!(ctrl, "position reconciliation divergence (REQ-EXEC-003): " * join(divergences, "; "))
        return false
    end
    @info "reconciliation ok" symbols_checked=length(union(keys(ctrl.expected), keys(broker)))
    return true
end
