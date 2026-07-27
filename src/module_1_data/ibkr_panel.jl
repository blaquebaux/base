module IBKRPanel

# =============================================================================
# ibkr_panel.jl — the LIVE panel provider (write-ahead, d-4).
#
# `IBKRPanelProvider <: PanelProvider` fetches daily bars over the IBKR Gateway via Jib
# (`reqHistoricalData`) and returns the same `(; returns, symbols, prices, asof)` panel the
# spine consumes — so swapping `CSVPanelProvider → IBKRPanelProvider` is the only change from
# the cached path to live paper.
#
# STATUS: written against the Jib v0.30 API **verified offline** (reqHistoricalData arity,
# 5-arg error callback, `historicalData(reqId, bars::VBar)` delivering all bars at once, Bar
# fields time/close, Contract fields) — the same standard the venue adapter met. NOT yet run
# against a live/paper Gateway (blocked on IBKR account approval); the connect→request→collect
# runtime needs the Gateway to exercise. Load order: include AFTER `equity_panel.jl` (it
# extends `EquityPanel.panel_at`). Requires Jib (a project dependency).
# =============================================================================

using Dates, Jib
using ..EquityPanel: PanelProvider
import ..EquityPanel: panel_at

export IBKRPanelProvider

"""
    IBKRPanelProvider(symbols; lookback=252, host="127.0.0.1",
                      port=parse(Int, get(ENV,"IBKR_PORT","7497")), client_id=2,
                      duration="2 Y", what_to_show="ADJUSTED_LAST",
                      sec_type="STK", exchange="SMART", currency="USD", timeout_sec=60.0)

Live equity-panel provider over the IBKR Gateway. `client_id` must differ from the execution
venue's (IBKR rejects duplicate client ids on one account). `what_to_show="ADJUSTED_LAST"`
gives total-return adjusted closes (matching the cached yfinance panel) — note IBKR only allows
ADJUSTED_LAST with an empty `endDateTime` (i.e. `asof = today`); for a historical `asof` it
falls back to `"TRADES"`. `duration="2 Y"` (~504 trading days) comfortably covers `lookback`.
"""
struct IBKRPanelProvider <: PanelProvider
    symbols::Vector{String}
    lookback::Int
    host::String
    port::Int
    client_id::Int
    duration::String
    what_to_show::String
    sec_type::String
    exchange::String
    currency::String
    timeout_sec::Float64
end

function IBKRPanelProvider(symbols::AbstractVector;
                           lookback::Int = 252, host::AbstractString = "127.0.0.1",
                           port::Int = parse(Int, get(ENV, "IBKR_PORT", "7497")),
                           client_id::Int = 2, duration::AbstractString = "2 Y",
                           what_to_show::AbstractString = "ADJUSTED_LAST",
                           sec_type::AbstractString = "STK", exchange::AbstractString = "SMART",
                           currency::AbstractString = "USD", timeout_sec::Real = 60.0)
    IBKRPanelProvider(String.(symbols), lookback, String(host), port, client_id,
                      String(duration), String(what_to_show), String(sec_type),
                      String(exchange), String(currency), float(timeout_sec))
end

"""
    panel_at(p::IBKRPanelProvider, asof=today()) -> (; returns, symbols, prices, asof)

Connect to the Gateway, request `p.duration` of daily bars for every symbol, align on common
dates, and return the trailing `lookback × N` return window + latest prices. Causal (bars end
at `asof`). Throws if the connection fails, a symbol returns no data, or the requests time out.
"""
function panel_at(p::IBKRPanelProvider, asof::Date = Dates.today())
    conn = try
        Jib.connect(p.host, p.port, p.client_id)
    catch e
        error("IBKRPanel: connect threw ($(p.host):$(p.port), client_id=$(p.client_id)) — is the Gateway running? $e")
    end
    conn === nothing &&
        error("IBKRPanel: connect returned nothing ($(p.host):$(p.port)) — is the Gateway running?")

    bars = Dict{Int,Vector}()                 # reqId → Vector{Bar}
    done = Channel{Int}(length(p.symbols))
    lk   = ReentrantLock()
    wrapper = Jib.Wrapper(;
        historicalData = (reqId, bs) -> lock(lk) do; bars[reqId] = collect(bs) end,
        historicalDataEnd = (reqId, s, e) -> put!(done, reqId),
        # 2104/2106/2158 are the benign "data farm connected" info messages that fire on connect.
        error = (id, errorTime, code, msg, adv) ->
            (code in (2104, 2106, 2158) || @warn "IBKRPanel error" reqId=id code=code msg=msg),
    )
    Jib.start_reader(conn, wrapper)

    # ADJUSTED_LAST is only valid with an empty endDateTime; fall back to TRADES for a past asof.
    endstr = asof >= Dates.today() ? "" : Dates.format(asof, "yyyymmdd HH:MM:SS")
    what   = (endstr == "" ? p.what_to_show : (p.what_to_show == "ADJUSTED_LAST" ? "TRADES" : p.what_to_show))
    for (i, sym) in enumerate(p.symbols)
        c = Jib.Contract(; symbol = sym, secType = p.sec_type, exchange = p.exchange, currency = p.currency)
        Jib.Requests.reqHistoricalData(conn, i, c, endstr, p.duration, "1 day", what, true, 1, false)
    end

    got = 0; t0 = time()
    while got < length(p.symbols) && time() - t0 < p.timeout_sec
        if isready(done); take!(done); got += 1 else sleep(0.05) end
    end
    try Jib.disconnect(conn) catch end
    got == length(p.symbols) ||
        error("IBKRPanel: timed out after $(p.timeout_sec)s ($got/$(length(p.symbols)) symbols returned)")

    # Per-symbol date→close maps, then align on the common trading days.
    maps = Vector{Dict{String,Float64}}(undef, length(p.symbols))
    for i in eachindex(p.symbols)
        b = get(bars, i, nothing)
        (b === nothing || isempty(b)) && error("IBKRPanel: no bars for $(p.symbols[i])")
        maps[i] = Dict(bar.time => Float64(bar.close) for bar in b)
    end
    common = sort!(collect(intersect((keys(m) for m in maps)...)))   # "YYYYMMDD" sorts chronologically
    length(common) >= p.lookback + 1 ||
        error("IBKRPanel: only $(length(common)) common bars, need $(p.lookback + 1)")
    win = common[end-p.lookback:end]                                 # lookback+1 dates → lookback returns

    N = length(p.symbols)
    prices = Matrix{Float64}(undef, length(win), N)
    for (r, d) in enumerate(win), i in 1:N
        prices[r, i] = maps[i][d]
    end
    rets = prices[2:end, :] ./ prices[1:end-1, :] .- 1
    return (; returns = Matrix(rets), symbols = p.symbols,
            prices = Vector(prices[end, :]), asof = Date(win[end], dateformat"yyyymmdd"))
end

end # module IBKRPanel
