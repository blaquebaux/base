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
    expected::Dict{String,Float64}    # symbol -> signed qty we believe we hold (optimistic)
    recon_tolerance::Float64          # shares; divergence beyond this halts (REQ-EXEC-003)
    # STEP 4: pool_budgets / daily_pnl (REQ-RISK-003/004) — per-pool state, incl. per-pool halt
end

ExecutionController(v::ExecutionVenue; account::String="", recon_tolerance::Real=0.0) =
    ExecutionController(v, false, nothing, account,
                        Dict{String,OrderAck}(), Dict{String,Float64}(), float(recon_tolerance))

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
        return OrderAck(false, "", o.client_order_id,
                        "HALTED (REQ-GOV-002): $(ctrl.halt_reason)")
    end

    # REQ-EXEC-002 — idempotency: never re-submit a client_order_id already accepted.
    # A retry after a reconnect/uncertain ack returns the prior ack instead of a
    # second order. (In-process; cross-restart via rehydrate! from the ledger, step 3.)
    if haskey(ctrl.seen, o.client_order_id)
        @warn "Idempotent replay — returning prior ack, NOT re-submitting (REQ-EXEC-002)" client_order_id=o.client_order_id
        return ctrl.seen[o.client_order_id]
    end

    # ───────────── GOVERNANCE GAPS (hard blockers to going live) ─────────────
    #   REQ-AUDIT-002 [STEP 3]: reject if any of signal_id/regime/solve_id is nothing.
    #   REQ-RISK-003  [STEP 4]: reject if o would breach o.pool_id's budget.
    #   REQ-RISK-004  [STEP 4]: halt o.pool_id if its daily loss limit is breached.
    # ─────────────────────────────────────────────────────────────────────────

    ack = submit!(ctrl.venue, o)

    if ack.accepted
        ctrl.seen[o.client_order_id] = ack
        # Optimistic expected-position update. Authoritative source becomes the fill
        # ledger (module_10) once lineage lands (step 3); until then this is the
        # controller's best estimate for reconciliation.
        signed = o.side === :buy ? o.quantity : -o.quantity
        ctrl.expected[o.symbol] = get(ctrl.expected, o.symbol, 0.0) + signed
    end
    return ack
end

# ── Reconciliation (REQ-EXEC-003) ──────────────────────────────────────────────

"""
    reconcile!(ctrl) -> Bool

Compare the controller's expected positions against broker-reported positions.
On any divergence beyond `recon_tolerance`, HALT and return false; otherwise true.

STEP 2 halts the whole controller (conservative). Per-pool halt arrives with the
per-pool state in step 4. Expected positions are optimistic until the ledger is
authoritative (step 3).
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
