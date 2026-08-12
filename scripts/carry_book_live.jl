#!/usr/bin/env julia
# ============================================================================
# carry_book_live.jl — PHASE 1 governed DRY-RUN driver for the crypto funding-rate CARRY sleeve.
#
# Validated premium (scripts/research/crypto_funding_carry.py): long spot / short perp, collect funding —
# +11.9%/yr net, corr +0.01 to SPY, the one genuinely orthogonal market-neutral stream. Design:
# docs/crypto_carry_design.md. THIS is Phase 1: compute the delta-neutral target pairs against LIVE PUBLIC
# funding data, run the funding gate + EVERY tail circuit breaker, run the safety-gate preflight, and LOG —
# placing NOTHING. No venue keys, no capital, no orders. Paper/live (Phase 2/3) need the PerpVenue adapter and
# are intentionally blocked here.
#
# THE THREE RULES + TAIL GOVERNANCE (all enforced, all logged):
#   size   : each coin at BB_CARRY_ALLOC of AUM (tail-sized, small — NOT sized by the 1%-vol carry Sharpe).
#   gate   : deploy a coin only when trailing-7d funding > 0 (crypto-native regime gate).
#   TAIL   : per-venue cap (Σ on-venue exposure <= BB_CARRY_VENUE_CAP x AUM, the FTX lesson); basis breaker
#            (|perp-spot|/spot <= band); stablecoin breaker (|USDC/USDT-1| <= band, global); funding-regime
#            kill (negative funding -> stand down); kill switch (~/.config/blaquebaux/HALT). Margin-health is
#            live-only (no account in dry-run) and reported N/A.
#   Run:  julia --project=. scripts/carry_book_live.jl        (BB_CARRY_MODE defaults to dryrun)
# ============================================================================
using HTTP, JSON3, Dates, Printf, Statistics
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_8_governance/safety_gate.jl"))
using .SafetyGate

const AUM        = parse(Float64, get(ENV, "BB_CARRY_AUM", "1000000"))       # total book (for % context + the venue cap)
const ALLOC      = parse(Float64, get(ENV, "BB_CARRY_ALLOC", "0.02"))        # per-coin size, fraction of AUM (tail-sized, small)
const VENUE_CAP  = parse(Float64, get(ENV, "BB_CARRY_VENUE_CAP", "0.05"))    # hard max on-venue exposure, fraction of AUM
const BASIS_BAND = parse(Float64, get(ENV, "BB_CARRY_BASIS_BAND", "0.01"))   # halt a coin if |perp-spot|/spot exceeds this
const STABLE_BAND= parse(Float64, get(ENV, "BB_CARRY_STABLE_BAND", "0.005")) # halt ALL if |USDC/USDT-1| exceeds this
const COINS = [("BTC", "BTC-USDT", "BTC-USDT-SWAP"), ("ETH", "ETH-USDT", "ETH-USDT-SWAP")]   # (name, spot, perp)

function okx(path)
    try
        r = HTTP.get("https://www.okx.com/api/v5/" * path; headers = ["User-Agent" => "Mozilla/5.0"],
                     readtimeout = 20, status_exception = false)
        return r.status == 200 ? JSON3.read(r.body) : nothing
    catch; return nothing; end
end
_last(instId) = (t = okx("market/ticker?instId=$instId"); t === nothing ? NaN : parse(Float64, t.data[1].last))
function trailing_funding(perp)        # sum of last 21 funding periods (~7 days) + current
    h = okx("public/funding-rate-history?instId=$perp&limit=21")
    h === nothing && return (NaN, NaN)
    fr = [parse(Float64, x.fundingRate) for x in h.data]
    (sum(fr), isempty(fr) ? NaN : fr[1])          # (trailing-7d sum, most-recent 8h rate)
end

"Build the carry book against live public data; returns targets/prices + a per-coin report + tail status."
function build_carry(aum)
    usdc = _last("USDC-USDT"); depeg = isfinite(usdc) ? abs(usdc - 1.0) : Inf
    stable_ok = depeg <= STABLE_BAND
    net = Dict{String,Float64}(); price = Dict{String,Float64}(); report = String[]; on_venue = 0.0
    for (nm, spot, perp) in COINS
        f7, fnow = trailing_funding(perp); sp = _last(spot); pp = _last(perp)
        basis = (isfinite(pp) && isfinite(sp) && sp > 0) ? (pp - sp) / sp : NaN
        annual = isfinite(fnow) ? fnow * 3 * 365 * 100 : NaN
        # gate + per-coin tail checks
        reasons = String[]
        !stable_ok && push!(reasons, "USDC depeg $(round(100depeg,digits=2))%")
        !(isfinite(f7) && f7 > 0) && push!(reasons, "funding<=0 (7d $(round(100f7,digits=3))%)")
        (isfinite(basis) && abs(basis) > BASIS_BAND) && push!(reasons, "basis $(round(100basis,digits=2))% > band")
        N = ALLOC * aum
        would_venue = on_venue + N
        would_venue > VENUE_CAP * aum && push!(reasons, "venue cap ($(round(100would_venue/aum,digits=1))% > $(round(100VENUE_CAP))%)")
        deploy = isempty(reasons)
        if deploy
            net[spot] = get(net, spot, 0.0) + N / sp        # long spot
            net[perp] = get(net, perp, 0.0) - N / pp        # short perp (delta-neutral pair)
            price[spot] = sp; price[perp] = pp; on_venue += N
        end
        push!(report, @sprintf("    %-4s %-7s  funding 7d %+6.3f%% (~%+5.0f%%/yr)  basis %+5.2f%%  -> %s%s",
            nm, deploy ? "DEPLOY" : "flat", 100*(isfinite(f7) ? f7 : NaN), annual, 100*(isfinite(basis) ? basis : NaN),
            deploy ? "long $sp / short $perp" : "stand down", isempty(reasons) ? "" : " [" * join(reasons, "; ") * "]"))
    end
    (; net, price, report, on_venue, usdc, stable_ok)
end

function main(; aum = AUM)
    mode = lowercase(get(ENV, "BB_CARRY_MODE", "dryrun"))
    mode != "dryrun" && error("carry_book_live.jl is PHASE 1 (dry-run only). paper/live need the PerpVenue adapter (Phase 2) — see docs/crypto_carry_design.md")
    kill = kill_switch_active()
    @info "carry_book_live (PHASE 1 dry-run)" aum alloc=ALLOC venue_cap=VENUE_CAP kill_switch=kill
    if kill
        println("\n  KILL SWITCH ACTIVE (~/.config/blaquebaux/HALT) — would unwind both legs and stand down. No book built.")
        return :halted
    end
    bk = build_carry(aum)
    println("\n  CRYPTO FUNDING-CARRY BOOK — Phase 1 dry-run (live public funding, delta-neutral spot/perp pairs)")
    println("  sizing: $(round(100ALLOC))%/coin of AUM, venue cap $(round(100VENUE_CAP))% of AUM (tail-sized, not vol-sized)\n")
    foreach(println, bk.report)
    @printf("\n  on-venue exposure: %.1f%% of AUM (cap %.0f%%)   USDC/USDT %.4f (%s)\n",
            100*bk.on_venue/aum, 100*VENUE_CAP, bk.usdc, bk.stable_ok ? "peg OK" : "DEPEG — global halt")
    println("  TAIL governance: venue-cap [enforced]  basis-breaker [enforced]  stablecoin [enforced]  funding-gate [enforced]  margin-health [LIVE-ONLY, N/A in dry-run]  kill-switch [clear]")
    if isempty(bk.net)
        println("\n  all coins flat — no positive-funding regime clears the tail checks right now.")
        println("\n  DRY RUN — no venue, no orders, no state advanced.")
        return :dryrun_flat
    end
    # signed-share targets -> safety-gate preflight (nominal account), exactly like the other dry-run drivers
    targets = Dict(s => round(w, digits = 6) for (s, w) in bk.net)
    ok, reasons = preflight(; account_status = "ACTIVE", equity = aum, hwm = aum, last_equity = aum,
        buying_power = aum, data_fresh = true, targets = targets, prices = bk.price,
        limits = SafetyLimits(; max_gross_leverage = 2.0))
    println("\n  netted per-instrument targets (of \$$(round(Int,aum)) AUM):")
    for (s, w) in sort(collect(bk.net), by = x -> -abs(x[2]))
        @printf("    %-16s %+10.4f units @ \$%.2f   (%+.1f%% notional)\n", s, w, get(bk.price, s, NaN), 100*w*get(bk.price,s,0.0)/aum)
    end
    @info "SAFETY GATE (dry-run, nominal account)" ok reasons
    println("\n  DRY RUN — no venue, no orders, no state advanced. Gate: $(ok ? "PASS" : "ABORT: " * join(reasons, "; "))")
    return ok ? :dryrun_ok : :dryrun_gate_abort
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
