"""Shared trade-journal parsing used by both report.py and the live performance lookup."""

from __future__ import annotations

import json
from pathlib import Path


def candles_to_dicts(rates, limit: int = 200) -> list[dict]:
    out = []
    for r in rates[-limit:]:
        out.append({
            "time": int(r["time"]),
            "open": float(r["open"]),
            "high": float(r["high"]),
            "low": float(r["low"]),
            "close": float(r["close"]),
            "volume": int(r["tick_volume"]),
        })
    return out


def load_events(path: str) -> list[dict]:
    p = Path(path)
    events = []
    if not p.exists():
        return events
    with p.open() as f:
        for line in f:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def build_trades(events: list[dict]) -> list[dict]:
    """Pairs each open with the next close for the same symbol (one trade at a time per symbol)."""
    open_by_symbol: dict[str, dict] = {}
    trades = []
    for e in events:
        if e["type"] == "open":
            open_by_symbol[e["symbol"]] = e
        elif e["type"] == "close":
            o = open_by_symbol.pop(e["symbol"], None)
            if o is None:
                continue
            risk = abs(o["entry"] - o["sl"])
            signed_move = (e["exit"] - o["entry"]) if o["action"] == "buy" else (o["entry"] - e["exit"])
            r_multiple = signed_move / risk if risk > 0 else 0.0
            trades.append({**o, "exit": e["exit"], "result": e["result"],
                           "pnl": e["pnl"], "r_multiple": r_multiple})
    return trades
