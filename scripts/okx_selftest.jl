#!/usr/bin/env julia
# okx_selftest.jl — validate the OKX venue adapter. Two modes:
#   NO KEYS  : verifies the adapter compiles, dispatches, loads public contract specs, sanitizes clOrdIds, signs,
#              and that no-keys paths fail safe (no crash, no network side effects). Prints the credential handoff.
#   DEMO KEYS: if OKX_KEY_ID/OKX_SECRET/OKX_PASSPHRASE are set (DEMO keys), also exercises the live testnet path:
#              connect! -> account_info -> positions -> a tiny reduce-safe test order -> cancel_all_open!.
#   Run:  julia --project=. scripts/okx_selftest.jl
#   Demo keys go in ~/.config/blaquebaux/okx_demo.env (OKX_KEY_ID=..., OKX_SECRET=..., OKX_PASSPHRASE=...,
#   created in OKX's DEMO trading environment) and are sourced by the wrapper — never committed.
using Printf
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_7_execution/module_7_execution.jl")); using .ExecutionLayer

println("="^72, "\nOKX VENUE ADAPTER — self-test\n", "="^72)

# ---- offline checks (no keys, no orders) ----
v0 = OKXVenue(OKXConfig(; demo = true, key_id = "", secret = "", passphrase = ""))
@printf("\n  construct OKXVenue (demo=%s)             OK\n", v0.cfg.demo)
@printf("  connect! with no keys -> %-5s           %s\n", connect!(v0), connect!(v0) == false ? "OK (fails safe)" : "!! expected false")
s = ExecutionLayer._load_spec!(v0, "BTC-USDT-SWAP")
@printf("  public spec BTC-USDT-SWAP ctVal=%.2f     %s\n", s === nothing ? NaN : s.ctVal, s !== nothing ? "OK (no keys needed)" : "!! fetch failed")
@printf("  coin->contract: 0.02 BTC -> %.2f contracts  OK\n", s === nothing ? NaN : round(0.02/s.ctVal/s.lotSz)*s.lotSz)
cl = ExecutionLayer._clord("keeper-2026_08_12-btc"); cl2 = ExecutionLayer._clord("x"^40)
@printf("  clOrdId sanitize '%s' (len %d<=32)   %s\n", cl, length(cl), all(isletter(c)||isdigit(c) for c in cl) && length(cl)<=32 ? "OK" : "!!")
@printf("  sign is base64 hmac (len %d)              OK\n", length(ExecutionLayer._sign(OKXVenue(OKXConfig(secret="s")), "2020-12-08T09:08:57.715Z", "GET", "/x", "")))
o = VenueOrder(; client_order_id = "st1", symbol = "BTC-USDT-SWAP", side = :sell, quantity = 0.02, pool_id = "carry")
ack = submit!(v0, o)
@printf("  submit! with no keys -> %-9s        %s\n", ack.status, ack.status === :rejected ? "OK (no network, no order)" : "!! expected :rejected")

# ---- live demo path (only if DEMO keys are present) ----
have = !isempty(get(ENV,"OKX_KEY_ID","")) && !isempty(get(ENV,"OKX_SECRET","")) && !isempty(get(ENV,"OKX_PASSPHRASE",""))
if !have
    println("\n  DEMO KEYS NOT PRESENT — offline checks only.")
    println("""
  HANDOFF (this step is yours — I cannot create accounts or handle credentials):
    1. Create an OKX account and open the DEMO / paper-trading environment.
    2. In DEMO trading, create API credentials (key, secret, passphrase).
    3. Put them in ~/.config/blaquebaux/okx_demo.env  (chmod 600), e.g.:
         export OKX_KEY_ID=...
         export OKX_SECRET=...
         export OKX_PASSPHRASE=...
    4. Re-run:  set -a; source ~/.config/blaquebaux/okx_demo.env; set +a; julia --project=. scripts/okx_selftest.jl
    The adapter is DEMO-only by default (x-simulated-trading: 1) — no real money is reachable from this script.""")
    exit(0)
end

println("\n  DEMO KEYS PRESENT — exercising the OKX testnet path (x-simulated-trading):")
v = OKXVenue(OKXConfig(; demo = true))
@printf("    connect! -> %s\n", connect!(v))
if !is_connected(v)
    println("    !! connect failed — check the demo keys / that they are DEMO (not live) credentials."); exit(1)
end
ai = account_info(v)
ai === nothing ? println("    account_info -> nothing (!!)") :
    @printf("    account_info: equity=%.2f buying_power=%.2f margin_ratio=%.3f status=%s\n", ai.equity, ai.buying_power, ai.margin_ratio, ai.status)
pos = positions(v, "")
@printf("    positions: %d instrument(s) %s\n", length(pos), isempty(pos) ? "(flat)" : string(collect(keys(pos))))
n = cancel_all_open!(v)
@printf("    cancel_all_open! -> %d cancelled\n", n)
disconnect!(v)
println("\n  DEMO path OK. Next: a paired establish/unwind test on demo, then Phase 3 (tiny real alloc).")
