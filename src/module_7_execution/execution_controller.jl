# ============================================================================
# EXECUTION CONTROLLER — venue-agnostic governed order path
# ----------------------------------------------------------------------------
# This is where the ORDER-PATH INVARIANTS live, built ONCE against the
# ExecutionVenue interface so every venue (IBKR now, Alpaca later) inherits them:
#
#   REQ-EXEC-001  serial submission per pool      (venue-side lock + here)
#   REQ-EXEC-002  idempotency across reconnects   [STEP 2 — not yet built]
#   REQ-EXEC-003  position reconciliation         [STEP 2 — not yet built]
#   REQ-AUDIT-001 fill lineage                     [STEP 3 — depends on FillRecord fields]
#   REQ-AUDIT-002 reject on incomplete lineage    [STEP 3 — not yet built]
#   REQ-RISK-003  per-pool budget gate            [STEP 4 — not yet built]
#   REQ-RISK-004  per-pool daily loss halt        [STEP 4 — not yet built]
#   REQ-GOV-002   kill switch                      [STEP 5 — seed below]
#
# STEP 1 (this file): skeleton. Routes to the venue with the kill switch wired
# and every remaining invariant marked as an explicit GOVERNANCE GAP. The engine
# MUST NOT trade live capital until every gap below is closed (HONEST-ASSESSMENT.md).
# ============================================================================

"""
    ExecutionController(venue)

Wraps an `ExecutionVenue` and is the single entry point the engine uses to
place orders. All governed invariants are enforced here.
"""
mutable struct ExecutionController{V<:ExecutionVenue}
    venue::V
    halted::Bool          # REQ-GOV-002 kill switch
    halt_reason::Union{String,Nothing}
    # STEP 2: seen_client_ids::Set{String}         (REQ-EXEC-002 idempotency)
    # STEP 4: pool_budgets::Dict{String,Float64}   (REQ-RISK-003)
    # STEP 4: daily_pnl::Dict{String,Float64}      (REQ-RISK-004)
end
ExecutionController(v::ExecutionVenue) = ExecutionController(v, false, nothing)

"""
    halt!(ctrl, reason) — REQ-GOV-002

Manual kill switch. Stops all new emission. The halt event is logged; wiring it
into the governance audit log (bounded-time guarantee) is completed in STEP 5.
"""
function halt!(ctrl::ExecutionController, reason::String)
    ctrl.halted = true
    ctrl.halt_reason = reason
    @warn "EXECUTION HALTED (REQ-GOV-002)" reason=reason  # STEP 5: also write to governance audit log
    return nothing
end

"""
    resume!(ctrl) — clears the kill switch (logged human re-enable, cf. REQ-RISK-004).
"""
function resume!(ctrl::ExecutionController)
    @warn "EXECUTION RESUMED" prior_reason=ctrl.halt_reason
    ctrl.halted = false
    ctrl.halt_reason = nothing
    return nothing
end

"""
    submit_governed!(ctrl, order) -> OrderAck

The single governed submission path. STEP 1 enforces only the kill switch;
the remaining invariants are explicit gaps below and are enforced in later steps.
"""
function submit_governed!(ctrl::ExecutionController, o::VenueOrder)::OrderAck
    # REQ-GOV-002 — kill switch (enforced now)
    if ctrl.halted
        return OrderAck(false, "", o.client_order_id,
                        "HALTED (REQ-GOV-002): $(ctrl.halt_reason)")
    end

    # ───────────────────────── GOVERNANCE GAPS ─────────────────────────
    # Each is a hard blocker to going live. Do not remove a marker without
    # implementing the invariant and flipping its row in design.md.
    #
    #   REQ-EXEC-002 [STEP 2]: if o.client_order_id already seen, return the
    #     prior ack instead of re-submitting (idempotency across reconnects).
    #   REQ-AUDIT-002 [STEP 3]: reject if any of signal_id/regime/solve_id is
    #     nothing — lineage is a precondition of emission, not an annotation.
    #   REQ-RISK-003 [STEP 4]: reject if o would breach o.pool_id's budget.
    #   REQ-RISK-004 [STEP 4]: halt o.pool_id if its daily loss limit is breached.
    # ────────────────────────────────────────────────────────────────────

    return submit!(ctrl.venue, o)
end
