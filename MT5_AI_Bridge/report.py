#!/usr/bin/env python3
"""Summarizes logs/trade_journal.jsonl: signal distribution, win rate, R multiples,
and which confidence/symbol buckets are actually working.

Usage:
    python report.py                       # uses logs/trade_journal.jsonl
    python report.py --journal path.jsonl
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path

from mt5_ai_bridge.analytics import build_trades, load_events


def confidence_bucket(c: float) -> str:
    if c >= 0.85:
        return "high (0.85+)"
    if c >= 0.70:
        return "medium (0.70-0.85)"
    return "low (<0.70)"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--journal", default="logs/trade_journal.jsonl")
    args = parser.parse_args()

    events = load_events(Path(args.journal))
    if not events:
        print(f"No journal entries found at {args.journal} yet — let the bridge run for a while first.")
        return

    signals = [e for e in events if e["type"] == "signal"]
    trades = build_trades(events)

    print("=" * 60)
    print("SIGNAL DISTRIBUTION (every decision the AI made)")
    print("=" * 60)
    by_action = defaultdict(int)
    for s in signals:
        by_action[s["action"]] += 1
    for action, count in sorted(by_action.items(), key=lambda kv: -kv[1]):
        print(f"  {action:6s}: {count}")
    print(f"  total signals: {len(signals)}")

    if not trades:
        print("\nNo completed trades yet (no open+close pair in the journal). Let it run longer.")
        return

    print()
    print("=" * 60)
    print(f"COMPLETED TRADES: {len(trades)}")
    print("=" * 60)
    wins = [t for t in trades if t["r_multiple"] > 0]
    losses = [t for t in trades if t["r_multiple"] <= 0]
    win_rate = len(wins) / len(trades) * 100
    avg_r = sum(t["r_multiple"] for t in trades) / len(trades)
    total_r = sum(t["r_multiple"] for t in trades)
    print(f"  win rate:        {win_rate:.1f}%  ({len(wins)} wins / {len(losses)} losses)")
    print(f"  average R:       {avg_r:+.2f}")
    print(f"  total R:         {total_r:+.2f}")
    real_trades = [t for t in trades if not t["dry_run"]]
    if real_trades:
        total_pnl = sum(t["pnl"] or 0 for t in real_trades)
        print(f"  real trades:     {len(real_trades)}  (total P/L: {total_pnl:+.2f})")

    print()
    print("-" * 60)
    print("BY SYMBOL")
    print("-" * 60)
    by_symbol: dict[str, list[dict]] = defaultdict(list)
    for t in trades:
        by_symbol[t["symbol"]].append(t)
    for sym, ts in sorted(by_symbol.items(), key=lambda kv: -sum(t["r_multiple"] for t in kv[1])):
        wr = sum(1 for t in ts if t["r_multiple"] > 0) / len(ts) * 100
        avg = sum(t["r_multiple"] for t in ts) / len(ts)
        print(f"  {sym:10s}: {len(ts)} trades, win rate {wr:.0f}%, avg R {avg:+.2f}")

    print()
    print("-" * 60)
    print("BY CONFIDENCE BUCKET (is the AI's own confidence meaningful?)")
    print("-" * 60)
    by_conf: dict[str, list[dict]] = defaultdict(list)
    for t in trades:
        by_conf[confidence_bucket(t["confidence"])].append(t)
    for bucket in ("high (0.85+)", "medium (0.70-0.85)", "low (<0.70)"):
        ts = by_conf.get(bucket)
        if not ts:
            continue
        wr = sum(1 for t in ts if t["r_multiple"] > 0) / len(ts) * 100
        avg = sum(t["r_multiple"] for t in ts) / len(ts)
        print(f"  {bucket:20s}: {len(ts)} trades, win rate {wr:.0f}%, avg R {avg:+.2f}")

    print()
    print("-" * 60)
    print("BY DIRECTION")
    print("-" * 60)
    by_dir: dict[str, list[dict]] = defaultdict(list)
    for t in trades:
        by_dir[t["action"]].append(t)
    for direction, ts in by_dir.items():
        wr = sum(1 for t in ts if t["r_multiple"] > 0) / len(ts) * 100
        avg = sum(t["r_multiple"] for t in ts) / len(ts)
        print(f"  {direction:6s}: {len(ts)} trades, win rate {wr:.0f}%, avg R {avg:+.2f}")

    print()
    print("-" * 60)
    print("BY MARKET REGIME (which conditions does the AI actually do well in?)")
    print("-" * 60)
    by_regime: dict[str, list[dict]] = defaultdict(list)
    for t in trades:
        by_regime[t.get("regime") or "unknown"].append(t)
    for regime, ts in sorted(by_regime.items(), key=lambda kv: -sum(t["r_multiple"] for t in kv[1])):
        wr = sum(1 for t in ts if t["r_multiple"] > 0) / len(ts) * 100
        avg = sum(t["r_multiple"] for t in ts) / len(ts)
        print(f"  {regime:18s}: {len(ts)} trades, win rate {wr:.0f}%, avg R {avg:+.2f}")

    print()
    print("-" * 60)
    print("RECENT TRADES (last 10)")
    print("-" * 60)
    for t in trades[-10:]:
        print(f"  {t['symbol']:8s} {t['action']:4s} conf={t['confidence']:.2f} "
              f"R={t['r_multiple']:+.2f} {'(dry run)' if t['dry_run'] else '(live)'} "
              f"- {t['reasoning'][:60]}")


if __name__ == "__main__":
    main()
