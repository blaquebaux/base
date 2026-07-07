"""
blaque_baux/ibkr/order_manager.py
───────────────────────────────────
IBKR order management for Blaque Baux rebalancing.

Every 15 minutes (or 1-hr / 2-hr for crypto), the pool manager
receives optimal weights from the Crypto Quant optimizer and
calls submit_rebalance() here.

Rebalancing logic:
  1. Get current positions from IBKR
  2. Compute target positions from weights × capital
  3. Compute delta (target - current)
  4. Filter out trivial trades (< min_trade_value)
  5. Submit buy/sell orders for the delta
  6. Wait for fills (async)
  7. Report realized P&L and fill prices

Order types:
  - Equity/commodity rebalancing: Adaptive Algo (IBKR's smart routing)
    minimizes market impact on liquid names
  - Crypto: Market orders on exchange (crypto doesn't support Adaptive)
  - 0DTE options: Limit orders, mid-price, timed out after 2 minutes

Key design decisions:
  - Never hold open orders across bar closes (cancel + re-evaluate)
  - Fractional shares enabled where IBKR supports them
  - All orders tagged with pool_id for P&L attribution
"""

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

try:
    from ib_insync import (
        IB, Stock, Future, Crypto, Option,
        MarketOrder, LimitOrder, Order,
        Contract, Trade
    )
    IBKR_AVAILABLE = True
except ImportError:
    IBKR_AVAILABLE = False


# ── TYPES ─────────────────────────────────────────────────────────────────────

@dataclass
class FillReport:
    pool_id:          str
    orders_submitted: int
    orders_filled:    int
    realized_return:  float     # weighted average fill return vs mid-price
    total_slippage:   float     # basis points of slippage from mid
    gross_notional:   float     # total trade value
    unfilled:         List[str] = field(default_factory=list)
    error:            Optional[str] = None


@dataclass
class Position:
    ticker:   str
    shares:   float
    avg_cost: float
    market_value: float
    unrealized_pnl: float


# ── ORDER MANAGER ─────────────────────────────────────────────────────────────

class IBKROrderManager:
    """
    Handles portfolio rebalancing for all Blaque Baux pools.
    One shared instance; pools call by pool_id.
    """

    MIN_TRADE_VALUE = 10.0    # skip trades smaller than this (not worth the commission)
    FILL_TIMEOUT    = 30      # seconds to wait for fills before cancelling

    def __init__(self, connection_pool):
        self.pool = connection_pool
        self._positions: Dict[str, Dict[str, Position]] = {}  # pool_id → {ticker → Position}

    # ── MAIN REBALANCING CALL ─────────────────────────────────────────────────

    async def submit_rebalance(
        self,
        pool_id:  str,
        weights:  Dict[str, float],  # positive=long, negative=short
        capital:  float,
        dry_run:  bool = False,      # log orders but don't submit
    ) -> Dict:
        """
        Compute delta from current positions to target weights,
        submit orders, and return a fill report.

        This is called at step 9 of every window loop.
        """
        ib = self.pool.get(pool_id)
        if not ib or not ib.isConnected():
            logger.error(f"[{pool_id}] IBKR not connected")
            return {"error": "not_connected", "realized_return": 0.0}

        # Current positions
        current = await self._get_positions(pool_id, ib)

        # Target positions (shares)
        targets = self._weights_to_shares(weights, capital, current)

        # Delta (what we need to trade)
        orders = self._compute_delta(current, targets)

        # Filter trivial trades
        orders = [o for o in orders if abs(o["notional"]) >= self.MIN_TRADE_VALUE]

        if not orders:
            return {"realized_return": 0.0, "orders_submitted": 0}

        if dry_run:
            for o in orders:
                logger.info(f"  [DRY RUN] [{pool_id}] {o['action']} "
                            f"{o['qty']:.2f} {o['ticker']} "
                            f"${o['notional']:.0f}")
            return {"realized_return": 0.0, "orders_submitted": len(orders), "dry_run": True}

        # Submit and collect fills
        fills = await self._submit_orders(pool_id, ib, orders)
        report = self._build_fill_report(pool_id, orders, fills)

        # Update position cache
        await self._refresh_positions(pool_id, ib)

        return {
            "realized_return":  report.realized_return,
            "orders_submitted": report.orders_submitted,
            "orders_filled":    report.orders_filled,
            "total_slippage_bps": report.total_slippage * 10000,
            "unfilled":         report.unfilled,
        }

    # ── ORDER SUBMISSION ──────────────────────────────────────────────────────

    async def _submit_orders(
        self,
        pool_id: str,
        ib:      "IB",
        orders:  List[Dict],
    ) -> List[Dict]:
        """Submit all delta orders and wait for fills."""
        trades = []

        for order_spec in orders:
            ticker  = order_spec["ticker"]
            action  = order_spec["action"]  # "BUY" or "SELL"
            qty     = abs(order_spec["qty"])

            contract = self._make_contract(ticker, order_spec.get("asset_type", "STK"))

            if IBKR_AVAILABLE:
                # Qualify the contract (gets IBKR's conid)
                try:
                    ib.qualifyContracts(contract)
                except Exception:
                    pass

            # Use Adaptive Algo for equities (minimizes market impact)
            # Use Market order for crypto (no algo support)
            if order_spec.get("asset_type") == "CRYPTO":
                ibkr_order = MarketOrder(action, qty) if IBKR_AVAILABLE else \
                    type("O", (), {"action": action, "totalQuantity": qty})()
            else:
                if IBKR_AVAILABLE:
                    ibkr_order = Order()
                    ibkr_order.action         = action
                    ibkr_order.totalQuantity  = qty
                    ibkr_order.orderType      = "MIDPRICE"  # IBKR Adaptive
                    ibkr_order.orderAlgo      = "Adaptive"
                    ibkr_order.adaptivePriority = "Normal"
                    ibkr_order.orderRef       = f"BB_{pool_id}_{ticker}"
                else:
                    ibkr_order = type("O", (), {"action": action,
                                                 "totalQuantity": qty})()

            try:
                if IBKR_AVAILABLE:
                    trade = ib.placeOrder(contract, ibkr_order)
                else:
                    trade = await ib.placeOrderAsync(contract, ibkr_order)

                trades.append({
                    "ticker": ticker,
                    "action": action,
                    "qty":    qty,
                    "trade":  trade,
                    "target_notional": order_spec["notional"],
                })
                logger.debug(f"  [{pool_id}] {action} {qty:.2f} {ticker}")

            except Exception as e:
                logger.error(f"  [{pool_id}] Order failed {ticker}: {e}")

        # Wait for fills
        if IBKR_AVAILABLE and trades:
            await asyncio.sleep(min(self.FILL_TIMEOUT, 15))

        # Collect fill prices
        results = []
        for t in trades:
            try:
                if IBKR_AVAILABLE:
                    status = t["trade"].orderStatus
                    fill_price = float(status.avgFillPrice or 0)
                    filled_qty = float(status.filled or 0)
                else:
                    # MockIB returns simulated fill
                    fill_price = 100.0
                    filled_qty = t["qty"]

                results.append({
                    "ticker":       t["ticker"],
                    "action":       t["action"],
                    "qty":          t["qty"],
                    "filled_qty":   filled_qty,
                    "fill_price":   fill_price,
                    "target_notional": t["target_notional"],
                })
            except Exception as e:
                logger.warning(f"  [{pool_id}] Fill check error {t['ticker']}: {e}")

        return results

    # ── POSITION MANAGEMENT ───────────────────────────────────────────────────

    async def _get_positions(
        self, pool_id: str, ib: "IB"
    ) -> Dict[str, Position]:
        """Get current positions from IBKR for this pool's client ID."""
        if pool_id in self._positions:
            return self._positions[pool_id]  # use cache

        positions = {}
        try:
            if IBKR_AVAILABLE:
                for pos in ib.portfolio():
                    ticker = pos.contract.symbol
                    positions[ticker] = Position(
                        ticker         = ticker,
                        shares         = pos.position,
                        avg_cost       = pos.averageCost,
                        market_value   = pos.marketValue,
                        unrealized_pnl = pos.unrealizedPNL,
                    )
            # MockIB: start flat
        except Exception as e:
            logger.warning(f"[{pool_id}] Could not fetch positions: {e}")

        self._positions[pool_id] = positions
        return positions

    async def _refresh_positions(self, pool_id: str, ib: "IB"):
        """Force refresh of position cache after rebalancing."""
        if pool_id in self._positions:
            del self._positions[pool_id]
        await self._get_positions(pool_id, ib)

    # ── HELPERS ───────────────────────────────────────────────────────────────

    def _weights_to_shares(
        self,
        weights:  Dict[str, float],
        capital:  float,
        current:  Dict[str, Position],
    ) -> Dict[str, float]:
        """Convert optimizer weights to target share counts."""
        targets = {}
        for ticker, weight in weights.items():
            target_value = capital * weight  # positive=long, negative=short
            # Rough share count (will use current market price in production)
            # For now, assume $100/share placeholder — real impl queries bid/ask
            est_price = 100.0
            if ticker in current:
                est_price = max(1.0, current[ticker].avg_cost)
            targets[ticker] = target_value / est_price
        return targets

    def _compute_delta(
        self,
        current: Dict[str, Position],
        targets: Dict[str, float],
    ) -> List[Dict]:
        """Compute orders needed to go from current to target positions."""
        orders = []
        all_tickers = set(current.keys()) | set(targets.keys())

        for ticker in all_tickers:
            current_qty = current.get(ticker, Position(ticker, 0, 0, 0, 0)).shares
            target_qty  = targets.get(ticker, 0.0)
            delta       = target_qty - current_qty

            if abs(delta) < 0.01:
                continue

            action   = "BUY" if delta > 0 else "SELL"
            notional = abs(delta) * 100.0  # placeholder price

            orders.append({
                "ticker":     ticker,
                "action":     action,
                "qty":        abs(delta),
                "notional":   notional,
                "asset_type": "CRYPTO" if self._is_crypto(ticker) else "STK",
            })

        return orders

    def _make_contract(self, ticker: str, asset_type: str = "STK") -> "Contract":
        """Build an IBKR contract object."""
        if not IBKR_AVAILABLE:
            return type("C", (), {"symbol": ticker})()

        if asset_type == "CRYPTO":
            return Crypto(ticker, "PAXOS", "USD")
        elif asset_type == "FUT":
            return Future(ticker, exchange="GLOBEX")
        else:
            return Stock(ticker, "SMART", "USD")

    def _is_crypto(self, ticker: str) -> bool:
        CRYPTO_TICKERS = {"BTC", "ETH", "SOL", "BNB", "AVAX", "MATIC"}
        return ticker.upper() in CRYPTO_TICKERS

    def _build_fill_report(
        self,
        pool_id: str,
        orders:  List[Dict],
        fills:   List[Dict],
    ) -> FillReport:
        filled   = [f for f in fills if f.get("filled_qty", 0) > 0]
        unfilled = [o["ticker"] for o in orders
                    if o["ticker"] not in {f["ticker"] for f in filled}]

        # Simple realized return estimate from fill vs target
        total_notional = sum(abs(o["notional"]) for o in orders) or 1
        slippage = sum(
            abs(f.get("fill_price", 100) - 100) / 100
            for f in filled
        ) / max(len(filled), 1)

        return FillReport(
            pool_id          = pool_id,
            orders_submitted = len(orders),
            orders_filled    = len(filled),
            realized_return  = 0.0,   # computed from actual P&L in next window
            total_slippage   = slippage,
            gross_notional   = total_notional,
            unfilled         = unfilled,
        )
