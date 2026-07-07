"""
dashboard.py — BlaqueBaux Portfolio Optimization Dashboard
============================================================
Data source : Massive.com (or yfinance fallback)
Backend     : Julia portfolio_server.jl  (HTTP on 127.0.0.1:8766)
Launch      :
    # Terminal 1 — start Julia backend
    julia --project=. scripts/portfolio_server.jl

    # Terminal 2 — start dashboard
    conda activate ml
    python scripts/dashboard.py
    # → open http://127.0.0.1:8050
"""

import os, sys, time, json, logging
from datetime import datetime, timedelta, date

import requests
import numpy as np
import pandas as pd
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots

import dash
from dash import dcc, html, dash_table, Input, Output, State, callback_context, no_update
import dash_bootstrap_components as dbc

sys.path.insert(0, os.path.dirname(__file__))
from massive_client import (
    fetch_prices, prices_to_log_returns, DEFAULT_UNIVERSE
)

# ── config ────────────────────────────────────────────────────────────────────

JULIA_URL   = os.environ.get("JULIA_URL", "http://127.0.0.1:8766")
DASH_PORT   = int(os.environ.get("DASH_PORT", 8050))
DASH_DEBUG  = os.environ.get("DASH_DEBUG", "false").lower() == "true"

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("dashboard")

# ── colour palette ────────────────────────────────────────────────────────────

DARK_BG     = "#0d1117"
PANEL_BG    = "#161b22"
CARD_BG     = "#1c2333"
ACCENT      = "#1F6FEB"
ACCENT2     = "#388BFD"
GREEN       = "#3FB950"
RED         = "#F85149"
YELLOW      = "#D29922"
TEXT        = "#E6EDF3"
MUTED       = "#8B949E"
BORDER      = "#30363D"

PLOTLY_TEMPLATE = dict(
    layout=dict(
        paper_bgcolor=CARD_BG, plot_bgcolor=CARD_BG,
        font=dict(color=TEXT, family="Arial"),
        xaxis=dict(gridcolor=BORDER, zerolinecolor=BORDER),
        yaxis=dict(gridcolor=BORDER, zerolinecolor=BORDER),
        colorway=[ACCENT, GREEN, YELLOW, RED, "#A371F7", "#F78166", "#56D364"],
        legend=dict(bgcolor=CARD_BG, bordercolor=BORDER),
        margin=dict(l=50, r=20, t=40, b=40),
    )
)

# ── Julia helpers ─────────────────────────────────────────────────────────────

def julia_post(endpoint: str, payload: dict, timeout: int = 120) -> dict | None:
    try:
        r = requests.post(f"{JULIA_URL}/{endpoint.lstrip('/')}", json=payload, timeout=timeout)
        r.raise_for_status()
        return r.json()
    except Exception as exc:
        log.error("Julia %s failed: %s", endpoint, exc)
        return None

def julia_alive() -> bool:
    try:
        r = requests.get(f"{JULIA_URL}/health", timeout=3)
        return r.status_code == 200
    except Exception:
        return False

# ── layout helpers ────────────────────────────────────────────────────────────

def kpi_card(title, value_id, color=ACCENT2, icon=""):
    return dbc.Card([
        dbc.CardBody([
            html.Div(f"{icon}  {title}", style={"color": MUTED, "fontSize": "11px",
                                                "textTransform": "uppercase",
                                                "letterSpacing": "1px"}),
            html.Div(id=value_id, children="—",
                     style={"color": color, "fontSize": "26px", "fontWeight": "bold",
                            "marginTop": "4px"}),
        ])
    ], style={"background": CARD_BG, "border": f"1px solid {BORDER}", "borderRadius": "8px"})

def section_title(text):
    return html.H6(text, style={"color": MUTED, "textTransform": "uppercase",
                                 "letterSpacing": "1.5px", "fontSize": "11px",
                                 "margin": "12px 0 6px 0"})

# ── strategy descriptions ─────────────────────────────────────────────────────

STRATEGY_INFO = {
    "min_variance":      "Minimum Variance — minimize portfolio vol; ignores expected returns.",
    "max_sharpe":        "Maximum Sharpe — maximize risk-adjusted return (Markowitz tangency).",
    "risk_parity":       "Risk Parity / ERC — equal risk contribution from every asset.",
    "hrp":               "Hierarchical Risk Parity — López de Prado (2016); no matrix inversion.",
    "inverse_variance":  "Inverse-Variance — weight ∝ 1/σ²; naive, fast, surprisingly robust.",
    "max_diversification": "Maximum Diversification — maximize weighted avg vol / portfolio vol.",
    "min_cvar":          "Min CVaR — Rockafellar-Uryasev LP; minimizes tail expected loss at α.",
    "min_cdar":          "Min CDaR — minimize conditional drawdown-at-risk at level α.",
    "black_litterman":   "Black-Litterman — blend equilibrium priors with analyst views.",
}

# ── app ───────────────────────────────────────────────────────────────────────

app = dash.Dash(
    __name__,
    external_stylesheets=[dbc.themes.DARKLY, dbc.icons.BOOTSTRAP],
    suppress_callback_exceptions=True,
    title="BlaqueBaux — Portfolio Dashboard",
)

# ── sidebar ───────────────────────────────────────────────────────────────────

sidebar = dbc.Col([
    # Logo / title
    html.Div([
        html.Span("⬛ ", style={"fontSize": "22px"}),
        html.Span("BLAQUE", style={"color": TEXT, "fontWeight": "900", "fontSize": "18px"}),
        html.Span(" BAUX", style={"color": ACCENT, "fontWeight": "900", "fontSize": "18px"}),
    ], style={"marginBottom": "4px"}),
    html.Div("Portfolio Optimizer", style={"color": MUTED, "fontSize": "11px",
                                           "marginBottom": "18px"}),

    # Julia status pill
    html.Div(id="julia-status", children=[
        dbc.Badge("● Julia Server", id="julia-badge", color="secondary", pill=True)
    ], style={"marginBottom": "16px"}),

    html.Hr(style={"borderColor": BORDER}),

    # Universe selector
    section_title("Stock Universe"),
    dcc.Dropdown(
        id="ticker-select",
        options=[{"label": t, "value": t} for t in DEFAULT_UNIVERSE],
        value=["AAPL","MSFT","NVDA","GOOGL","AMZN","META","JPM","JNJ","XOM","PG"],
        multi=True,
        placeholder="Select tickers…",
        style={"fontSize": "13px"},
        className="mb-2",
    ),

    # Date range
    section_title("Date Range"),
    dbc.Row([
        dbc.Col(dcc.DatePickerSingle(
            id="date-start",
            date=(datetime.today() - timedelta(days=5*365)).strftime("%Y-%m-%d"),
            display_format="YYYY-MM-DD",
            style={"width": "100%", "fontSize": "12px"},
        ), width=6),
        dbc.Col(dcc.DatePickerSingle(
            id="date-end",
            date=datetime.today().strftime("%Y-%m-%d"),
            display_format="YYYY-MM-DD",
            style={"width": "100%", "fontSize": "12px"},
        ), width=6),
    ], className="mb-2"),

    # Return type
    section_title("Return Type"),
    dbc.RadioItems(
        id="return-type",
        options=[{"label": "Log returns", "value": "log"},
                 {"label": "Simple returns", "value": "simple"}],
        value="log",
        inline=True,
        className="mb-2",
        style={"fontSize": "13px"},
    ),

    html.Hr(style={"borderColor": BORDER}),

    # Strategy
    section_title("Optimization Strategy"),
    dcc.Dropdown(
        id="strategy-select",
        options=[{"label": k, "value": k} for k in STRATEGY_INFO],
        value="max_sharpe",
        clearable=False,
        style={"fontSize": "13px"},
    ),
    html.Div(id="strategy-desc", style={"color": MUTED, "fontSize": "11px",
                                         "marginTop": "6px", "marginBottom": "8px"}),

    # Constraints
    section_title("Constraints"),
    dbc.Checklist(
        id="long-only",
        options=[{"label": " Long only", "value": "long_only"}],
        value=["long_only"],
        className="mb-1",
        style={"fontSize": "13px"},
    ),
    dbc.Row([
        dbc.Col([
            html.Label("Max weight", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="w-max", type="number", value=0.25, min=0.05, max=1.0,
                      step=0.05, size="sm"),
        ], width=6),
        dbc.Col([
            html.Label("CVaR α", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="cvar-alpha", type="number", value=0.95, min=0.80,
                      max=0.99, step=0.01, size="sm"),
        ], width=6),
    ], className="mb-2"),

    html.Hr(style={"borderColor": BORDER}),

    # Backtest params
    section_title("Backtest Parameters"),
    dbc.Row([
        dbc.Col([
            html.Label("Lookback (days)", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="lookback", type="number", value=252, min=60,
                      max=756, step=21, size="sm"),
        ], width=6),
        dbc.Col([
            html.Label("Rebalance (days)", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="rebalance-freq", type="number", value=21, min=1,
                      max=252, step=1, size="sm"),
        ], width=6),
    ], className="mb-1"),
    dbc.Row([
        dbc.Col([
            html.Label("Trans. cost (bps)", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="cost-bps", type="number", value=5.0, min=0.0,
                      max=50.0, step=0.5, size="sm"),
        ], width=6),
        dbc.Col([
            html.Label("Frontier points", style={"fontSize": "11px", "color": MUTED}),
            dbc.Input(id="n-points", type="number", value=25, min=10,
                      max=100, step=5, size="sm"),
        ], width=6),
    ], className="mb-2"),

    html.Hr(style={"borderColor": BORDER}),

    # Action buttons
    dbc.Button([html.I(className="bi bi-cloud-download me-2"),
                "Pull Data from Massive"],
               id="btn-pull", color="secondary", className="w-100 mb-2",
               style={"fontWeight": "600"}),
    dbc.Button([html.I(className="bi bi-cpu me-2"),
                "Run Optimization"],
               id="btn-optimize", color="primary", className="w-100 mb-2",
               style={"fontWeight": "600"}),

    # Status bar
    html.Div(id="status-bar",
             children="Ready — pull data then run optimization.",
             style={"color": MUTED, "fontSize": "11px", "marginTop": "8px",
                    "minHeight": "32px"}),

    # Hidden stores
    dcc.Store(id="store-prices"),    # raw prices JSON (tickers, dates, matrix)
    dcc.Store(id="store-returns"),   # log returns JSON
    dcc.Store(id="store-opt"),       # optimization result
    dcc.Store(id="store-bt"),        # backtest result
    dcc.Store(id="store-frontier"),  # efficient frontier result
    dcc.Interval(id="julia-ping", interval=5000, n_intervals=0),

], width=2, style={"background": PANEL_BG, "padding": "16px 14px",
                   "height": "100vh", "overflowY": "auto",
                   "borderRight": f"1px solid {BORDER}", "position": "fixed",
                   "top": 0, "left": 0, "zIndex": 999})

# ── main content ──────────────────────────────────────────────────────────────

main_content = dbc.Col([

    # ── KPI row ──────────────────────────────────────────────────────────────
    dbc.Row([
        dbc.Col(kpi_card("Ann. Return",  "kpi-ret",    GREEN),  width=2),
        dbc.Col(kpi_card("Ann. Vol",     "kpi-vol",    YELLOW), width=2),
        dbc.Col(kpi_card("Sharpe",       "kpi-sharpe", ACCENT2),width=2),
        dbc.Col(kpi_card("Max Drawdown", "kpi-mdd",    RED),    width=2),
        dbc.Col(kpi_card("Calmar",       "kpi-calmar", ACCENT2),width=2),
        dbc.Col(kpi_card("95% CVaR",     "kpi-cvar",   YELLOW), width=2),
    ], className="mb-3 g-2"),

    # ── tabs ─────────────────────────────────────────────────────────────────
    dbc.Tabs([

        # Tab 1 — Portfolio Overview
        dbc.Tab(label="Portfolio", tab_id="tab-portfolio", children=[
            dbc.Row([
                # Weights pie
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Allocation", style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-pie", style={"height": "340px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=4),

                # Weights bar + table
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Weight Distribution",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-weights-bar", style={"height": "340px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=8),
            ], className="mb-3 g-2"),

            # Holdings table
            dbc.Card([
                dbc.CardHeader("Holdings — Stocks to Purchase",
                               style={"color": MUTED, "fontSize": "12px"}),
                dbc.CardBody(html.Div(id="holdings-table")),
            ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}),
        ]),

        # Tab 2 — Efficient Frontier
        dbc.Tab(label="Frontier", tab_id="tab-frontier", children=[
            dbc.Row([
                dbc.Col([
                    section_title("Resampled Frontier Settings"),
                    dbc.Row([
                        dbc.Col([
                            html.Label("Resamples", style={"fontSize": "11px", "color": MUTED}),
                            dbc.Input(id="n-resample", type="number", value=100,
                                      min=20, max=500, step=20, size="sm"),
                        ], width=4),
                        dbc.Col([
                            html.Label("DGP sampler", style={"fontSize": "11px", "color": MUTED}),
                            dcc.Dropdown(
                                id="sampler-select",
                                options=[
                                    {"label": "Stationary Bootstrap", "value": "stationary_bootstrap"},
                                    {"label": "Block Bootstrap",       "value": "block_bootstrap"},
                                    {"label": "IID Bootstrap",         "value": "iid_bootstrap"},
                                    {"label": "t-Copula (fat tails)",  "value": "t_copula"},
                                    {"label": "Student-t",             "value": "student_t"},
                                    {"label": "Gaussian (baseline)",   "value": "gaussian"},
                                ],
                                value="stationary_bootstrap", clearable=False,
                                style={"fontSize": "12px"},
                            ),
                        ], width=5),
                        dbc.Col([
                            html.Label("DoF (ν)", style={"fontSize": "11px", "color": MUTED}),
                            dbc.Input(id="frontier-nu", type="number", value=5.0,
                                      min=2.5, max=30.0, step=0.5, size="sm"),
                        ], width=3),
                    ], className="mb-2"),
                    dbc.Button("Compute Frontier", id="btn-frontier", color="secondary",
                               className="mt-1", size="sm"),
                ], width=12),
            ], className="mb-2"),
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Efficient Frontier + Feasibility Set",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-frontier", style={"height": "460px"},
                                          config={"displayModeBar": True})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=8),
                dbc.Col(dbc.Card([
                    dbc.CardHeader("CVaR vs Vol (Resampled)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-cvar-frontier", style={"height": "460px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=4),
            ], className="g-2"),
        ]),

        # Tab 3 — Performance
        dbc.Tab(label="Performance", tab_id="tab-performance", children=[
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Cumulative Returns vs Equal-Weight Benchmark",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-cumret", style={"height": "320px"},
                                          config={"displayModeBar": True})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=12),
            ], className="mb-3 g-2"),
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Drawdown", style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-drawdown", style={"height": "240px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=8),
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Rolling Sharpe (63-day)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-rolling-sharpe", style={"height": "240px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=4),
            ], className="g-2"),
        ]),

        # Tab 4 — Risk Analysis
        dbc.Tab(label="Risk", tab_id="tab-risk", children=[
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Correlation Heatmap",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-corr", style={"height": "380px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=6),
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Risk Contributions",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-risk-contrib", style={"height": "380px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=6),
            ], className="mb-3 g-2"),
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("VaR / CVaR by Asset (historical, 95%)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-var-asset", style={"height": "260px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=12),
            ], className="g-2"),
        ]),

        # Tab 5 — Backtest
        dbc.Tab(label="Backtest", tab_id="tab-backtest", children=[
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Walk-Forward Equity Curve (Net of Transaction Costs)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-bt-equity", style={"height": "340px"},
                                          config={"displayModeBar": True})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=12),
            ], className="mb-3 g-2"),
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Turnover per Rebalance",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-bt-turnover", style={"height": "200px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=6),
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Backtest Metrics Summary",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(html.Div(id="bt-metrics-table")),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=6),
            ], className="g-2"),
        ]),

        # Tab 6 — Individual Assets
        dbc.Tab(label="Assets", tab_id="tab-assets", children=[
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Asset Price History (normalized to 100)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-prices", style={"height": "380px"},
                                          config={"displayModeBar": True})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=12),
            ], className="mb-3 g-2"),
            dbc.Row([
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Return Distribution (violin)",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(dcc.Graph(id="fig-violin", style={"height": "280px"},
                                          config={"displayModeBar": False})),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=8),
                dbc.Col(dbc.Card([
                    dbc.CardHeader("Annualized Stats per Asset",
                                   style={"color": MUTED, "fontSize": "12px"}),
                    dbc.CardBody(html.Div(id="asset-stats-table")),
                ], style={"background": CARD_BG, "border": f"1px solid {BORDER}"}), width=4),
            ], className="g-2"),
        ]),

    ], id="main-tabs", active_tab="tab-portfolio",
       style={"borderBottom": f"1px solid {BORDER}"}),

], width={"size": 10, "offset": 2},
   style={"padding": "16px 20px", "background": DARK_BG, "minHeight": "100vh"})

# ── full layout ───────────────────────────────────────────────────────────────

app.layout = dbc.Container([
    dbc.Row([sidebar, main_content], className="g-0"),
], fluid=True, style={"background": DARK_BG, "minHeight": "100vh", "padding": 0})

# ═════════════════════════════════════════════════════════════════════════════
# CALLBACKS
# ═════════════════════════════════════════════════════════════════════════════

# ── Julia server ping ─────────────────────────────────────────────────────────
@app.callback(
    Output("julia-badge", "color"),
    Output("julia-badge", "children"),
    Input("julia-ping", "n_intervals"),
)
def ping_julia(_):
    alive = julia_alive()
    return ("success", "● Julia Server Online") if alive else ("danger", "● Julia Server Offline")

# ── strategy description ──────────────────────────────────────────────────────
@app.callback(
    Output("strategy-desc", "children"),
    Input("strategy-select", "value"),
)
def update_strategy_desc(strat):
    return STRATEGY_INFO.get(strat, "")

# ── PULL DATA ─────────────────────────────────────────────────────────────────
@app.callback(
    Output("store-prices",  "data"),
    Output("store-returns", "data"),
    Output("status-bar",    "children", allow_duplicate=True),
    Input("btn-pull", "n_clicks"),
    State("ticker-select", "value"),
    State("date-start",    "date"),
    State("date-end",      "date"),
    State("return-type",   "value"),
    prevent_initial_call=True,
)
def pull_data(n_clicks, tickers, start, end, ret_type):
    if not tickers:
        return no_update, no_update, "⚠ Select at least one ticker."
    tickers = list(tickers)
    status = f"⏳ Pulling {len(tickers)} tickers from Massive.com…"
    try:
        prices = fetch_prices(tickers, start, end)
        tickers_ok = list(prices.columns)
        dates_str  = [str(d.date()) for d in prices.index]

        prices_store = {
            "tickers": tickers_ok,
            "dates":   dates_str,
            "matrix":  prices.values.tolist(),
        }

        if ret_type == "log":
            R = np.log(prices / prices.shift(1)).dropna()
        else:
            R = prices.pct_change().dropna()

        returns_store = {
            "tickers": tickers_ok,
            "dates":   dates_str[1:],
            "matrix":  R.values.tolist(),
        }

        status = (f"✓ Loaded {len(tickers_ok)} tickers × {len(dates_str)} days "
                  f"({start} → {end}). Run optimization to continue.")
        return prices_store, returns_store, status

    except Exception as exc:
        return no_update, no_update, f"✗ Data pull failed: {exc}"

# ── RUN OPTIMIZATION ─────────────────────────────────────────────────────────
@app.callback(
    Output("store-opt",  "data"),
    Output("store-bt",   "data"),
    Output("status-bar", "children", allow_duplicate=True),
    Output("kpi-ret",    "children"),
    Output("kpi-vol",    "children"),
    Output("kpi-sharpe", "children"),
    Output("kpi-mdd",    "children"),
    Output("kpi-calmar", "children"),
    Output("kpi-cvar",   "children"),
    Input("btn-optimize", "n_clicks"),
    State("store-returns",    "data"),
    State("strategy-select",  "value"),
    State("long-only",        "value"),
    State("w-max",            "value"),
    State("cvar-alpha",       "value"),
    State("lookback",         "value"),
    State("rebalance-freq",   "value"),
    State("cost-bps",         "value"),
    prevent_initial_call=True,
)
def run_optimization(n_clicks, ret_store, strategy, long_only_vals,
                     w_max, cvar_alpha, lookback, rebalance, cost_bps):
    if not ret_store:
        return (no_update,) * 8 + ("No data — pull first.",)

    R_mat  = ret_store["matrix"]
    tickers = ret_store["tickers"]
    lo = "long_only" in (long_only_vals or [])

    # Optimization
    opt_payload = {
        "returns":    R_mat,
        "tickers":    tickers,
        "strategy":   strategy,
        "long_only":  lo,
        "w_max":      float(w_max) if w_max else None,
        "cvar_alpha": float(cvar_alpha) if cvar_alpha else 0.95,
    }
    opt = julia_post("optimize", opt_payload)
    if not opt or "error" in opt:
        err = opt.get("error", "unknown") if opt else "Julia server unreachable"
        return (no_update,) * 7 + (no_update, f"✗ Optimization failed: {err}")

    # Backtest
    bt_payload = {
        "returns":   R_mat,
        "tickers":   tickers,
        "strategy":  strategy,
        "lookback":  int(lookback or 252),
        "rebalance": int(rebalance or 21),
        "cost_bps":  float(cost_bps or 5.0),
    }
    bt = julia_post("backtest", bt_payload)

    m = opt["metrics"]
    fmt_pct = lambda x: f"{x*100:.2f}%"
    fmt_f   = lambda x: f"{x:.3f}"

    status = (f"✓ {strategy.replace('_',' ').title()} — "
              f"Sharpe {fmt_f(m['sharpe'])} | "
              f"Ann. Ret {fmt_pct(m['ann_return'])} | "
              f"MaxDD {fmt_pct(m['max_dd'])}")

    return (
        opt, bt, status,
        fmt_pct(m["ann_return"]),
        fmt_pct(m["ann_vol"]),
        fmt_f(m["sharpe"]),
        fmt_pct(m["max_dd"]),
        fmt_f(m["calmar"]),
        fmt_pct(m["cvar_95"]),
    )

# ── PORTFOLIO CHARTS ─────────────────────────────────────────────────────────
@app.callback(
    Output("fig-pie",          "figure"),
    Output("fig-weights-bar",  "figure"),
    Output("holdings-table",   "children"),
    Input("store-opt", "data"),
    prevent_initial_call=True,
)
def update_portfolio_charts(opt):
    if not opt:
        empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
        return empty, empty, "No data yet."

    tickers = opt["tickers"]
    weights = opt["weights_vec"]
    rc      = [opt["risk_contributions"].get(t, 0) for t in tickers]

    # filter tiny weights for pie display
    threshold = 0.005
    labels_pie = [t for t, w in zip(tickers, weights) if w > threshold]
    vals_pie   = [w for w in weights if w > threshold]

    pie = go.Figure(go.Pie(
        labels=labels_pie, values=vals_pie, hole=0.45,
        textinfo="label+percent",
        marker=dict(colors=px.colors.sequential.Blues_r[:len(labels_pie)]),
        textfont=dict(size=11, color=TEXT),
    ))
    pie.update_layout(**PLOTLY_TEMPLATE["layout"], showlegend=False)

    # Weight + risk-contrib horizontal bar
    sorted_idx = sorted(range(len(tickers)), key=lambda i: weights[i], reverse=True)
    s_tickers  = [tickers[i] for i in sorted_idx]
    s_weights  = [weights[i] for i in sorted_idx]
    s_rc       = [rc[i]      for i in sorted_idx]

    bar = go.Figure()
    bar.add_trace(go.Bar(name="Weight", x=s_weights, y=s_tickers,
                         orientation="h", marker_color=ACCENT))
    bar.add_trace(go.Bar(name="Risk Contrib", x=s_rc, y=s_tickers,
                         orientation="h", marker_color=RED, opacity=0.7))
    bar.update_layout(**PLOTLY_TEMPLATE["layout"],
                      barmode="overlay",
                      xaxis_tickformat=".1%",
                      legend=dict(orientation="h", y=-0.15))

    # Holdings table
    portfolio_value = 100_000  # illustrative $100k
    rows = []
    for t, w, r in zip(s_tickers, s_weights, s_rc):
        notional = w * portfolio_value
        rows.append({
            "Ticker":          t,
            "Weight":          f"{w*100:.2f}%",
            "$ Notional":      f"${notional:,.0f}",
            "Risk Contrib":    f"{r*100:.2f}%",
        })

    table = dash_table.DataTable(
        data=rows,
        columns=[{"name": c, "id": c} for c in rows[0].keys()] if rows else [],
        style_table={"overflowX": "auto"},
        style_header={"backgroundColor": DARK_BG, "color": MUTED, "fontWeight": "600",
                      "fontSize": "12px", "border": f"1px solid {BORDER}"},
        style_cell={"backgroundColor": CARD_BG, "color": TEXT, "fontSize": "13px",
                    "border": f"1px solid {BORDER}", "padding": "6px 12px"},
        style_data_conditional=[
            {"if": {"row_index": "odd"}, "backgroundColor": PANEL_BG},
        ],
        sort_action="native",
        page_size=20,
    )
    return pie, bar, table

# ── COMPUTE FRONTIER ─────────────────────────────────────────────────────────
@app.callback(
    Output("store-frontier",    "data"),
    Output("status-bar",        "children", allow_duplicate=True),
    Input("btn-frontier",       "n_clicks"),
    State("store-returns",      "data"),
    State("n-points",           "value"),
    State("n-resample",         "value"),
    State("sampler-select",     "value"),
    State("frontier-nu",        "value"),
    State("long-only",          "value"),
    State("w-max",              "value"),
    prevent_initial_call=True,
)
def compute_frontier(n_clicks, ret_store, n_points, n_resample,
                     sampler, nu, long_only_vals, w_max):
    if not ret_store:
        return no_update, "⚠ Pull data first."
    lo = "long_only" in (long_only_vals or [])
    R_mat   = ret_store["matrix"]
    tickers = ret_store["tickers"]

    # Point-estimate frontier
    ef_data = julia_post("frontier", {
        "returns": R_mat, "tickers": tickers,
        "n_points": int(n_points or 25), "long_only": lo,
        "w_max": float(w_max) if w_max else None,
    })

    # Resampled frontier
    rf_data = julia_post("resampled_frontier", {
        "returns": R_mat, "tickers": tickers,
        "n_points": int(n_points or 25),
        "n_resample": int(n_resample or 100),
        "sampler": sampler or "stationary_bootstrap",
        "nu": float(nu or 5.0),
        "long_only": lo,
    })

    # Random portfolios for backdrop
    rp_data = julia_post("random_portfolios", {"returns": R_mat, "n": 2000})

    return {"ef": ef_data, "rf": rf_data, "rp": rp_data}, "✓ Frontier computed."

@app.callback(
    Output("fig-frontier",      "figure"),
    Output("fig-cvar-frontier", "figure"),
    Input("store-frontier", "data"),
    State("store-opt",      "data"),
    prevent_initial_call=True,
)
def update_frontier_chart(frontier, opt):
    empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
    if not frontier:
        return empty, empty

    fig = go.Figure()
    fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Efficient Frontier",
                      xaxis_title="Annualized Vol", yaxis_title="Annualized Return",
                      xaxis_tickformat=".1%", yaxis_tickformat=".1%")

    rp = frontier.get("rp")
    if rp:
        fig.add_trace(go.Scatter(
            x=rp["risks"], y=rp["returns"], mode="markers",
            marker=dict(size=3, color=MUTED, opacity=0.3),
            name="Feasibility set", showlegend=True,
        ))

    ef = frontier.get("ef")
    if ef:
        fig.add_trace(go.Scatter(
            x=ef["risks"], y=ef["returns"], mode="lines+markers",
            line=dict(color=ACCENT, width=2),
            marker=dict(size=5), name="Efficient Frontier",
        ))

    rf = frontier.get("rf")
    if rf:
        fig.add_trace(go.Scatter(
            x=rf["risks"], y=rf["returns"], mode="lines+markers",
            line=dict(color=GREEN, width=2, dash="dash"),
            marker=dict(size=5), name="Resampled Frontier",
        ))

    if opt:
        m = opt["metrics"]
        fig.add_trace(go.Scatter(
            x=[m["ann_vol"]], y=[m["ann_return"]], mode="markers",
            marker=dict(size=14, color=YELLOW, symbol="star"),
            name="Current Portfolio",
        ))

    # CVaR frontier chart
    cvar_fig = go.Figure()
    cvar_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="CVaR vs Vol",
                           xaxis_title="Ann. Vol", yaxis_title="95% CVaR",
                           xaxis_tickformat=".1%", yaxis_tickformat=".1%")
    if rf:
        cvar_fig.add_trace(go.Scatter(
            x=rf["risks"], y=rf["cvars"], mode="lines+markers",
            line=dict(color=RED, width=2),
            marker=dict(size=5), name="Resampled CVaR",
        ))

    return fig, cvar_fig

# ── PERFORMANCE CHARTS ────────────────────────────────────────────────────────
@app.callback(
    Output("fig-cumret",        "figure"),
    Output("fig-drawdown",      "figure"),
    Output("fig-rolling-sharpe","figure"),
    Input("store-bt",      "data"),
    State("store-returns", "data"),
    prevent_initial_call=True,
)
def update_performance(bt, ret_store):
    empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
    if not bt:
        return empty, empty, empty

    returns = np.array(bt["returns"])
    cumret  = np.array(bt["cumulative"])
    dates_idx = bt["dates"]
    bench   = bt.get("benchmark_cum")

    # Use actual dates if available
    all_dates = ret_store.get("dates", []) if ret_store else []
    x_vals = [all_dates[i] if i < len(all_dates) else i for i in dates_idx]

    # Cumulative returns
    cum_fig = go.Figure()
    cum_fig.update_layout(**PLOTLY_TEMPLATE["layout"],
                          title="Cumulative Returns", xaxis_title="Date",
                          yaxis_title="Return", yaxis_tickformat=".0%")
    cum_fig.add_trace(go.Scatter(x=x_vals, y=cumret, mode="lines",
                                  line=dict(color=ACCENT, width=2),
                                  name="Strategy", fill="tozeroy",
                                  fillcolor=f"rgba(31,111,235,0.1)"))
    if bench:
        cum_fig.add_trace(go.Scatter(x=x_vals, y=bench, mode="lines",
                                      line=dict(color=MUTED, width=1, dash="dot"),
                                      name="Equal Weight"))

    # Drawdown
    wealth = 1 + cumret
    peak   = np.maximum.accumulate(wealth)
    dd     = wealth / peak - 1

    dd_fig = go.Figure()
    dd_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Drawdown",
                          yaxis_tickformat=".1%")
    dd_fig.add_trace(go.Scatter(x=x_vals, y=dd, mode="lines",
                                 line=dict(color=RED, width=1.5),
                                 fill="tozeroy", fillcolor="rgba(248,81,73,0.15)",
                                 name="Drawdown"))

    # Rolling Sharpe (63-day)
    window = 63
    roll_sharpe = []
    for i in range(len(returns)):
        if i < window:
            roll_sharpe.append(None)
        else:
            s = returns[i-window:i]
            rs = np.mean(s) / (np.std(s) + 1e-12) * np.sqrt(252)
            roll_sharpe.append(rs)

    rs_fig = go.Figure()
    rs_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Rolling Sharpe (63d)")
    rs_fig.add_trace(go.Scatter(x=x_vals, y=roll_sharpe, mode="lines",
                                 line=dict(color=GREEN, width=1.5), name="Rolling Sharpe"))
    rs_fig.add_hline(y=0, line_color=MUTED, line_dash="dash", line_width=1)

    return cum_fig, dd_fig, rs_fig

# ── RISK CHARTS ───────────────────────────────────────────────────────────────
@app.callback(
    Output("fig-corr",        "figure"),
    Output("fig-risk-contrib","figure"),
    Output("fig-var-asset",   "figure"),
    Input("store-opt",     "data"),
    State("store-returns", "data"),
    prevent_initial_call=True,
)
def update_risk_charts(opt, ret_store):
    empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
    if not opt or not ret_store:
        return empty, empty, empty

    tickers = opt["tickers"]
    R       = np.array(ret_store["matrix"])
    rc      = [opt["risk_contributions"].get(t, 0) for t in tickers]
    weights = opt["weights_vec"]

    # Correlation heatmap
    corr = np.corrcoef(R.T)
    corr_fig = go.Figure(go.Heatmap(
        z=corr, x=tickers, y=tickers,
        colorscale="RdBu_r", zmin=-1, zmax=1,
        text=np.round(corr, 2),
        texttemplate="%{text}",
        textfont={"size": 9},
        showscale=True,
    ))
    corr_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Correlation Matrix")

    # Risk contributions
    sorted_idx = sorted(range(len(tickers)), key=lambda i: rc[i], reverse=True)
    rc_fig = go.Figure(go.Bar(
        x=[rc[i] for i in sorted_idx],
        y=[tickers[i] for i in sorted_idx],
        orientation="h",
        marker_color=[ACCENT if weights[i] > 0.05 else MUTED for i in sorted_idx],
    ))
    rc_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Risk Contributions",
                          xaxis_tickformat=".1%")

    # VaR / CVaR per asset
    var95  = [-np.percentile(R[:, j], 5) for j in range(len(tickers))]
    cvar95 = [
        -np.mean(R[:, j][R[:, j] <= np.percentile(R[:, j], 5)]) * np.sqrt(252)
        for j in range(len(tickers))
    ]
    var_ann = [v * np.sqrt(252) for v in var95]

    var_fig = go.Figure()
    var_fig.add_trace(go.Bar(name="95% VaR (ann.)", x=tickers, y=var_ann,
                              marker_color=YELLOW))
    var_fig.add_trace(go.Bar(name="95% CVaR (ann.)", x=tickers, y=cvar95,
                              marker_color=RED, opacity=0.8))
    var_fig.update_layout(**PLOTLY_TEMPLATE["layout"], barmode="group",
                           title="VaR / CVaR per Asset", yaxis_tickformat=".1%")

    return corr_fig, rc_fig, var_fig

# ── BACKTEST CHARTS ───────────────────────────────────────────────────────────
@app.callback(
    Output("fig-bt-equity",   "figure"),
    Output("fig-bt-turnover", "figure"),
    Output("bt-metrics-table","children"),
    Input("store-bt",      "data"),
    State("store-returns", "data"),
    prevent_initial_call=True,
)
def update_backtest_charts(bt, ret_store):
    empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
    if not bt:
        return empty, empty, "Run optimization first."

    returns  = np.array(bt["returns"])
    cumret   = np.array(bt["cumulative"])
    turnover = bt.get("turnover", [])
    bench    = bt.get("benchmark_cum")
    dates_idx = bt["dates"]
    all_dates = ret_store.get("dates", []) if ret_store else []
    x_vals = [all_dates[i] if i < len(all_dates) else i for i in dates_idx]

    # Equity curve
    eq_fig = go.Figure()
    eq_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Walk-Forward Equity Curve",
                          yaxis_tickformat=".0%")
    eq_fig.add_trace(go.Scatter(x=x_vals, y=cumret, mode="lines",
                                 line=dict(color=ACCENT, width=2),
                                 fill="tozeroy", fillcolor="rgba(31,111,235,0.08)",
                                 name="Strategy"))
    if bench:
        eq_fig.add_trace(go.Scatter(x=x_vals, y=bench, mode="lines",
                                     line=dict(color=MUTED, width=1, dash="dot"),
                                     name="Equal Weight"))

    # Turnover
    to_fig = go.Figure(go.Bar(y=turnover, marker_color=YELLOW, name="Turnover"))
    to_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Rebalance Turnover",
                          yaxis_tickformat=".1%")

    # Metrics table
    m = bt.get("metrics", {})
    rows = [
        {"Metric": "Ann. Return", "Value": f"{m.get('ann_return',0)*100:.2f}%"},
        {"Metric": "Ann. Vol",    "Value": f"{m.get('ann_vol',0)*100:.2f}%"},
        {"Metric": "Sharpe",      "Value": f"{m.get('sharpe',0):.3f}"},
        {"Metric": "Sortino",     "Value": f"{m.get('sortino',0):.3f}"},
        {"Metric": "Max DD",      "Value": f"{m.get('max_dd',0)*100:.2f}%"},
        {"Metric": "Calmar",      "Value": f"{m.get('calmar',0):.3f}"},
        {"Metric": "Avg Turnover","Value": f"{np.mean(turnover)*100:.1f}%" if turnover else "—"},
    ]
    tbl = dash_table.DataTable(
        data=rows,
        columns=[{"name": "Metric", "id": "Metric"}, {"name": "Value", "id": "Value"}],
        style_header={"backgroundColor": DARK_BG, "color": MUTED, "fontSize": "12px",
                       "border": f"1px solid {BORDER}"},
        style_cell={"backgroundColor": CARD_BG, "color": TEXT, "fontSize": "13px",
                     "border": f"1px solid {BORDER}", "padding": "6px 12px"},
        style_data_conditional=[
            {"if": {"row_index": "odd"}, "backgroundColor": PANEL_BG}
        ],
    )
    return eq_fig, to_fig, tbl

# ── ASSET CHARTS ──────────────────────────────────────────────────────────────
@app.callback(
    Output("fig-prices",       "figure"),
    Output("fig-violin",       "figure"),
    Output("asset-stats-table","children"),
    Input("store-prices",  "data"),
    State("store-returns", "data"),
    prevent_initial_call=True,
)
def update_asset_charts(prices_store, ret_store):
    empty = go.Figure().update_layout(**PLOTLY_TEMPLATE["layout"])
    if not prices_store:
        return empty, empty, "Pull data first."

    tickers = prices_store["tickers"]
    prices  = np.array(prices_store["matrix"])
    dates   = prices_store["dates"]

    # Normalized prices
    prices_norm = prices / prices[0] * 100
    price_fig = go.Figure()
    price_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Normalized Price History (100 = start)")
    colors = px.colors.qualitative.Plotly
    for j, t in enumerate(tickers):
        price_fig.add_trace(go.Scatter(
            x=dates, y=prices_norm[:, j], mode="lines",
            line=dict(width=1.5, color=colors[j % len(colors)]),
            name=t,
        ))

    # Violin
    if ret_store:
        R = np.array(ret_store["matrix"])
        violin_fig = go.Figure()
        violin_fig.update_layout(**PLOTLY_TEMPLATE["layout"], title="Daily Return Distribution",
                                  yaxis_tickformat=".1%")
        for j, t in enumerate(tickers):
            violin_fig.add_trace(go.Violin(
                y=R[:, j], name=t, box_visible=True, meanline_visible=True,
                line_color=colors[j % len(colors)], fillcolor=colors[j % len(colors)],
                opacity=0.6,
            ))
    else:
        violin_fig = empty

    # Per-asset stats table
    rows = []
    if ret_store:
        R = np.array(ret_store["matrix"])
        for j, t in enumerate(tickers):
            r = R[:, j]
            rows.append({
                "Ticker":    t,
                "Ann. Ret":  f"{np.mean(r)*252*100:.1f}%",
                "Ann. Vol":  f"{np.std(r)*np.sqrt(252)*100:.1f}%",
                "Sharpe":    f"{(np.mean(r)*252)/(np.std(r)*np.sqrt(252)+1e-12):.2f}",
                "Skew":      f"{float(pd.Series(r).skew()):.2f}",
                "Kurt":      f"{float(pd.Series(r).kurt()):.2f}",
            })
    if rows:
        tbl = dash_table.DataTable(
            data=rows,
            columns=[{"name": c, "id": c} for c in rows[0]],
            style_header={"backgroundColor": DARK_BG, "color": MUTED, "fontSize": "11px",
                           "border": f"1px solid {BORDER}"},
            style_cell={"backgroundColor": CARD_BG, "color": TEXT, "fontSize": "12px",
                         "border": f"1px solid {BORDER}", "padding": "4px 8px"},
            style_data_conditional=[
                {"if": {"row_index": "odd"}, "backgroundColor": PANEL_BG}
            ],
            sort_action="native", page_size=15,
        )
    else:
        tbl = "No return data."

    return price_fig, violin_fig, tbl

# ═════════════════════════════════════════════════════════════════════════════
# Entry point
# ═════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print(f"""
╔══════════════════════════════════════════════════════╗
║       BLAQUE BAUX  —  Portfolio Dashboard            ║
║                                                      ║
║  Dashboard  → http://127.0.0.1:{DASH_PORT}               ║
║  Julia API  → {JULIA_URL:<37}║
║                                                      ║
║  Start Julia server first:                           ║
║    julia --project=. scripts/portfolio_server.jl     ║
╚══════════════════════════════════════════════════════╝
""")
    app.run(debug=DASH_DEBUG, host="127.0.0.1", port=DASH_PORT)
