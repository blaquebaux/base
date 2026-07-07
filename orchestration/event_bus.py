"""
blaque_baux/orchestration/event_bus.py
───────────────────────────────────────
Python bridge to the @smallclaw/coordination SQLite WAL bus.

The existing TypeScript coordination layer (M4 Mini, Hono HTTP API)
is the canonical coordination bus for the fleet. This module gives
the Python trading layer two integration paths:

  Path A (preferred): HTTP API calls to the Hono server on M4 Mini.
      All pool status, circuit breaker state, and inter-pool messages
      route through the existing @smallclaw/coordination schema.

  Path B (local fallback): Direct SQLite writes when network is
      unavailable. Uses the same schema as the coordination bus
      so data is consistent when the bus reconnects.

Schema mirrors @smallclaw/coordination exactly:
    agents      — pool registry (each pool is an "agent")
    messages    — inter-pool messages, circuit breaker alerts
    tasks       — active trading windows (task per window)
    memories    — trade log, P&L history, accuracy records
    rules       — circuit breaker rules with trust scores
"""

import asyncio
import json
import logging
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import aiohttp

logger = logging.getLogger(__name__)

# ── CONFIGURATION ─────────────────────────────────────────────────────────────

COORDINATION_BUS_URL = "http://m4mini.local:7700"   # @smallclaw/coordination Hono server
LOCAL_DB_PATH        = Path("./data/blaque_baux_bus.db")
HEARTBEAT_INTERVAL   = 30  # seconds


# ── DATA TYPES (mirrors @smallclaw/coordination schema) ───────────────────────

@dataclass
class AgentRecord:
    agent_id:        str
    machine_id:      str
    capability_tier: float
    status:          str          # 'idle' | 'working' | 'offline'
    current_task:    Optional[str]
    judgment_policy: Dict[str, Any]


@dataclass
class Message:
    id:         str
    from_agent: str
    to_agent:   Optional[str]     # None = broadcast
    msg_type:   str               # 'pool_status' | 'circuit_alert' | 'optimizer_request' | 'window_result'
    payload:    Dict[str, Any]
    status:     str = "pending"


@dataclass
class Memory:
    id:           str
    content:      str
    tags:         List[str]
    source_agent: str


# ── LOCAL SQLITE SCHEMA ───────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
    agent_id        TEXT PRIMARY KEY,
    machine_id      TEXT NOT NULL,
    capability_tier REAL,
    status          TEXT DEFAULT 'idle',
    current_task    TEXT,
    last_heartbeat  TEXT,
    judgment_policy TEXT
);

CREATE TABLE IF NOT EXISTS messages (
    id           TEXT PRIMARY KEY,
    from_agent   TEXT NOT NULL,
    to_agent     TEXT,
    msg_type     TEXT NOT NULL,
    payload      TEXT NOT NULL,
    status       TEXT DEFAULT 'pending',
    created_at   TEXT DEFAULT (datetime('now')),
    delivered_at TEXT
);

CREATE TABLE IF NOT EXISTS memories (
    id           TEXT PRIMARY KEY,
    content      TEXT NOT NULL,
    tags         TEXT,
    source_agent TEXT,
    created_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS rules (
    id            TEXT PRIMARY KEY,
    content       TEXT NOT NULL,
    trust_score   REAL DEFAULT 0.5,
    usage_count   INTEGER DEFAULT 0,
    success_count INTEGER DEFAULT 0,
    failure_count INTEGER DEFAULT 0,
    created_by    TEXT,
    created_at    TEXT DEFAULT (datetime('now')),
    last_applied  TEXT
);

CREATE TABLE IF NOT EXISTS window_log (
    id               TEXT PRIMARY KEY,
    pool_id          TEXT NOT NULL,
    timestamp        TEXT NOT NULL,
    factor_accuracy  REAL,
    portfolio_return REAL,
    qp_status        TEXT,
    cascade_strength REAL,
    n_long           INTEGER,
    n_short          INTEGER,
    circuit_state    TEXT DEFAULT 'normal'
);

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
"""


# ── LOCAL BUS (always available) ──────────────────────────────────────────────

class LocalBus:
    """
    Direct SQLite WAL bus — same schema as @smallclaw/coordination.
    Used as fallback when M4 Mini coordination server is unreachable,
    and as the local write-ahead log that syncs to the coordination bus.
    """

    def __init__(self, db_path: Path = LOCAL_DB_PATH):
        LOCAL_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        self._init_schema()

    def _init_schema(self):
        with self._conn() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def register_agent(self, agent: AgentRecord):
        with self._conn() as conn:
            conn.execute("""
                INSERT OR REPLACE INTO agents
                    (agent_id, machine_id, capability_tier, status,
                     current_task, last_heartbeat, judgment_policy)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (
                agent.agent_id, agent.machine_id, agent.capability_tier,
                agent.status, agent.current_task,
                datetime.now(timezone.utc).isoformat(),
                json.dumps(agent.judgment_policy),
            ))

    def heartbeat(self, agent_id: str, status: str, current_task: Optional[str] = None):
        with self._conn() as conn:
            conn.execute("""
                UPDATE agents
                SET status = ?, current_task = ?,
                    last_heartbeat = datetime('now')
                WHERE agent_id = ?
            """, (status, current_task, agent_id))

    def publish(self, msg: Message):
        with self._conn() as conn:
            conn.execute("""
                INSERT INTO messages (id, from_agent, to_agent, msg_type, payload)
                VALUES (?, ?, ?, ?, ?)
            """, (
                msg.id, msg.from_agent, msg.to_agent,
                msg.msg_type, json.dumps(msg.payload)
            ))

    def claim_message(self, agent_id: str) -> Optional[Dict]:
        with self._conn() as conn:
            row = conn.execute("""
                UPDATE messages
                SET status = 'delivered', delivered_at = datetime('now')
                WHERE id = (
                    SELECT id FROM messages
                    WHERE (to_agent = ? OR to_agent IS NULL)
                      AND status = 'pending'
                    ORDER BY created_at
                    LIMIT 1
                )
                RETURNING *
            """, (agent_id,)).fetchone()
            if row:
                d = dict(row)
                d["payload"] = json.loads(d["payload"])
                return d
        return None

    def write_memory(self, memory: Memory):
        with self._conn() as conn:
            conn.execute("""
                INSERT INTO memories (id, content, tags, source_agent)
                VALUES (?, ?, ?, ?)
            """, (
                memory.id, memory.content,
                json.dumps(memory.tags), memory.source_agent,
            ))

    def log_window(self, pool_id: str, **kwargs):
        with self._conn() as conn:
            conn.execute("""
                INSERT INTO window_log
                    (id, pool_id, timestamp, factor_accuracy,
                     portfolio_return, qp_status, cascade_strength,
                     n_long, n_short, circuit_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                str(uuid.uuid4()), pool_id,
                datetime.now(timezone.utc).isoformat(),
                kwargs.get("factor_accuracy"),
                kwargs.get("portfolio_return"),
                kwargs.get("qp_status"),
                kwargs.get("cascade_strength"),
                kwargs.get("n_long"),
                kwargs.get("n_short"),
                kwargs.get("circuit_state", "normal"),
            ))

    def get_circuit_rules(self, min_trust: float = 0.5) -> List[Dict]:
        with self._conn() as conn:
            rows = conn.execute("""
                SELECT * FROM rules
                WHERE trust_score >= ?
                ORDER BY trust_score DESC
            """, (min_trust,)).fetchall()
            return [dict(r) for r in rows]

    def update_rule_outcome(self, rule_id: str, success: bool):
        """Bayesian Beta-Binomial trust score update — same as @smallclaw/coordination."""
        with self._conn() as conn:
            field = "success_count" if success else "failure_count"
            conn.execute(f"""
                UPDATE rules
                SET usage_count = usage_count + 1,
                    {field} = {field} + 1,
                    trust_score = CAST(success_count + 1 AS REAL)
                              / (usage_count + 2),
                    last_applied = datetime('now')
                WHERE id = ?
            """, (rule_id,))


# ── NETWORK BUS (coordination server on M4 Mini) ──────────────────────────────

class NetworkBus:
    """
    HTTP client for the @smallclaw/coordination Hono server on M4 Mini.
    All pool status, alerts, and inter-pool messages route here first.
    Falls back to LocalBus if the server is unreachable.
    """

    def __init__(
        self,
        url: str = COORDINATION_BUS_URL,
        local_fallback: Optional[LocalBus] = None,
        timeout: float = 3.0,
    ):
        self.url      = url.rstrip("/")
        self.local    = local_fallback or LocalBus()
        self.timeout  = aiohttp.ClientTimeout(total=timeout)
        self._online  = False

    async def check_health(self) -> bool:
        try:
            async with aiohttp.ClientSession(timeout=self.timeout) as session:
                async with session.get(f"{self.url}/health") as r:
                    self._online = r.status == 200
        except Exception:
            self._online = False
        return self._online

    async def register_agent(self, agent: AgentRecord):
        if not await self.check_health():
            self.local.register_agent(agent)
            return
        try:
            async with aiohttp.ClientSession(timeout=self.timeout) as s:
                await s.post(f"{self.url}/agents", json=asdict(agent))
        except Exception as e:
            logger.warning(f"Coordination bus unreachable, writing locally: {e}")
            self.local.register_agent(agent)

    async def publish(self, msg: Message):
        if not self._online:
            self.local.publish(msg)
            return
        try:
            async with aiohttp.ClientSession(timeout=self.timeout) as s:
                await s.post(f"{self.url}/messages", json=asdict(msg))
        except Exception:
            self.local.publish(msg)

    async def heartbeat(self, agent_id: str, status: str, task: Optional[str] = None):
        self.local.heartbeat(agent_id, status, task)
        if self._online:
            try:
                async with aiohttp.ClientSession(timeout=self.timeout) as s:
                    await s.patch(f"{self.url}/agents/{agent_id}",
                                  json={"status": status, "current_task": task})
            except Exception:
                pass  # local write is sufficient

    def log_window(self, pool_id: str, **kwargs):
        """Always write locally — window log is high-frequency, no network needed."""
        self.local.log_window(pool_id, **kwargs)

    def write_memory(self, memory: Memory):
        self.local.write_memory(memory)
        # TODO Phase 4: async sync to coordination bus


# ── FACTORY ───────────────────────────────────────────────────────────────────

def make_bus(use_network: bool = True) -> NetworkBus:
    local = LocalBus()
    return NetworkBus(local_fallback=local) if use_network else NetworkBus(
        url="http://localhost:9999",  # unreachable — forces local mode
        local_fallback=local,
    )
