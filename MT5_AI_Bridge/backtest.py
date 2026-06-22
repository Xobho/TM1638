#!/usr/bin/env python3
"""Walk-forward backtest: replays historical candles through the same AIAnalyst
the live bridge uses, one closed-candle decision at a time, in chronological
order — so regime/performance context at each step only ever sees data that
would have actually been available at that moment (no lookahead).

Results go to a SEPARATE journal (default logs/backtest_journal.jsonl) so they
never mix with the live bridge's performance-memory calibration.

This makes REAL, BILLED calls to the Anthropic API. It always prints a cost
estimate first and requires explicit confirmation (or --yes) before spending
anything.

Usage:
    python backtest.py --symbol EURUSD --timeframe M15 --days 30
    python backtest.py --symbol EURUSD --timeframe M15 --days 30 --yes
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

from mt5_ai_bridge.ai_analyst import AIAnalyst, SYSTEM_PROMPT
from mt5_ai_bridge.analytics import build_trades, candles_to_dicts, load_events
from mt5_ai_bridge.config import Config
from mt5_ai_bridge.journal import TradeJournal
from mt5_ai_bridge.mt5_client import MT5Client
from mt5_ai_bridge.performance import rolling_stats
from mt5_ai_bridge.regime import compute_regime

# Estimate only — check https://docs.anthropic.com/en/docs/about-claude/pricing
# for the real rate on your account before relying on this number.
PRICE_PER_MTOK_INPUT = 3.0
PRICE_PER_MTOK_OUTPUT = 15.0
AVG_OUTPUT_TOKENS_PER_CALL = 200  # typical short JSON decision; max_tokens cap is 700


def estimate_cost(num_calls: int, sample_payload: dict) -> dict:
    input_chars = len(SYSTEM_PROMPT) + len(json.dumps(sample_payload))
    input_tokens_per_call = input_chars / 4  # rough chars-per-token heuristic
    total_input_tokens = input_tokens_per_call * num_calls
    total_output_tokens = AVG_OUTPUT_TOKENS_PER_CALL * num_calls
    input_cost = total_input_tokens / 1_000_000 * PRICE_PER_MTOK_INPUT
    output_cost = total_output_tokens / 1_000_000 * PRICE_PER_MTOK_OUTPUT
    return {
        "num_calls": num_calls,
        "input_tokens_per_call": round(input_tokens_per_call),
        "total_input_tokens": round(total_input_tokens),
        "total_output_tokens": round(total_output_tokens),
        "estimated_cost_usd": round(input_cost + output_cost, 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--symbol", required=True)
    parser.add_argument("--timeframe", default="M15")
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--bars", type=int, default=200, help="lookback window per decision")
    parser.add_argument("--journal", default="logs/backtest_journal.jsonl")
    parser.add_argument("--fallback-rr", type=float, default=2.0,
                         help="R:R used when the AI gives no take_profit")
    parser.add_argument("--min-confidence", type=float, default=0.65)
    parser.add_argument("--yes", action="store_true",
                         help="skip the confirmation prompt and spend immediately")
    args = parser.parse_args()

    config = Config.load(args.config)
    a = config.anthropic
    analyst = AIAnalyst(api_key_env=a.get("api_key_env", "ANTHROPIC_API_KEY"),
                         model=a.get("model", "claude-sonnet-4-6"))

    mt5_client = MT5Client(**{k: v for k, v in config.mt5.items()
                               if k in ("terminal_path", "login", "password", "server")})
    mt5_client.connect()
    try:
        date_to = dt.datetime.now()
        date_from = date_to - dt.timedelta(days=args.days)
        rates = mt5_client.get_rates_range(args.symbol, args.timeframe, date_from, date_to)
    finally:
        mt5_client.shutdown()

    all_candles = candles_to_dicts(rates, limit=len(rates))
    if len(all_candles) <= args.bars:
        print(f"Only {len(all_candles)} candles fetched, need more than --bars={args.bars} "
              "to run a single decision. Try a larger --days.")
        sys.exit(1)

    num_calls = len(all_candles) - args.bars
    sample_payload = {
        "symbol": args.symbol,
        "timeframe": args.timeframe,
        "candles": all_candles[:args.bars],
        "account": {"balance": 10000.0, "equity": 10000.0, "currency": "USD"},
        "open_position": None,
        "market_regime": {"label": "trending-normalvol", "trend": "trending",
                           "volatility": "normal", "adx": 28.4, "atr": 0.00123,
                           "atr_percentile": 55.0},
        "my_recent_performance": {
            "overall": {"count": 12, "win_rate": 50.0, "avg_r": 0.1},
            "current_regime": {"count": 4, "win_rate": 50.0, "avg_r": 0.1},
        },
    }
    est = estimate_cost(num_calls, sample_payload)

    print("=" * 60)
    print(f"BACKTEST COST ESTIMATE — {args.symbol} {args.timeframe}, {args.days} days")
    print("=" * 60)
    print(f"  candles fetched:       {len(all_candles)}")
    print(f"  decisions (API calls): {est['num_calls']}")
    print(f"  est. input tokens/call: ~{est['input_tokens_per_call']}")
    print(f"  est. total input tokens:  ~{est['total_input_tokens']:,}")
    print(f"  est. total output tokens: ~{est['total_output_tokens']:,}")
    print(f"  ESTIMATED COST: ~${est['estimated_cost_usd']:.2f} USD")
    print()
    print("  This is a rough estimate (chars/4 token heuristic, fixed $3/$15 per")
    print("  MTok pricing) — check the real rate for your model/account at")
    print("  https://docs.anthropic.com/en/docs/about-claude/pricing before relying on it.")
    print("=" * 60)

    if not args.yes:
        answer = input("\nProceed and make these real, billed API calls? [y/N] ").strip().lower()
        if answer != "y":
            print("Aborted — no API calls made.")
            return

    journal = TradeJournal(args.journal)
    run_backtest(analyst, all_candles, args, journal)


def run_backtest(analyst: AIAnalyst, all_candles: list[dict], args, journal: TradeJournal) -> None:
    open_trade: dict | None = None

    for i in range(args.bars, len(all_candles)):
        window = all_candles[i - args.bars:i]
        bar = all_candles[i]
        regime = compute_regime(window)
        performance = {
            "overall": rolling_stats(journal.path, args.symbol, regime_label=None, lookback=30),
            "current_regime": rolling_stats(journal.path, args.symbol,
                                             regime_label=regime["label"], lookback=30),
        }

        if open_trade is not None:
            entry, sl, tp, is_buy = open_trade["entry"], open_trade["sl"], open_trade["tp"], open_trade["is_buy"]
            hit_sl = bar["low"] <= sl if is_buy else bar["high"] >= sl
            hit_tp = bar["high"] >= tp if is_buy else bar["low"] <= tp
            if hit_sl or hit_tp:
                exit_price = sl if hit_sl else tp
                journal.log_close(args.symbol, exit_price, result="sl" if hit_sl else "tp",
                                   pnl=None, dry_run=True)
                open_trade = None

        decision = analyst.analyze(
            symbol=args.symbol, timeframe=args.timeframe, candles=window,
            account={"balance": 10000.0, "equity": 10000.0, "currency": "USD"},
            open_position=None if open_trade is None else {
                "type": "buy" if open_trade["is_buy"] else "sell",
            },
            regime=regime, performance=performance,
        )
        journal.log_signal(args.symbol, decision.action, decision.confidence,
                            decision.reasoning, regime=regime["label"])

        if decision.action in ("hold", "close"):
            continue
        if open_trade is not None:
            continue
        if decision.confidence < args.min_confidence or decision.stop_loss is None:
            continue

        is_buy = decision.action == "buy"
        entry = bar["close"]
        sl = decision.stop_loss
        tp = decision.take_profit
        if tp is None:
            dist = abs(entry - sl)
            tp = entry + dist * args.fallback_rr if is_buy else entry - dist * args.fallback_rr

        journal.log_open(args.symbol, decision.action, entry, sl, tp, lots=0.0,
                          confidence=decision.confidence, reasoning=decision.reasoning,
                          dry_run=True, regime=regime["label"])
        open_trade = {"entry": entry, "sl": sl, "tp": tp, "is_buy": is_buy}

    trades = build_trades(load_events(str(journal.path)))
    print(f"\nBacktest complete: {len(trades)} completed trades logged to {journal.path}")
    print("Run: python report.py --journal", journal.path)


if __name__ == "__main__":
    main()
