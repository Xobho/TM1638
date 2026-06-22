"""Append-only JSONL trade journal.

Every AI decision and every trade outcome (real or dry-run) gets one line.
Kept separate from bridge.log (which is for debugging) because this is the
data report.py reads to score what's actually working.
"""

from __future__ import annotations

import json
import time
from pathlib import Path


class TradeJournal:
    def __init__(self, path: str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _write(self, record: dict) -> None:
        record["ts"] = time.time()
        with self.path.open("a") as f:
            f.write(json.dumps(record) + "\n")

    def log_signal(self, symbol: str, action: str, confidence: float, reasoning: str) -> None:
        self._write({
            "type": "signal", "symbol": symbol, "action": action,
            "confidence": confidence, "reasoning": reasoning,
        })

    def log_open(self, symbol: str, action: str, entry: float, sl: float, tp: float,
                 lots: float, confidence: float, reasoning: str, dry_run: bool,
                 ticket: int | None = None) -> None:
        self._write({
            "type": "open", "symbol": symbol, "action": action, "entry": entry,
            "sl": sl, "tp": tp, "lots": lots, "confidence": confidence,
            "reasoning": reasoning, "dry_run": dry_run, "ticket": ticket,
        })

    def log_close(self, symbol: str, exit_price: float, result: str,
                  pnl: float | None, dry_run: bool) -> None:
        self._write({
            "type": "close", "symbol": symbol, "exit": exit_price,
            "result": result, "pnl": pnl, "dry_run": dry_run,
        })
