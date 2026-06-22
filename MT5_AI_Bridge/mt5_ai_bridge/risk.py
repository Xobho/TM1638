"""Guardrails that sit between an AI decision and a real order.

The AI analyst can recommend a trade; nothing reaches the broker unless it
passes every check here. This is the only place trade approval logic lives,
so all limits stay in one auditable spot.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field


@dataclass
class RiskLimits:
    dry_run: bool = True
    max_risk_percent_per_trade: float = 1.0
    max_open_positions: int = 3
    max_daily_trades: int = 6
    max_spread_points: float = 30.0
    min_confidence: float = 0.65
    fallback_rr: float = 2.0


@dataclass
class RiskState:
    trades_today: int = 0
    day: dt.date = field(default_factory=dt.date.today)

    def register_trade(self) -> None:
        today = dt.date.today()
        if today != self.day:
            self.day = today
            self.trades_today = 0
        self.trades_today += 1


class RiskManager:
    def __init__(self, limits: RiskLimits):
        self.limits = limits
        self.state = RiskState()

    def reset_if_new_day(self) -> None:
        today = dt.date.today()
        if today != self.state.day:
            self.state.day = today
            self.state.trades_today = 0

    def can_open_new_trade(self, confidence: float, open_position_count: int,
                            spread_points: float) -> tuple[bool, str]:
        self.reset_if_new_day()
        if confidence < self.limits.min_confidence:
            return False, f"confidence {confidence:.2f} below min {self.limits.min_confidence:.2f}"
        if open_position_count >= self.limits.max_open_positions:
            return False, f"max_open_positions ({self.limits.max_open_positions}) reached"
        if self.state.trades_today >= self.limits.max_daily_trades:
            return False, f"max_daily_trades ({self.limits.max_daily_trades}) reached"
        if spread_points > self.limits.max_spread_points:
            return False, f"spread {spread_points:.1f} > max {self.limits.max_spread_points}"
        return True, "ok"
