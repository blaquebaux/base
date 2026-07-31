#!/usr/bin/python3
# =============================================================================
# pnl_attribution.py — daily P&L + per-asset attribution logger (READ-ONLY).
#
# Snapshots the Alpaca account and positions and appends three things:
#   logs/pnl_portfolio.csv   one row/snapshot: equity, day P&L, gross/net leverage
#   logs/pnl_positions.csv   one row/asset/snapshot: mkt value, day P&L, weight
#   logs/pnl_<YYYY-MM>.log   a human-readable table block (also printed to stdout)
#
# It NEVER trades and never prints keys. Any failure exits 0 so it can't break
# the trade job that calls it.
#
#   python3 scripts/pnl_attribution.py [open|close|manual]   (default: manual)
#
# Keys come from the environment (ALPACA_KEY_ID / ALPACA_SECRET_KEY), exactly
# as the daily wrappers already source them from ~/.config/blaquebaux/alpaca.env.
# =============================================================================
import os, sys, csv, json, urllib.request
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
    ET = ZoneInfo("America/New_York")
except Exception:
    ET = None

PHASE = (sys.argv[1] if len(sys.argv) > 1 else "manual").lower()
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(REPO, "logs"); os.makedirs(LOGDIR, exist_ok=True)
BASE = os.environ.get("ALPACA_BASE_URL", "https://paper-api.alpaca.markets").rstrip("/") + "/v2"


def warn(msg):
    print("pnl_attribution: WARN " + msg)


def get(path):
    key = os.environ.get("ALPACA_KEY_ID"); sec = os.environ.get("ALPACA_SECRET_KEY")
    if not key or not sec:
        raise RuntimeError("ALPACA_KEY_ID / ALPACA_SECRET_KEY not set in environment")
    req = urllib.request.Request(BASE + path,
                                 headers={"APCA-API-KEY-ID": key, "APCA-API-SECRET-KEY": sec})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def append_csv(path, header, row):
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(header)
        w.writerow(row)


def f(x, d=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return d


def main():
    now = datetime.now(ET) if ET else datetime.now()
    date = now.strftime("%Y-%m-%d")
    ts = now.strftime("%Y-%m-%d %H:%M:%S %Z").strip()

    a = get("/account")
    eq = f(a["equity"]); le = f(a["last_equity"])
    day_pl = eq - le
    day_pct = (day_pl / le * 100) if le else 0.0
    lmv = f(a["long_market_value"]); smv = f(a["short_market_value"])
    gross = abs(lmv) + abs(smv); net = lmv + smv
    gross_x = gross / eq if eq else 0.0
    net_x = net / eq if eq else 0.0
    cash = f(a["cash"]); status = a.get("status", "?")

    append_csv(os.path.join(LOGDIR, "pnl_portfolio.csv"),
               ["date", "timestamp_et", "phase", "equity", "last_equity", "day_pl", "day_pct",
                "gross_mv", "gross_x", "net_x", "cash", "status"],
               [date, ts, PHASE, "%.2f" % eq, "%.2f" % le, "%.2f" % day_pl, "%.4f" % day_pct,
                "%.2f" % gross, "%.4f" % gross_x, "%.4f" % net_x, "%.2f" % cash, status])

    ps = get("/positions")
    rows = []
    for p in ps:
        mv = f(p["market_value"])
        rows.append({
            "symbol": p["symbol"], "side": p["side"], "qty": f(p["qty"]),
            "mv": mv, "pl": f(p["unrealized_intraday_pl"]),
            "pct": f(p["unrealized_intraday_plpc"]) * 100,
            "wt": (abs(mv) / gross * 100) if gross else 0.0,
        })
    rows.sort(key=lambda r: abs(r["pl"]), reverse=True)
    for r in rows:
        append_csv(os.path.join(LOGDIR, "pnl_positions.csv"),
                   ["date", "timestamp_et", "phase", "symbol", "side", "qty",
                    "market_value", "day_pl", "day_pct", "weight_pct"],
                   [date, ts, PHASE, r["symbol"], r["side"], "%.0f" % r["qty"],
                    "%.2f" % r["mv"], "%.2f" % r["pl"], "%.4f" % r["pct"], "%.2f" % r["wt"]])

    # human-readable block
    L = []
    L.append("================ P&L attribution [{}] {} ================".format(PHASE, ts))
    L.append("equity  ${:,.2f}    day P&L  ${:,.2f}  ({:+.2f}%)    gross {:.2f}x  net {:.2f}x    {}"
             .format(eq, day_pl, day_pct, gross_x, net_x, status))
    if rows:
        L.append("  {:<6}{:<6}{:>9}{:>14}{:>12}{:>9}{:>8}"
                 .format("sym", "side", "qty", "mkt_val", "day_pl", "day_%", "wt_%"))
        for r in rows:
            L.append("  {:<6}{:<6}{:>9.0f}{:>14,.0f}{:>12,.2f}{:>8.2f}%{:>7.1f}%"
                     .format(r["symbol"], r["side"], r["qty"], r["mv"], r["pl"], r["pct"], r["wt"]))
    else:
        L.append("  (flat — no open positions)")
    block = "\n".join(L)

    print(block)
    with open(os.path.join(LOGDIR, "pnl_%s.log" % now.strftime("%Y-%m")), "a") as fh:
        fh.write(block + "\n\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        warn(str(e))
        sys.exit(0)   # never break the caller
