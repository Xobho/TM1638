"""Rolling win-rate / avg-R lookups, used to give the AI memory of its own
recent track record — overall and broken down by market regime — before
each new decision."""

from __future__ import annotations

from .analytics import build_trades, load_events


def rolling_stats(journal_path: str, symbol: str, regime_label: str | None = None,
                   lookback: int = 30) -> dict:
    trades = build_trades(load_events(journal_path))
    trades = [t for t in trades if t["symbol"] == symbol]
    if regime_label is not None:
        trades = [t for t in trades if t.get("regime") == regime_label]
    trades = trades[-lookback:]

    if not trades:
        return {"count": 0, "win_rate": None, "avg_r": None}

    wins = sum(1 for t in trades if t["r_multiple"] > 0)
    avg_r = sum(t["r_multiple"] for t in trades) / len(trades)
    return {
        "count": len(trades),
        "win_rate": round(wins / len(trades) * 100, 1),
        "avg_r": round(avg_r, 2),
    }
