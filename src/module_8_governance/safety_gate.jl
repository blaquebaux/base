module SafetyGate

# =============================================================================
# safety_gate.jl — Layer 3: the live-money safety gate.
#
# Pure decision logic (`preflight`, `drawdown`, `SafetyLimits`) — fully unit-tested — plus the
# I/O it needs (kill switch, high-water-mark persistence, alerting). The live driver runs
# `preflight` BEFORE placing any order; if it returns not-ok, the book is NOT traded and an
# alert fires. This sits on top of the governed ExecutionController's own gates (per-pool
# budget/loss/staleness, kill switch) — belt AND suspenders for real money.
# =============================================================================

using Dates, HTTP, JSON3

export SafetyLimits, drawdown, preflight, kill_switch_active,
       load_hwm, save_hwm, alert, default_kill_path, default_hwm_path, default_equity_path

"""
    SafetyLimits(; max_daily_loss, max_drawdown_pct, max_gross_leverage,
                 max_position_pct, min_buying_power, max_orders)

Hard limits the gate enforces before every rebalance. Defaults are conservative; tune per book.
"""
Base.@kwdef struct SafetyLimits
    max_daily_loss::Float64     = 2_000.0    # abort if equity fell more than this since last run
    max_drawdown_pct::Float64   = 0.15       # abort if equity is >15% below its high-water mark
    max_gross_leverage::Float64 = 2.0        # abort if Σ|target notional| / equity exceeds this
    # Per-name cap is a RUNAWAY-BUG catcher, NOT a concentration-risk tool: the inverse-vol base
    # legitimately puts ~68% in low-vol IEF (by design, low risk). Real concentration risk is
    # handled by the strategy + the gross-leverage and drawdown gates. Keep this loose enough to
    # allow the real book but tight enough to block an absurd (buggy) single order.
    max_position_pct::Float64    = 0.85       # abort if any one name exceeds this fraction of equity
    min_buying_power::Float64     = 1_000.0   # abort if buying power below this
    max_orders::Int              = 50         # abort if a rebalance would place more than this many
end

_cfgdir()            = joinpath(homedir(), ".config", "blaquebaux")
default_kill_path()  = joinpath(_cfgdir(), "HALT")
default_hwm_path()   = joinpath(_cfgdir(), "equity_hwm.txt")
default_equity_path()= joinpath(_cfgdir(), "equity_last.txt")

"Kill switch: trading is disabled while this file exists (create to stop, delete to resume)."
kill_switch_active(path::AbstractString = default_kill_path()) = isfile(path)

function load_hwm(path::AbstractString = default_hwm_path())
    isfile(path) || return -Inf
    v = tryparse(Float64, strip(read(path, String))); v === nothing ? -Inf : v
end
save_hwm(hwm::Real, path::AbstractString = default_hwm_path()) =
    (mkpath(dirname(path)); write(path, string(hwm)); float(hwm))

"Fractional drawdown of `equity` below `hwm` (≤ 0). 0 when no valid high-water mark yet."
drawdown(equity::Real, hwm::Real) = hwm > 0 ? (equity / hwm - 1.0) : 0.0

"""
    preflight(; account_status, trading_blocked, account_blocked, equity, hwm, last_equity,
              buying_power, data_fresh, targets, prices, limits, kill_path) -> (ok, reasons)

Aggregate every pre-trade safety check. `ok == false` ⇒ **DO NOT TRADE**; `reasons` lists every
tripped guard (all are evaluated so the alert is complete, not just the first failure).
"""
function preflight(; account_status::AbstractString, trading_blocked::Bool = false,
                   account_blocked::Bool = false, equity::Real, hwm::Real,
                   last_equity::Real = NaN, buying_power::Real, data_fresh::Bool,
                   targets::AbstractDict, prices::AbstractDict, limits::SafetyLimits = SafetyLimits(),
                   kill_path::AbstractString = default_kill_path())
    r = String[]
    kill_switch_active(kill_path)         && push!(r, "KILL SWITCH active ($kill_path)")
    account_status != "ACTIVE"            && push!(r, "account status=$account_status (not ACTIVE)")
    trading_blocked                       && push!(r, "account trading_blocked")
    account_blocked                       && push!(r, "account_blocked")
    !data_fresh                           && push!(r, "market data STALE")
    equity <= 0                           && push!(r, "equity $equity ≤ 0")
    buying_power < limits.min_buying_power && push!(r, "buying_power $buying_power < min $(limits.min_buying_power)")

    dd = drawdown(equity, hwm)
    dd < -limits.max_drawdown_pct &&
        push!(r, "drawdown $(round(100dd, digits=1))% exceeds limit -$(round(100limits.max_drawdown_pct))%")

    if isfinite(last_equity)
        day_pnl = equity - last_equity
        day_pnl < -limits.max_daily_loss &&
            push!(r, "daily loss $(round(day_pnl, digits=0)) exceeds limit -$(limits.max_daily_loss)")
    end

    length(targets) > limits.max_orders && push!(r, "$(length(targets)) orders > max $(limits.max_orders)")
    gross = 0.0
    for (s, q) in targets
        px = get(prices, s, 0.0)
        if px <= 0 || !isfinite(px)
            push!(r, "$s bad price $px"); continue
        end
        notional = abs(float(q)) * px; gross += notional
        equity > 0 && notional / equity > limits.max_position_pct &&
            push!(r, "$s position $(round(100notional/equity, digits=1))% > max $(round(100limits.max_position_pct))%")
    end
    equity > 0 && gross / equity > limits.max_gross_leverage &&
        push!(r, "gross leverage $(round(gross/equity, digits=2))x > max $(limits.max_gross_leverage)x")

    return (isempty(r), r)
end

"""
    alert(msg; title, level, log_path, webhook, notify)

Fan out an alert: always append to the alerts log; post a macOS notification (best-effort);
and POST to `BB_ALERT_WEBHOOK` (Slack/Discord-style `{"text": …}`) if that env var is set.
Never throws — alerting must not break the trade loop.
"""
function alert(msg::AbstractString; title::AbstractString = "BlaqueBaux", level::Symbol = :warn,
               log_path::AbstractString = joinpath(_cfgdir(), "alerts.log"),
               webhook::AbstractString = get(ENV, "BB_ALERT_WEBHOOK", ""), notify::Bool = true)
    line = "[$(Dates.format(now(), "yyyy-mm-dd HH:MM:SS")) $level] $title: $msg"
    try; mkpath(dirname(log_path)); open(io -> println(io, line), log_path, "a"); catch; end
    if notify
        try; run(pipeline(`osascript -e "display notification \"$(replace(msg, "\"" => "'"))\" with title \"$title\""`,
                          stdout = devnull, stderr = devnull)); catch; end
    end
    if !isempty(webhook)
        try; HTTP.post(webhook; headers = ["Content-Type" => "application/json"],
                       body = JSON3.write(Dict("text" => "$title: $msg")),
                       readtimeout = 10, status_exception = false, retry = false); catch; end
    end
    return nothing
end

end # module SafetyGate
