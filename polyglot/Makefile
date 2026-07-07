.PHONY: all rust julia test bench clean

# ══════════════════════════════════════════════════════════════════════════════
# Blaque Baux — Polyglot Build
#
# Prerequisites:
#   Rust:   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
#           pip install maturin
#   Julia:  https://julialang.org/downloads/ (1.10+)
#           pip install juliacall
#   Python: pip install -r requirements.txt
# ══════════════════════════════════════════════════════════════════════════════

all: rust julia

# ── Rust signal engine ───────────────────────────────────────────────────────
PYTHON ?= /usr/bin/python3

rust:
	@echo "═══ Building Rust signal engine (PyO3) ═══"
	cd signal_engine_rs && maturin build --release --interpreter $(PYTHON)
	$(PYTHON) -m pip install --user --force-reinstall signal_engine_rs/target/wheels/*.whl
	@echo "✓ signal_engine_rs installed — import with: from signal_engine_rs import HybridEngine"

rust-debug:
	cd signal_engine_rs && maturin build --interpreter $(PYTHON)
	$(PYTHON) -m pip install --user --force-reinstall signal_engine_rs/target/wheels/*.whl
	@echo "✓ signal_engine_rs (debug) installed"

# ── Julia optimizer ──────────────────────────────────────────────────────────
JULIA ?= $(shell command -v julia 2>/dev/null || echo $(HOME)/.juliaup/bin/julia)

julia:
	@echo "═══ Installing Julia dependencies ═══"
	$(JULIA) -e 'using Pkg; Pkg.activate("optimizer_jl"); Pkg.instantiate()'
	@echo "✓ Julia packages installed"

julia-precompile: julia
	@echo "═══ Precompiling Julia modules ═══"
	$(JULIA) -e '\
		using Pkg; Pkg.activate("optimizer_jl"); \
		include("optimizer_jl/qp_solver.jl"); \
		include("optimizer_jl/six_sigma_oracle.jl"); \
		println("✓ Precompile complete")'

# ── Test ─────────────────────────────────────────────────────────────────────
test: rust julia
	@echo "═══ Running integration tests ═══"
	$(PYTHON) -c "\
from integration.signal_engine_bridge import HybridSignalBridge; \
import numpy as np; \
engine = HybridSignalBridge(n_assets=10, tickers=[f'T{i}' for i in range(10)]); \
alpha, unc, mask = engine.update_bar( \
    __import__('pandas').Series(np.random.randn(10)*0.01, index=[f'T{i}' for i in range(10)])); \
print(f'Signal engine [{engine.mode}]: alpha={alpha[:3]}, mask={mask.sum()}/10 active'); \
print(f'Diagnostics: {engine.diagnostics()}')"
	@echo ""
	$(PYTHON) -c "\
from integration.optimizer_bridge import optimize_portfolio; \
import pandas as pd, numpy as np; \
tickers = [f'T{i}' for i in range(20)]; \
scores = pd.Series(np.random.randn(20)*0.02, index=tickers); \
hist = pd.DataFrame(np.random.randn(200,20)*0.01, columns=tickers); \
w, meta = optimize_portfolio(scores, hist, tickers[:10], tickers[10:]); \
engine = meta.get('engine', 'cvxpy'); \
print(f'Optimizer [{engine}]: {len(w)} positions, status={meta[\"status\"]}'); \
print(f'Sharpe est: {meta.get(\"sharpe_est\",0):.3f}, solve: {meta.get(\"solve_ms\",meta.get(\"bridge_ms\",0)):.1f}ms')"
	@echo "═══ All tests passed ═══"

# ── Benchmark ────────────────────────────────────────────────────────────────
bench: rust
	@echo "═══ Signal engine latency benchmark (1000 bars × 50 assets) ═══"
	$(PYTHON) -c "\
import time, numpy as np, pandas as pd; \
from integration.signal_engine_bridge import HybridSignalBridge; \
N=50; tickers=[f'T{i}' for i in range(N)]; \
engine = HybridSignalBridge(n_assets=N, tickers=tickers); \
times=[]; \
for _ in range(1000): \
    rets = pd.Series(np.random.randn(N)*0.01, index=tickers); \
    t0=time.perf_counter(); \
    engine.update_bar(rets); \
    times.append((time.perf_counter()-t0)*1e6); \
arr=np.array(times); \
print(f'Mode: {engine.mode}'); \
print(f'Mean:  {arr.mean():.1f} μs'); \
print(f'P50:   {np.median(arr):.1f} μs'); \
print(f'P95:   {np.percentile(arr,95):.1f} μs'); \
print(f'P99:   {np.percentile(arr,99):.1f} μs'); \
print(f'Max:   {arr.max():.1f} μs'); \
print(f'Budget: 500,000 μs (0.5ms) — headroom: {500000/arr.mean():.0f}×')"

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	cd signal_engine_rs && cargo clean
	rm -rf optimizer_jl/Manifest.toml
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
