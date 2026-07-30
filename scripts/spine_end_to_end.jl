#!/usr/bin/env julia
# ============================================================================
# spine_end_to_end.jl — d-4: the WHOLE Path-B pipeline on cached data, no broker.
#
#   CSV panel  →  stateful spine (regime :dd)  →  signed share targets  →  the governed
#   ExecutionController (all order-path invariants)  →  simulated fills  →  the real SQLite
#   ledger with decision lineage  →  reconciliation.
#
# Proves the pipeline runs end-to-end. The ONLY thing standing between this and live paper
# trading is the data source: swap `CSVPanelProvider` for an `IBKRPanelProvider` and the
# `SimVenue` for `IBKRVenue`. Everything between is exercised here exactly as it will run live.
# ============================================================================

using Dates, Serialization, Printf

const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl"))
include(joinpath(REPO, "src/module_10_feedback/module_10_feedback.jl"))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl"))
include(joinpath(REPO, "src/module_1_data/equity_panel.jl"))
using .ExecutionLayer, .FeedbackLayer, .PortfolioOptModule, .EquityPanel
include(joinpath(REPO, "scripts/live_execution.jl"))

# ── A simulating venue: acks every order and fills it at the ref price, tracking positions.
#    Same ExecutionVenue interface IBKRVenue implements — this is the only swapped part.
mutable struct SimVenue <: ExecutionVenue
    n::Int
    fills::Vector{NamedTuple}
    posns::Dict{String,Float64}
    lk::ReentrantLock
end
SimVenue() = SimVenue(0, NamedTuple[], Dict{String,Float64}(), ReentrantLock())
ExecutionLayer.connect!(::SimVenue) = true
ExecutionLayer.disconnect!(::SimVenue) = nothing
ExecutionLayer.is_connected(::SimVenue) = true
ExecutionLayer.positions(v::SimVenue, ::String) = lock(() -> copy(v.posns), v.lk)
ExecutionLayer.drain_fills(v::SimVenue) = lock(v.lk) do
    fs = copy(v.fills); empty!(v.fills); fs
end
function ExecutionLayer.submit!(v::SimVenue, o::VenueOrder)
    lock(v.lk) do
        v.n += 1; oid = "SIM$(v.n)"
        signed = o.side === :buy ? o.quantity : -o.quantity
        px = o.ref_price === nothing ? 0.0 : float(o.ref_price)
        push!(v.fills, (symbol = o.symbol, order_id = oid, exec_id = "EX$(v.n)",
                        fill_price = px, shares = o.quantity,
                        side = o.side === :buy ? "BOT" : "SLD", timestamp = now(UTC)))
        v.posns[o.symbol] = get(v.posns, o.symbol, 0.0) + signed
        OrderAck(:accepted, oid, o.client_order_id, nothing)
    end
end

function main(; csv = joinpath(REPO, "scripts/data/sector_panel.csv"),
              capital = 1_000_000.0, n_rebalances = 12, step = 21, regime = :dd,
              verbose::Bool = true)
    tmp = mktempdir()
    venue = SimVenue()
    built = build_live_controller(; venue = venue,
        ledger_config = LedgerConfig(; db_path = joinpath(tmp, "ledger.sqlite")),
        audit_path = joinpath(tmp, "audit.jsonl"))
    ctrl, ledger = built.ctrl, built.ledger
    pool = "us"
    set_pool_budget!(ctrl, pool, 2 * capital)
    set_pool_loss_limit!(ctrl, pool, capital)
    set_pool_staleness!(ctrl, pool, Day(5))

    provider = CSVPanelProvider(csv; lookback = 252)
    ad = available_dates(provider)
    sel = ad[max(1, length(ad) - step * (n_rebalances - 1)):step:end]
    state = SpineState(length(provider.symbols); regime = regime)

    verbose && @info "Pipeline start" symbols=provider.symbols rebalances=length(sel) span="$(first(sel)) → $(last(sel))"
    verbose && println("\n date        regime    orders  fills  reconciled  gross\$")
    verbose && println("-"^68)
    recs = NamedTuple[]
    for asof in sel
        reset_daily!(ctrl)                                        # each rebalance = a new trading day
        feed_staleness!(ctrl, pool; stale = false)               # cached data is fresh by construction
        panel   = panel_at(provider, asof)
        w       = spine_step!(state, panel.returns)
        reg     = regime_multiplier(panel.returns, :dd) < 1.0 ? "risk-off" : "normal"
        targets = spine_targets(w, panel.symbols, panel.prices, capital)
        prices  = Dict(panel.symbols[i] => panel.prices[i] for i in eachindex(panel.symbols))
        res = execute_rebalance!(ctrl, ledger; targets = targets, prices = prices,
            signal_id = "spine", regime = reg, solve_id = Dates.format(asof, "yyyymmdd"),
            pool_id = pool, settle_secs = 0)
        gross = sum(abs(v) * prices[k] for (k, v) in targets)
        accepted = count(a -> a.status == :accepted, res.acks)
        push!(recs, (asof = asof, regime = reg, orders = length(res.acks), accepted = accepted,
                     fills = length(res.fills), reconciled = res.reconciled, gross = gross))
        verbose && @printf("%s   %-8s  %5d  %5d   %-9s  %s\n", asof, reg,
                length(res.acks), length(res.fills), string(res.reconciled), string(round(Int, gross)))
    end

    # Prove the ledger captured fills WITH decision lineage (AUDIT-001).
    total = 0
    sample = nothing
    for s in provider.symbols
        fs = query_fills(ledger, s); total += length(fs)
        sample === nothing && !isempty(fs) && (sample = fs[end])
    end
    if verbose
        println("-"^68)
        @info "Pipeline complete" ledger_fills=total
        sample !== nothing && @info "sample fill lineage (AUDIT-001)" symbol=sample.symbol qty=sample.signed_qty price=sample.fill_price signal_id=sample.signal_id regime=sample.regime solve_id=sample.solve_id order_id=sample.order_id
    end
    close_ledger(ledger)
    return (; rebalances = recs, ledger_fills = total, sample = sample)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
