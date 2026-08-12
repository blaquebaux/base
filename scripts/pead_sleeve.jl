# pead_sleeve.jl — shared PEAD (post-earnings-drift) tactical sleeve math (single source for the validation
# and the live driver). Event-driven & market-neutral: among names still inside their post-earnings DRIFT
# window (report + DRIFT_CAL days), rank by the actual earnings surprise, go LONG the top third / SHORT the
# bottom third (dollar-neutral), then SPY-beta-hedge the residual. Reads the calendar from pead_calendar.py.
using Dates, JSON3, Statistics, LinearAlgebra

const PEAD_UNIVERSE = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG",
    "XOM","JNJ","COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL",
    "DIS","GS","MS","CAT","HON","LLY","ABBV","TMO","NKE"]
const PEAD_DRIFT_CAL = 88     # ~60 trading days of post-earnings drift window (calendar days)
const PEAD_MINLEG    = 3      # need >= 3 names per leg to deploy

"Parse the pead_calendar.py JSON into sym => sorted [(entry_date, surprise)]. entry_date = report + 1 day if AMC
 (enter only after the reaction is priced)."
function load_pead_calendar(path)
    cal = Dict{String,Vector{Tuple{Date,Float64}}}()
    isfile(path) || return cal
    j = JSON3.read(read(path, String))
    for (sym, evs) in pairs(j.calendar)
        rows = Tuple{Date,Float64}[]
        for e in evs
            try
                push!(rows, (Date(String(e.d)) + Day(e.amc ? 1 : 0), Float64(e.surprise)))
            catch; end
        end
        !isempty(rows) && (cal[String(sym)] = sort(rows, by = x -> x[1]))
    end
    cal
end

"Market-neutral PEAD weights at `asof` from panel returns `R` (cols=`syms`) + the calendar. Returns (net, on)."
function pead_weights(R, syms, cal, asof::Date; drift_cal = PEAD_DRIFT_CAL, minleg = PEAD_MINLEG, lb = 60)
    sidx = Dict(s => i for (i, s) in enumerate(syms))
    active = Tuple{String,Float64}[]
    for s in PEAD_UNIVERSE
        (haskey(sidx, s) && haskey(cal, s)) || continue
        recent = nothing
        for (d, sup) in cal[s]
            (d <= asof && asof - d <= Day(drift_cal)) && (recent = sup)   # latest event still in the drift window
        end
        recent !== nothing && push!(active, (s, recent))
    end
    length(active) < 2minleg && return (Dict{String,Float64}(), false)
    sort!(active, by = x -> x[2])                                          # ascending surprise
    k = max(minleg, length(active) ÷ 3)
    shorts = first.(active[1:k]); longs = first.(active[end-k+1:end])      # short worst / long best surprise
    net = Dict{String,Float64}()
    for s in longs;  net[s] = get(net, s, 0.0) + 1 / (2k); end             # dollar-neutral, gross ~1
    for s in shorts; net[s] = get(net, s, 0.0) - 1 / (2k); end
    # SPY hedge: trailing-lb beta of the CURRENT book (large-cap dollar-neutral -> already ~0; hedge the residue)
    Tr = size(R, 1); spy = R[:, sidx["SPY"]]; bookret = zeros(Tr)
    for (s, wt) in net; haskey(sidx, s) && (bookret .+= wt .* R[:, sidx[s]]); end
    win = max(1, Tr-lb+1):Tr
    bt = var(spy[win]) > 0 ? clamp(cov(bookret[win], spy[win]) / var(spy[win]), -3.0, 3.0) : 0.0
    net["SPY"] = get(net, "SPY", 0.0) - bt
    (net, true)
end
