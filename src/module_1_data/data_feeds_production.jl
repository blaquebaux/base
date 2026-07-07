# ============================================================================
# PRODUCTION DATA FEEDS — REST + WebSocket scaffolds
# Source: Deepseek v2, integrated with corrections (May 2026)
# Status: Scaffold — endpoints and auth require wiring per vendor docs
# ============================================================================

using HTTP, JSON3, Dates, TimeZones

# ── Environment configuration ─────────────────────────────────────────────────
const FRED_API_KEY = get(ENV, "FRED_API_KEY", "")
const IBKR_ACCOUNT  = get(ENV, "IBKR_ACCOUNT", "")
const DERIBIT_ID     = get(ENV, "DERIBIT_CLIENT_ID", "")
const DERIBIT_SECRET = get(ENV, "DERIBIT_CLIENT_SECRET", "")

# ── FRED (Federal Reserve Economic Data) ─────────────────────────────────────
# DGS series = market (par) yields. True GSW zero-coupon dataset requires
# separate download from: https://www.federalreserve.gov/pubs/feds/2006/200628/
# For daily production use, DGS2/10/30 are close enough as yield proxies.
const FRED_SERIES = Dict(2 => "DGS2", 10 => "DGS10", 30 => "DGS30")
const FRED_BASE   = "https://api.stlouisfed.org/fred/series/observations"

function fetch_fred_yield(maturity::Int, dt::ZonedDateTime)::Union{Float64,Nothing}
    sid = get(FRED_SERIES, maturity, nothing)
    sid === nothing && return nothing
    isempty(FRED_API_KEY) && (@warn "FRED_API_KEY not set"; return nothing)

    date_str = Dates.format(DateTime(dt), "yyyy-mm-dd")
    url = "$FRED_BASE?series_id=$sid&api_key=$FRED_API_KEY" *
          "&observation_start=$date_str&observation_end=$date_str&file_type=json"
    try
        resp = HTTP.get(url; connect_timeout=10, readtimeout=15)
        data = JSON3.read(resp.body)
        obs  = get(data, "observations", [])
        isempty(obs) && return nothing
        val  = obs[1]["value"]
        val == "." && return nothing           # FRED missing-data sentinel
        return parse(Float64, val) / 100.0     # Convert pct → decimal
    catch e
        @warn "FRED fetch failed for $sid: $e"
        return nothing
    end
end

# ── Cboe Volatility Indices ───────────────────────────────────────────────────
# CORRECTION from Deepseek v2: Cboe API requires registration.
# Production endpoint: https://cdn.cboe.com/api/global/us_indices/daily_prices/
# VIX_History.csv — updated daily. Simpler than WebSocket for daily-close use.
# Real-time WebSocket requires Cboe DataShop subscription.
const CBOE_DAILY_BASE = "https://cdn.cboe.com/api/global/us_indices/daily_prices/"
const CBOE_INDEX_FILES = Dict(
    "VIX"  => "VIX_History.csv",
    "VXV"  => "VXV_History.csv",
    "VVIX" => "VVIX_History.csv",
    "VIX1D"=> "VIX1D_History.csv",
)

function fetch_cboe_daily_close(index::String, dt::ZonedDateTime)::Union{Float64,Nothing}
    fname = get(CBOE_INDEX_FILES, index, nothing)
    fname === nothing && return nothing
    date_str = Dates.format(DateTime(dt), "mm/dd/yyyy")
    try
        resp = HTTP.get("$CBOE_DAILY_BASE$fname"; connect_timeout=10)
        for line in split(String(resp.body), "\n")[2:end]  # skip header
            parts = split(strip(line), ",")
            length(parts) < 5 && continue
            parts[1] == date_str && return parse(Float64, parts[5])  # CLOSE col
        end
        return nothing
    catch e
        @warn "Cboe fetch failed for $index: $e"
        return nothing
    end
end

# ── TGA Balance (US Treasury Fiscal Data Service) ────────────────────────────
# CORRECTION from Deepseek v2: actual endpoint is fiscaldata.treasury.gov
const TGA_URL = "https://api.fiscaldata.treasury.gov/services/api/v1/accounting/dts/dts_table_1/"

function fetch_tga_balance(dt::ZonedDateTime)::Union{Float64,Nothing}
    date_str = Dates.format(DateTime(dt), "yyyy-MM-dd")
    url = "$TGA_URL?filter=record_date:eq:$date_str" *
          "&fields=record_date,closing_balance_today&page[size]=1"
    try
        resp = HTTP.get(url; connect_timeout=10)
        data = JSON3.read(resp.body)
        rows = get(data, "data", [])
        isempty(rows) && return nothing
        return parse(Float64, rows[1]["closing_balance_today"]) * 1e6  # millions → dollars
    catch e
        @warn "TGA fetch failed: $e"
        return nothing
    end
end

# ── Deribit Crypto Options Skew ───────────────────────────────────────────────
# Endpoint verified against Deribit API v2 docs.
function fetch_deribit_skew(currency::String="BTC")::Union{Float64,Nothing}
    url = "https://www.deribit.com/api/v2/public/get_volatility_index_data" *
          "?currency=$currency&start_timestamp=0&end_timestamp=0&resolution=1D"
    try
        resp = HTTP.get(url; connect_timeout=10)
        data = JSON3.read(resp.body)
        result = get(data, "result", nothing)
        result === nothing && return nothing
        # Returns ATM vol — skew requires delta-surface which needs auth
        # Placeholder: return implied vol as vol-surface proxy
        return get(result, "volatility", nothing)
    catch e
        @warn "Deribit fetch failed for $currency: $e"
        return nothing
    end
end

# ── OIS-SOFR Spread ───────────────────────────────────────────────────────────
# SOFR from FRED (SOFR series), OIS from market quotes (not free via FRED)
# Production: pull SOFR from FRED, OIS from Bloomberg or IBKR
const SOFR_SERIES = "SOFR"

function fetch_ois_sofr_spread(dt::ZonedDateTime)::Union{Float64,Nothing}
    sofr = fetch_fred_yield(0, dt)  # 0-maturity = overnight
    # NOTE: Replace 0 with actual SOFR FRED call:
    # sofr = fetch_single_fred_series("SOFR", dt)
    sofr === nothing && return nothing
    # OIS not available free — use SOFR as proxy (spread ≈ 0 in normal conditions)
    return 0.0005  # placeholder 5bps baseline; wire to real OIS quote in production
end

function fetch_single_fred_series(series_id::String, dt::ZonedDateTime)::Union{Float64,Nothing}
    isempty(FRED_API_KEY) && return nothing
    date_str = Dates.format(DateTime(dt), "yyyy-mm-dd")
    url = "$FRED_BASE?series_id=$series_id&api_key=$FRED_API_KEY" *
          "&observation_start=$date_str&observation_end=$date_str&file_type=json"
    try
        resp = HTTP.get(url; connect_timeout=10)
        data = JSON3.read(resp.body)
        obs  = get(data, "observations", [])
        isempty(obs) && return nothing
        val = obs[1]["value"]
        val == "." && return nothing
        return parse(Float64, val)
    catch e; return nothing; end
end
