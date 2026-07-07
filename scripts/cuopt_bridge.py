#!/usr/bin/env python3
"""
cuOpt Smart Order Routing Bridge
Gap 5 — receives routing requests from Julia SOR module via HTTP,
solves the venue allocation LP using NVIDIA cuOpt, returns allocations.

Run on Alienware or DGX (CUDA required):
    python scripts/cuopt_bridge.py --port 8765

Julia calls: POST http://127.0.0.1:8765/route
Request:  {"total_qty": 500, "venues": [{"id":"ARCA","depth":1000,"spread":0.02,"fee":0.003},...]}
Response: {"allocations": {"ARCA": 0.6, "NASDAQ": 0.4}, "solve_time_ms": 2.3}

Falls back to scipy.optimize.linprog (CPU) if cuOpt is not available.
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import cuopt
    CUOPT_AVAILABLE = True
except ImportError:
    CUOPT_AVAILABLE = False

try:
    from scipy.optimize import linprog
    import numpy as np
    SCIPY_AVAILABLE = True
except ImportError:
    SCIPY_AVAILABLE = False


# ── Solver ─────────────────────────────────────────────────────────────────────

def solve_cuopt(total_qty: int, venues: list) -> dict:
    """
    Solve the minimum-cost venue allocation using NVIDIA cuOpt.

    Formulation:
      Variables: x_v = shares allocated to venue v
      Minimize:  Σ_v (spread_v/2 + fee_v) * x_v / total_qty
      Subject to:
        Σ_v x_v = total_qty
        0 ≤ x_v ≤ depth_v  ∀v

    cuOpt models this as a capacitated assignment problem.
    """
    n = len(venues)
    if n == 0:
        return {}

    # Cost per unit at each venue: half-spread + fee (normalized)
    costs = [(v["spread"] / 2 + abs(v["fee"])) for v in venues]

    # cuOpt LP setup — cuOpt uses a data model approach
    data = cuopt.DataModel()

    # Decision variables: allocations x_v ∈ [0, depth_v]
    data.add_cost_matrix([[c] for c in costs])
    data.set_min_vehicles(1)

    # Capacity constraint: Σ x_v = total_qty
    data.set_vehicle_capacities([total_qty])
    demands = [min(v["depth"], total_qty) for v in venues]
    data.set_task_demand_matrix([[d] for d in demands])

    solver = cuopt.Solver(data)
    solver.set_number_of_climbers(32)
    sol = solver.solve()

    routes = sol.get_route()
    allocations = {}
    for i, venue in enumerate(venues):
        alloc = demands[i] if i in routes else 0
        if alloc > 0:
            allocations[venue["id"]] = alloc / total_qty

    return _normalize(allocations)


def solve_linprog(total_qty: int, venues: list) -> dict:
    """
    CPU fallback: scipy linprog (LP relaxation).
    Identical formulation to cuOpt but solved on CPU.
    """
    if not SCIPY_AVAILABLE or not venues:
        return _greedy(total_qty, venues)

    n = len(venues)
    # Objective: minimize cost
    c = [(v["spread"] / 2 + abs(v["fee"])) for v in venues]

    # Equality: Σ x_v = total_qty
    A_eq = [[1.0] * n]
    b_eq = [float(total_qty)]

    # Bounds: 0 ≤ x_v ≤ depth_v
    bounds = [(0, min(v["depth"], total_qty)) for v in venues]

    res = linprog(c, A_eq=A_eq, b_eq=b_eq, bounds=bounds, method="highs")
    if not res.success:
        return _greedy(total_qty, venues)

    allocations = {}
    for i, venue in enumerate(venues):
        frac = res.x[i] / total_qty
        if frac > 1e-4:
            allocations[venue["id"]] = frac

    return _normalize(allocations)


def _greedy(total_qty: int, venues: list) -> dict:
    """Last-resort: fill cheapest venue first."""
    sorted_v = sorted(venues, key=lambda v: v["spread"] / 2 + abs(v["fee"]))
    remaining = total_qty
    allocations = {}
    for v in sorted_v:
        if remaining <= 0:
            break
        alloc = min(remaining, v["depth"])
        if alloc > 0:
            allocations[v["id"]] = alloc / total_qty
            remaining -= alloc
    return _normalize(allocations)


def _normalize(alloc: dict) -> dict:
    total = sum(alloc.values())
    if total <= 0:
        return alloc
    return {k: v / total for k, v in alloc.items()}


def route(total_qty: int, venues: list) -> dict:
    t0 = time.perf_counter()

    # Filter stale / zero-depth venues
    valid = [v for v in venues if v.get("depth", 0) > 0]
    if not valid:
        return {"allocations": {}, "solve_time_ms": 0, "method": "no_venues"}

    if CUOPT_AVAILABLE:
        try:
            alloc = solve_cuopt(total_qty, valid)
            method = "cuopt_gpu"
        except Exception as e:
            print(f"cuOpt solve failed: {e} — falling back to linprog")
            alloc = solve_linprog(total_qty, valid)
            method = "linprog_cpu"
    else:
        alloc = solve_linprog(total_qty, valid)
        method = "linprog_cpu" if SCIPY_AVAILABLE else "greedy"

    elapsed_ms = (time.perf_counter() - t0) * 1000
    return {"allocations": alloc, "solve_time_ms": round(elapsed_ms, 3), "method": method}


# ── HTTP server ────────────────────────────────────────────────────────────────

class RouteHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log; Julia SOR logs its own

    def do_POST(self):
        if self.path != "/route":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            result = route(body["total_qty"], body["venues"])
            payload = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(payload))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as e:
            self.send_error(500, str(e))

    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({
                "status": "ok",
                "cuopt": CUOPT_AVAILABLE,
                "scipy": SCIPY_AVAILABLE
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="cuOpt SOR bridge")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    backend = "cuOpt GPU" if CUOPT_AVAILABLE else ("scipy linprog" if SCIPY_AVAILABLE else "greedy")
    print(f"cuOpt SOR bridge starting on {args.host}:{args.port}  [{backend}]")

    server = HTTPServer((args.host, args.port), RouteHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Bridge stopped.")
