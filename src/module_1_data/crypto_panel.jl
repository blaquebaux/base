# ============================================================================
# crypto_panel.jl — Alpaca CRYPTO daily-bar provider (v1beta3). Returns the same
# `(; returns, symbols, prices, asof)` panel the sleeves consume, so a driver can point the
# identical target logic at real BTC/USD + ETH/USD instead of equity ETF proxies. Crypto trades
# every day (no market-day gaps), so the common window is dense. Read-only. Keys from env.
# ============================================================================
module CryptoPanel
using HTTP, JSON3, Dates
export CryptoPanelProvider, crypto_panel_at

struct CryptoPanelProvider
    symbols::Vector{String}
    lookback::Int
    key_id::String
    secret::String
    data_url::String
    calendar_days::Int
    timeout_sec::Float64
end
function CryptoPanelProvider(symbols::AbstractVector; lookback::Int = 252,
        key_id::AbstractString = get(ENV, "ALPACA_KEY_ID", ""),
        secret::AbstractString = get(ENV, "ALPACA_SECRET_KEY", ""),
        data_url::AbstractString = "https://data.alpaca.markets",
        calendar_days::Union{Int,Nothing} = nothing, timeout_sec::Real = 30.0)
    cd = calendar_days === nothing ? lookback + 30 : calendar_days   # daily-traded -> ~1 bar/day
    CryptoPanelProvider(String.(symbols), lookback, String(key_id), String(secret),
                        String(data_url), cd, float(timeout_sec))
end
_bd(t::AbstractString) = String(t[1:10])

"crypto_panel_at(p) -> (; returns, symbols, prices, asof). Causal; throws on auth/HTTP/insufficient history."
function crypto_panel_at(p::CryptoPanelProvider, asof::Date = Dates.today())
    (isempty(p.key_id) || isempty(p.secret)) && error("CryptoPanel: set ALPACA_KEY_ID and ALPACA_SECRET_KEY")
    headers = ["APCA-API-KEY-ID" => p.key_id, "APCA-API-SECRET-KEY" => p.secret]
    startd = asof - Day(p.calendar_days)
    bars = Dict{String,Vector{Any}}(s => [] for s in p.symbols); page = ""
    while true
        q = Dict("symbols" => join(p.symbols, ","), "timeframe" => "1Day",
                 "start" => string(startd), "end" => string(asof), "limit" => "10000")
        page != "" && (q["page_token"] = page)
        resp = HTTP.get(string(p.data_url, "/v1beta3/crypto/us/bars");
                        query = q, headers = headers, readtimeout = round(Int, p.timeout_sec), status_exception = false)
        resp.status == 200 || error("CryptoPanel: HTTP $(resp.status) — $(String(resp.body))")
        j = JSON3.read(resp.body)
        if haskey(j, :bars) && j.bars !== nothing
            for s in p.symbols
                sym = Symbol(s); haskey(j.bars, sym) && j.bars[sym] !== nothing && append!(bars[s], collect(j.bars[sym]))
            end
        end
        page = get(j, :next_page_token, nothing); (page === nothing || page == "") && break
    end
    maps = Vector{Dict{String,Float64}}(undef, length(p.symbols))
    for (i, s) in enumerate(p.symbols)
        isempty(bars[s]) && error("CryptoPanel: no bars for $s")
        maps[i] = Dict(_bd(b.t) => Float64(b.c) for b in bars[s])
    end
    common = sort!(collect(intersect((keys(m) for m in maps)...)))
    length(common) >= p.lookback + 1 || error("CryptoPanel: only $(length(common)) common bars, need $(p.lookback + 1)")
    win = common[end-p.lookback:end]; N = length(p.symbols)
    prices = Matrix{Float64}(undef, length(win), N)
    for (r, d) in enumerate(win), i in 1:N; prices[r, i] = maps[i][d]; end
    rets = prices[2:end, :] ./ prices[1:end-1, :] .- 1
    return (; returns = Matrix(rets), symbols = p.symbols, prices = Vector(prices[end, :]),
            asof = Date(win[end], dateformat"yyyy-mm-dd"))
end
end # module CryptoPanel
