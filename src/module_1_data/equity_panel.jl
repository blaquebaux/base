module EquityPanel

# =============================================================================
# equity_panel.jl — the spine's multi-asset data adapter.
#
# Produces the `(; returns, symbols, prices, asof)` panel the spine consumes
# (`compute_targets` in run_daily_recursive.jl). `panel_at(provider, asof)` returns the
# trailing return window ending at `asof` (last row = the just-closed bar) plus the latest
# per-symbol prices. Providers are swappable behind one interface: `CSVPanelProvider` reads
# cached history now; an `IBKRPanelProvider <: PanelProvider` (reqHistoricalData over the
# Gateway) drops in later — the only change is which provider you construct.
# =============================================================================

using DelimitedFiles, Dates

export PanelProvider, CSVPanelProvider, panel_at, available_dates

"""
    PanelProvider

Abstract source of equity panels. Implement `panel_at(p, asof::Date) -> NamedTuple` and
`available_dates(p) -> Vector{Date}`.
"""
abstract type PanelProvider end

"""
    CSVPanelProvider(path; lookback=252)

Panel provider backed by a cached CSV (`date,<SYM1>,<SYM2>,…` of adjusted closes, one row
per bar). `lookback` is the number of return rows the spine needs (≥ its `mom_lookback`).
"""
struct CSVPanelProvider <: PanelProvider
    dates::Vector{Date}
    prices::Matrix{Float64}      # T×N adjusted closes
    symbols::Vector{String}
    lookback::Int
end

function CSVPanelProvider(path::AbstractString; lookback::Int = 252)
    raw, hdr = readdlm(path, ',', header = true)
    dates   = Date.(string.(raw[:, 1]))
    prices  = Float64.(raw[:, 2:end])
    symbols = String.(vec(hdr)[2:end])
    issorted(dates) || error("EquityPanel: CSV dates must be ascending")
    CSVPanelProvider(dates, prices, symbols, lookback)
end

"""
    available_dates(p) -> Vector{Date}

Dates for which a full-lookback panel can be produced (i.e. warmup satisfied).
"""
available_dates(p::CSVPanelProvider) = p.dates[p.lookback+1:end]

"""
    panel_at(p, asof) -> (; returns, symbols, prices, asof)

Panel as of the last bar on/before `asof`: `returns` is the trailing `lookback × N` matrix
(last row = the bar at `asof`), `prices` the closes at `asof`. Causal — no future data.
"""
function panel_at(p::CSVPanelProvider, asof::Date)
    i = searchsortedlast(p.dates, asof)
    i >= p.lookback + 1 ||
        error("EquityPanel: need $(p.lookback + 1) bars on/before $asof, have $i")
    wp = @view p.prices[i-p.lookback:i, :]                 # lookback+1 prices → lookback returns
    rets = wp[2:end, :] ./ wp[1:end-1, :] .- 1
    return (; returns = Matrix(rets), symbols = p.symbols,
            prices = Vector(p.prices[i, :]), asof = p.dates[i])
end

end # module EquityPanel
