#!/usr/bin/python3
# =============================================================================
# family_summary.py — READ-ONLY cross-family A/B check-in for every Blaque Baux leg.
#
# Engine-level ops monitoring: snapshots each paper account (spine family + the
# flavor sleeves that live in their own repos), reads each leg's job log for a
# status flag, and writes a side-by-side summary (each active leg vs the SINGLE
# control) to logs/family_summary_<date>.txt (and stdout).
#
# Account keys are read from the CENTRALIZED ~/.config/blaquebaux/*.env files, so
# this needs no knowledge of the flavor repos beyond where each writes its job log
# (deployment config below). A leg is skipped cleanly until its key file exists.
# Never trades, never prints keys, exits 0 on any error.
#
#   /usr/bin/python3 scripts/family_summary.py
# =============================================================================
import os, sys, json, urllib.request
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
    ET = ZoneInfo("America/New_York")
except Exception:
    ET = None

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(REPO, "logs"); os.makedirs(LOGDIR, exist_ok=True)
CFG = os.path.expanduser("~/.config/blaquebaux")
HOME = os.path.expanduser("~")
BASE = "https://paper-api.alpaca.markets/v2"

# label, env file, job-log dir, job-log prefix. Log dir is best-effort (job status
# only); the account snapshot needs just the env file. Flavor legs log in their own repos.
LEGS = [
    ("SINGLE (sign)",          "alpaca.env",       os.path.join(REPO, "logs"),                  "spine"),
    ("SPLIT (universe)",       "alpaca_split.env", os.path.join(REPO, "logs"),                  "spine_split"),
    ("MULTI (single+multi)",   "alpaca_multi.env", os.path.join(REPO, "logs"),                  "spine_multi"),
    ("BLUNT (crude->refiner)", "alpaca_blunt.env", os.path.join(HOME, "blaquebaux-blunt/logs"), "blunt"),
    ("BOOM (megacap mom)",     "alpaca_boom.env",  os.path.join(HOME, "blaquebaux-boom/logs"),  "boom"),
]


def read_keys(path):
    if not os.path.exists(path):
        return None
    kv = {}
    for line in open(path):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip().strip('"').strip("'")
    kid, sec = kv.get("ALPACA_KEY_ID"), kv.get("ALPACA_SECRET_KEY")
    return (kid, sec) if kid and sec else None


def get(path, keys):
    req = urllib.request.Request(BASE + path,
        headers={"APCA-API-KEY-ID": keys[0], "APCA-API-SECRET-KEY": keys[1]})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def job_status(log_dir, prefix, datestr):
    log = os.path.join(log_dir, "%s_%s.log" % (prefix, datestr))
    if not os.path.exists(log):
        return "no log (job not run?)"
    txt = open(log, errors="ignore").read()
    if "SAFETY ABORT" in txt:
        return "!! SAFETY HALT"
    if "RECONCILE FAILED" in txt or "reconcile mismatch" in txt:
        return "!! RECONCILE FAILED"
    if "reconciled=true" in txt:
        return "OK"
    if "not activated" in txt:
        return "not activated (no keys)"
    if "not a trading day" in txt:
        return "skipped (non-trading day)"
    return "ran (see log)"


def snapshot(label, env, log_dir, prefix, datestr):
    keys = read_keys(os.path.join(CFG, env))
    if keys is None:
        return {"label": label, "note": "no keys (%s) — not active" % env}
    try:
        a = get("/account", keys); ps = get("/positions", keys)
    except Exception as e:
        return {"label": label, "note": "query error: %s" % e}
    eq, le = f(a["equity"]), f(a["last_equity"])
    gross = abs(f(a["long_market_value"])) + abs(f(a["short_market_value"]))
    rows = sorted(({"s": p["symbol"], "mv": f(p["market_value"]),
                    "pl": f(p["unrealized_intraday_pl"])} for p in ps),
                  key=lambda r: abs(r["mv"]), reverse=True)
    return {
        "label": label, "acct": a["account_number"], "eq": eq, "le": le,
        "pl": eq - le, "pct": (eq - le) / le * 100 if le else 0.0,
        "gross_x": gross / eq if eq else 0.0, "npos": len(ps),
        "top": rows[:6], "status": job_status(log_dir, prefix, datestr),
    }


def main():
    now = datetime.now(ET) if ET else datetime.now()
    datestr = now.strftime("%Y%m%d")
    snaps = [snapshot(l, e, d, p, datestr) for (l, e, d, p) in LEGS]

    L = []
    L.append("=" * 68)
    L.append(" Blaque Baux — cross-family A/B check-in   %s" % now.strftime("%a %Y-%m-%d %H:%M %Z"))
    L.append("=" * 68)
    for s in snaps:
        L.append("")
        L.append("  %s" % s["label"])
        if "note" in s:
            L.append("    %s" % s["note"]); continue
        L.append("    account        %s" % s["acct"])
        L.append("    equity         ${:,.2f}".format(s["eq"]))
        L.append("    day P&L        ${:,.2f}  ({:+.2f}%)".format(s["pl"], s["pct"]))
        L.append("    gross exposure {:.2f}x".format(s["gross_x"]))
        L.append("    positions      {}".format(s["npos"]))
        L.append("    job status     {}".format(s["status"]))
        if s["top"]:
            tops = "  ".join("{}:{:+,.0f}".format(r["s"], r["pl"]) for r in s["top"])
            L.append("    top P&L        %s" % tops)

    nums = [s for s in snaps if "pct" in s]
    if len(nums) >= 2:
        base = next((s for s in nums if s["label"].startswith("SINGLE")), nums[0])
        L.append("")
        L.append("  " + "-" * 64)
        L.append("  head-to-head vs %s (today):" % base["label"])
        for s in nums:
            if s is base:
                continue
            L.append("    {:<24} {:+.2f}%".format(s["label"], s["pct"] - base["pct"]))
    L.append("")

    block = "\n".join(L)
    print(block)
    out = os.path.join(LOGDIR, "family_summary_%s.txt" % datestr)
    with open(out, "w") as fh:
        fh.write(block + "\n")
    print("written: %s" % out)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("family_summary: WARN %s" % e); sys.exit(0)
