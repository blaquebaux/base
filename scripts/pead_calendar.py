#!/usr/bin/python3
# pead_calendar.py — the earnings-calendar PIPELINE for the PEAD tactical sleeve. Fetches each name's earnings
# dates + actual surprise% (yfinance) and caches them to a JSON the Julia driver/validation read. This is the
# one piece the momentum-gated sleeves didn't need: PEAD is event-driven, so it needs to know WHO reported WHEN
# and by HOW MUCH. Run periodically (e.g. weekly) to refresh; the driver just reads the cache.
#   Output: scripts/pead_earnings_calendar.json  {ticker: [{"d": "YYYY-MM-DD", "surprise": pct, "amc": bool}, ...]}
#   Run:  python scripts/pead_calendar.py            (~2-4 min, rate-limited yfinance; no Alpaca keys needed)
import os, json, warnings, datetime as dt
warnings.filterwarnings("ignore")
import yfinance as yf

U = ["AAPL","MSFT","NVDA","AMZN","GOOGL","META","AVGO","TSLA","JPM","V","MA","UNH","HD","PG","XOM","JNJ",
     "COST","WMT","BAC","KO","PEP","CVX","MRK","CRM","ADBE","NFLX","AMD","INTC","QCOM","TXN","ORCL","DIS",
     "GS","MS","CAT","HON","LLY","ABBV","TMO","NKE"]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pead_earnings_calendar.json")

cal = {}; nfail = 0; nev = 0
for s in U:
    try:
        ed = yf.Ticker(s).get_earnings_dates(limit=60).dropna(subset=["Surprise(%)"])
    except Exception:
        nfail += 1; continue
    rows = []
    for ts, row in ed.iterrows():
        try:
            rows.append({"d": ts.date().isoformat(), "surprise": float(row["Surprise(%)"]), "amc": bool(ts.hour >= 16)})
        except Exception:
            continue
    rows.sort(key=lambda r: r["d"])
    if rows:
        cal[s] = rows; nev += len(rows)

payload = {"_generated": dt.datetime.utcnow().isoformat() + "Z", "_universe": U, "_events": nev, "calendar": cal}
with open(OUT, "w") as f:
    json.dump(payload, f, indent=0, sort_keys=True)
print(f"wrote {OUT}: {len(cal)} names, {nev} events ({nfail} fetch failures)")
