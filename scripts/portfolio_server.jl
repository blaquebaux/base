#!/usr/bin/env julia
# =============================================================================
# portfolio_server.jl — HTTP REST server for the BlaqueBaux portfolio dashboard
#
# Exposes the full PortfolioOpt + BlaqueBaux analytics stack to the Python
# Dash frontend over a local HTTP connection.
#
# Start:
#   julia --project=. scripts/portfolio_server.jl
#   julia --project=. scripts/portfolio_server.jl --port 8766
#
# Endpoints:
#   GET  /health                   liveness check
#   POST /optimize                 run one optimization strategy
#   POST /frontier                 efficient frontier (n_points)
#   POST /resampled_frontier       Michaud resampled frontier
#   POST /backtest                 walk-forward backtest
#   POST /metrics                  performance metrics for a return series
#   POST /random_portfolios        feasibility-set Monte Carlo
# =============================================================================

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using HTTP, JSON3, Dates, LinearAlgebra, Statistics

# Load PortfolioOpt via the module wrapper
include(joinpath(@__DIR__, "../src/module_13_portfolio/module_13_portfolio.jl"))
using .PortfolioOptModule

const DEFAULT_PORT = 8766

# ── helpers ──────────────────────────────────────────────────────────────────

function parse_returns(body::Dict)
    raw = body["returns"]  # Vector of vectors (T x N) row-major from JSON
    T = length(raw)
    N = length(raw[1])
    R = Matrix{Float64}(undef, T, N)
    for (i, row) in enumerate(raw)
        R[i, :] = Float64.(row)
    end
    return R
end

function json_resp(data; status=200)
    HTTP.Response(status,
        ["Content-Type" => "application/json"],
        body = JSON3.write(data))
end

function error_resp(msg::String; status=400)
    json_resp(Dict("error" => msg); status=status)
end

# ── route handlers ────────────────────────────────────────────────────────────

function handle_health(req::HTTP.Request)
    json_resp(Dict("status" => "ok", "time" => string(now())))
end

function handle_optimize(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    R = parse_returns(body)
    strategy = get(body, "strategy", "min_variance")
    long_only = get(body, "long_only", true)
    w_max = get(body, "w_max", nothing)
    w_min = get(body, "w_min", nothing)
    tickers = get(body, "tickers", ["A$i" for i in 1:size(R, 2)])

    μ, (Σ, _) = mean_returns(R), shrinkage_cov(R)

    w = try
        if strategy == "min_variance"
            min_variance(Σ; long_only, w_max, w_min)
        elseif strategy == "max_sharpe"
            max_sharpe(μ, Σ; long_only, w_max, w_min)
        elseif strategy == "risk_parity"
            risk_parity(Σ)
        elseif strategy == "hrp"
            hrp_weights(Σ)
        elseif strategy == "inverse_variance"
            inverse_variance(Σ)
        elseif strategy == "max_diversification"
            max_diversification(μ, Σ; long_only, w_max, w_min)
        elseif strategy == "min_cvar"
            α = Float64(get(body, "cvar_alpha", 0.95))
            tgt = get(body, "target_return", nothing)
            min_cvar(R; α, μ, target_return = isnothing(tgt) ? nothing : Float64(tgt))
        elseif strategy == "min_cdar"
            α = Float64(get(body, "cvar_alpha", 0.95))
            min_cdar(R; α)
        elseif strategy == "black_litterman"
            views = get(body, "views", [])
            mkt_caps = get(body, "mkt_caps", fill(1.0 / size(R, 2), size(R, 2)))
            π_eq = implied_equilibrium_returns(Float64.(mkt_caps), Σ)
            if isempty(views)
                w_eq = Float64.(mkt_caps)
                w_eq ./= sum(w_eq)
                w_eq
            else
                vws = [make_view(Float64.(v["pick"]), Float64(v["expected"]), Float64(v["confidence"])) for v in views]
                bl = black_litterman(π_eq, Σ, vws)
                max_sharpe(bl.μ_posterior, bl.Σ_posterior; long_only, w_max, w_min)
            end
        else
            return error_resp("unknown strategy: $strategy")
        end
    catch e
        return error_resp("optimization failed: $(sprint(showerror, e))")
    end

    port_ret = R * w
    stats = summary_stats(port_ret)
    rc = risk_contributions(w, Σ)

    json_resp(Dict(
        "weights"   => Dict(zip(tickers, w)),
        "weights_vec" => collect(w),
        "tickers"   => collect(tickers),
        "metrics"   => Dict(
            "ann_return" => stats.ann_return,
            "ann_vol"    => stats.ann_vol,
            "sharpe"     => stats.sharpe,
            "sortino"    => stats.sortino,
            "max_dd"     => stats.max_dd,
            "calmar"     => stats.calmar,
            "var_95"     => stats.var,
            "cvar_95"    => stats.cvar,
        ),
        "risk_contributions" => Dict(zip(tickers, rc)),
        "portfolio_returns"  => collect(port_ret),
    ))
end

function handle_frontier(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    R = parse_returns(body)
    n = Int(get(body, "n_points", 25))
    long_only = get(body, "long_only", true)
    w_max = get(body, "w_max", nothing)
    tickers = get(body, "tickers", ["A$i" for i in 1:size(R, 2)])

    μ, (Σ, _) = mean_returns(R), shrinkage_cov(R)

    ef = try
        efficient_frontier(μ, Σ; n, long_only, w_max)
    catch e
        return error_resp("frontier failed: $(sprint(showerror, e))")
    end

    json_resp(Dict(
        "risks"   => ef.risks .* sqrt(252),
        "returns" => ef.returns .* 252,
        "weights" => [Dict(zip(tickers, ef.weights[:, k])) for k in 1:n],
    ))
end

function handle_resampled_frontier(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    R = parse_returns(body)
    n_resample = Int(get(body, "n_resample", 100))
    n_points   = Int(get(body, "n_points", 25))
    sampler_name = get(body, "sampler", "stationary_bootstrap")
    ν  = Float64(get(body, "nu", 5.0))
    tickers = get(body, "tickers", ["A$i" for i in 1:size(R, 2)])

    sampler = if sampler_name == "gaussian"
        gaussian_dgp()
    elseif sampler_name == "iid_bootstrap"
        iid_bootstrap()
    elseif sampler_name == "block_bootstrap"
        block_bootstrap()
    elseif sampler_name == "t_copula"
        t_copula_dgp(; ν)
    elseif sampler_name == "student_t"
        student_t_dgp(; ν)
    else
        stationary_bootstrap()
    end

    rf = try
        resampled_frontier(R; n_resample, n_points, sampler)
    catch e
        return error_resp("resampled frontier failed: $(sprint(showerror, e))")
    end

    json_resp(Dict(
        "risks"   => rf.risks .* sqrt(252),
        "returns" => rf.returns .* 252,
        "cvars"   => rf.cvars,
        "weights" => [Dict(zip(tickers, rf.weights[:, k])) for k in 1:n_points],
    ))
end

function handle_backtest(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    R = parse_returns(body)
    strategy_name = get(body, "strategy", "risk_parity")
    lookback  = Int(get(body, "lookback", 252))
    rebalance = Int(get(body, "rebalance", 21))
    cost_bps  = Float64(get(body, "cost_bps", 5.0))
    tickers   = get(body, "tickers", ["A$i" for i in 1:size(R, 2)])

    strategy_fn = if strategy_name == "min_variance"
        w -> min_variance(shrinkage_cov(w)[1])
    elseif strategy_name == "max_sharpe"
        w -> max_sharpe(mean_returns(w), shrinkage_cov(w)[1])
    elseif strategy_name == "hrp"
        w -> hrp_weights(shrinkage_cov(w)[1])
    elseif strategy_name == "inverse_variance"
        w -> inverse_variance(shrinkage_cov(w)[1])
    elseif strategy_name == "equal_weight"
        w -> equal_weight(w)
    else  # default: risk_parity
        w -> risk_parity(shrinkage_cov(w)[1])
    end

    bt = try
        backtest(R, strategy_fn; lookback, rebalance, cost_bps)
    catch e
        return error_resp("backtest failed: $(sprint(showerror, e))")
    end

    eq_bt = try
        backtest(R, equal_weight; lookback, rebalance, cost_bps=0.0)
    catch
        nothing
    end

    cumret = cumprod(1 .+ bt.returns) .- 1
    stats  = summary_stats(bt.returns)

    json_resp(Dict(
        "dates"           => bt.dates,
        "returns"         => collect(bt.returns),
        "cumulative"      => collect(cumret),
        "turnover"        => collect(bt.turnover),
        "benchmark_cum"   => isnothing(eq_bt) ? nothing : collect(cumprod(1 .+ eq_bt.returns) .- 1),
        "metrics"         => Dict(
            "ann_return" => stats.ann_return,
            "ann_vol"    => stats.ann_vol,
            "sharpe"     => stats.sharpe,
            "sortino"    => stats.sortino,
            "max_dd"     => stats.max_dd,
            "calmar"     => stats.calmar,
        ),
        "weight_history"  => [Dict(zip(tickers, bt.weights[:, k])) for k in 1:size(bt.weights, 2)],
    ))
end

function handle_metrics(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    r = Float64.(body["returns"])
    ppy = Int(get(body, "ppy", 252))
    α   = Float64(get(body, "alpha", 0.95))
    stats = summary_stats(r; ppy, α)
    dd    = drawdown_series(r)
    json_resp(Dict(
        "ann_return" => stats.ann_return,
        "ann_vol"    => stats.ann_vol,
        "sharpe"     => stats.sharpe,
        "sortino"    => stats.sortino,
        "max_dd"     => stats.max_dd,
        "calmar"     => stats.calmar,
        "var_95"     => stats.var,
        "cvar_95"    => stats.cvar,
        "drawdown_series" => collect(dd),
    ))
end

function handle_random_portfolios(req::HTTP.Request)
    body = JSON3.read(String(req.body), Dict)
    R = parse_returns(body)
    n = Int(get(body, "n", 3000))
    μ, (Σ, _) = mean_returns(R), shrinkage_cov(R)
    rp = random_portfolios(μ, Σ; n, ppy=252)
    json_resp(Dict(
        "risks"   => rp.risks,
        "returns" => rp.returns,
        "best_sharpe_weights" => collect(rp.best_sharpe_weights),
    ))
end

# ── router ────────────────────────────────────────────────────────────────────

function router(req::HTTP.Request)
    @info "$(req.method) $(req.target)"
    return try
        if req.target == "/health" && req.method == "GET"
            handle_health(req)
        elseif req.target == "/optimize" && req.method == "POST"
            handle_optimize(req)
        elseif req.target == "/frontier" && req.method == "POST"
            handle_frontier(req)
        elseif req.target == "/resampled_frontier" && req.method == "POST"
            handle_resampled_frontier(req)
        elseif req.target == "/backtest" && req.method == "POST"
            handle_backtest(req)
        elseif req.target == "/metrics" && req.method == "POST"
            handle_metrics(req)
        elseif req.target == "/random_portfolios" && req.method == "POST"
            handle_random_portfolios(req)
        else
            json_resp(Dict("error" => "not found"); status=404)
        end
    catch e
        @error "handler error" exception=(e, catch_backtrace())
        error_resp("internal error: $(sprint(showerror, e))"; status=500)
    end
end

# ── main ─────────────────────────────────────────────────────────────────────

port = DEFAULT_PORT
for (i, arg) in enumerate(ARGS)
    if arg == "--port" && i < length(ARGS)
        port = parse(Int, ARGS[i + 1])
    end
end

@info "BlaqueBaux Portfolio Server starting on http://127.0.0.1:$port"
@info "Precompiling PortfolioOpt..."
# Warm up JuMP/Clarabel with a tiny problem so first dashboard request is fast
let
    R0 = randn(60, 4) .* 0.01
    μ0 = mean_returns(R0)
    Σ0 = shrinkage_cov(R0)[1]
    min_variance(Σ0)
    @info "Warm-up complete — server ready."
end

HTTP.serve(router, "127.0.0.1", port)
