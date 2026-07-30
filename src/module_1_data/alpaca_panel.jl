module AlpacaPanel

# =============================================================================
# alpaca_panel.jl — LIVE panel provider over the Alpaca Market Data API (Plan B).
#
# `AlpacaPanelProvider <: PanelProvider` fetches daily bars via Alpaca's REST v2
# (`GET /v2/stocks/bars`, adjustment=all for total-return closes) and returns the same
# `(; returns, symbols, prices, asof)` panel the spine consumes. Swapping
# `CSVPanelProvider → AlpacaPanelProvider` is the only change from cached to live data.
#
# Unlike the IBKR path, Alpaca **paper keys need no account approval**, so this can be RUN,
# not just written ahead. Requires ALPACA_KEY_ID / ALPACA_SECRET_KEY (paper keys are fine —
# data is the same). HTTP + JSON3 are already project deps. Load AFTER equity_panel.jl.
# =============================================================================

using Dates, HTTP, JSON3
using ..EquityPanel: PanelProvider
import ..EquityPanel: panel_at

export AlpacaPanelProvider

"""
    AlpacaPanelProvider(symbols; lookback=252,
                        key_id=ENV["ALPACA_KEY_ID"], secret=ENV["ALPACA_SECRET_KEY"],
                        data_url="https://data.alpaca.markets", feed="iex",
                        adjustment="all", calendar_days=nothing, timeout_sec=30.0)

Live daily-bar provider over Alpaca. `feed="iex"` is the free tier (fine for EOD daily bars);
`"sip"` is the paid full-market feed. `adjustment="all"` gives split+dividend-adjusted
(total-return) closes, matching the cached yfinance panel. `calendar_days` is how far back to
request (defaults to ~1.7× `lookback` + buffer, enough calendar days to cover `lookback`
trading days). Keys are read at construction but only *used* in `panel_at`.
"""
struct AlpacaPanelProvider <: PanelProvider
    symbols::Vector{String}
    lookback::Int
    key_id::String
    secret::String
    data_url::String
    feed::String
    adjustment::String
    calendar_days::Int
    timeout_sec::Float64
end

function AlpacaPanelProvider(symbols::AbstractVector;
                            lookback::Int = 252,
                            key_id::AbstractString = get(ENV, "ALPACA_KEY_ID", ""),
                            secret::AbstractString = get(ENV, "ALPACA_SECRET_KEY", ""),
                            data_url::AbstractString = "https://data.alpaca.markets",
                            feed::AbstractString = "iex", adjustment::AbstractString = "all",
                            calendar_days::Union{Int,Nothing} = nothing, timeout_sec::Real = 30.0)
    cd = calendar_days === nothing ? ceil(Int, lookback * 1.7) + 45 : calendar_days
    AlpacaPanelProvider(String.(symbols), lookback, String(key_id), String(secret),
                        String(data_url), String(feed), String(adjustment), cd, float(timeout_sec))
end

_bardate(t::AbstractString) = String(t[1:10])   # "2024-01-03T05:00:00Z" → "2024-01-03" (sorts chronologically)

"""
    panel_at(p::AlpacaPanelProvider, asof=today()) -> (; returns, symbols, prices, asof)

Pull `p.calendar_days` of daily bars for every symbol (paginated), align on common trading
days, and return the trailing `lookback × N` return window + latest prices. Causal (bars end
at `asof`). Throws on auth/HTTP errors, a symbol with no bars, or insufficient history.
"""
function panel_at(p::AlpacaPanelProvider, asof::Date = Dates.today())
    (isempty(p.key_id) || isempty(p.secret)) &&
        error("AlpacaPanel: set ALPACA_KEY_ID and ALPACA_SECRET_KEY (paper keys are fine)")
    headers = ["APCA-API-KEY-ID" => p.key_id, "APCA-API-SECRET-KEY" => p.secret]
    startd  = asof - Day(p.calendar_days)

    bars = Dict{String,Vector{Any}}(s => [] for s in p.symbols)
    page = ""
    while true
        q = Dict("symbols" => join(p.symbols, ","), "timeframe" => "1Day",
                 "start" => string(startd), "end" => string(asof),
                 "adjustment" => p.adjustment, "feed" => p.feed, "limit" => "10000")
        page != "" && (q["page_token"] = page)
        resp = HTTP.get(string(p.data_url, "/v2/stocks/bars");
                        query = q, headers = headers, readtimeout = round(Int, p.timeout_sec),
                        status_exception = false)
        resp.status == 200 ||
            error("AlpacaPanel: HTTP $(resp.status) — $(String(resp.body))")
        j = JSON3.read(resp.body)
        if haskey(j, :bars) && j.bars !== nothing
            for s in p.symbols
                sym = Symbol(s)
                haskey(j.bars, sym) && j.bars[sym] !== nothing && append!(bars[s], collect(j.bars[sym]))
            end
        end
        page = get(j, :next_page_token, nothing)
        (page === nothing || page == "") && break
    end

    maps = Vector{Dict{String,Float64}}(undef, length(p.symbols))
    for (i, s) in enumerate(p.symbols)
        isempty(bars[s]) && error("AlpacaPanel: no bars for $s (check symbol, feed=$(p.feed), or entitlements)")
        maps[i] = Dict(_bardate(b.t) => Float64(b.c) for b in bars[s])
    end
    common = sort!(collect(intersect((keys(m) for m in maps)...)))
    length(common) >= p.lookback + 1 ||
        error("AlpacaPanel: only $(length(common)) common bars, need $(p.lookback + 1) — widen calendar_days")
    win = common[end-p.lookback:end]

    N = length(p.symbols)
    prices = Matrix{Float64}(undef, length(win), N)
    for (r, d) in enumerate(win), i in 1:N
        prices[r, i] = maps[i][d]
    end
    rets = prices[2:end, :] ./ prices[1:end-1, :] .- 1
    return (; returns = Matrix(rets), symbols = p.symbols,
            prices = Vector(prices[end, :]), asof = Date(win[end], dateformat"yyyy-mm-dd"))
end

end # module AlpacaPanel
