"""Main polling loop: pulls candles from MT5, asks Claude for a decision,
runs it through risk checks, then acts (or just logs, in dry_run mode)."""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from .ai_analyst import AIAnalyst, TradeDecision
from .config import Config
from .mt5_client import MT5Client
from .risk import RiskLimits, RiskManager

log = logging.getLogger("mt5_ai_bridge.agent")


def _setup_logging(log_dir: str) -> None:
    Path(log_dir).mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(Path(log_dir) / "bridge.log"),
        ],
    )


def _candles_to_dicts(rates, limit: int = 200) -> list[dict]:
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


class Agent:
    def __init__(self, config: Config):
        self.config = config
        _setup_logging(config.logging_cfg.get("log_dir", "logs"))

        m = config.mt5
        self.mt5 = MT5Client(
            terminal_path=m.get("terminal_path", ""),
            login=m.get("login", 0),
            password=m.get("password", ""),
            server=m.get("server", ""),
        )

        a = config.anthropic
        self.analyst = AIAnalyst(
            api_key_env=a.get("api_key_env", "ANTHROPIC_API_KEY"),
            model=a.get("model", "claude-sonnet-4-6"),
        )

        r = config.risk
        self.risk = RiskManager(RiskLimits(
            dry_run=r.get("dry_run", True),
            max_risk_percent_per_trade=r.get("max_risk_percent_per_trade", 1.0),
            max_open_positions=r.get("max_open_positions", 3),
            max_daily_trades=r.get("max_daily_trades", 6),
            max_spread_points=r.get("max_spread_points", 30.0),
            min_confidence=r.get("min_confidence", 0.65),
            fallback_rr=r.get("fallback_rr", 2.0),
        ))

        t = config.trading
        self.symbols: list[str] = t.get("symbols", ["EURUSD"])
        self.timeframe: str = t.get("timeframe", "M15")
        self.bars: int = t.get("bars", 200)
        self.poll_seconds: int = t.get("poll_seconds", 60)
        self.magic: int = t.get("magic_number", 990177)

        self.log_ai_responses = config.logging_cfg.get("log_ai_responses", True)
        self._last_bar_time: dict[str, int] = {}

        if self.risk.limits.dry_run:
            log.warning("DRY RUN MODE — no real orders will be sent. Set risk.dry_run: false to go live.")
        else:
            log.warning("LIVE TRADING MODE — real orders WILL be sent to your account.")

    def run_forever(self) -> None:
        self.mt5.connect()
        try:
            while True:
                for symbol in self.symbols:
                    try:
                        self._process_symbol(symbol)
                    except Exception:
                        log.exception("Error processing %s", symbol)
                time.sleep(self.poll_seconds)
        finally:
            self.mt5.shutdown()

    def run_once(self) -> None:
        self.mt5.connect()
        try:
            for symbol in self.symbols:
                self._process_symbol(symbol, force=True)
        finally:
            self.mt5.shutdown()

    def _process_symbol(self, symbol: str, force: bool = False) -> None:
        rates = self.mt5.get_rates(symbol, self.timeframe, self.bars)
        latest_bar_time = int(rates[-1]["time"])
        if not force and self._last_bar_time.get(symbol) == latest_bar_time:
            return
        self._last_bar_time[symbol] = latest_bar_time

        account = self.mt5.account_snapshot()
        positions = self.mt5.open_positions(symbol=symbol, magic=self.magic)
        open_position = None
        if positions:
            p = positions[0]
            open_position = {
                "type": "buy" if p.type == 0 else "sell",
                "volume": p.volume,
                "price_open": p.price_open,
                "sl": p.sl,
                "tp": p.tp,
                "profit": p.profit,
            }

        candles = _candles_to_dicts(rates, self.bars)
        decision = self.analyst.analyze(
            symbol=symbol,
            timeframe=self.timeframe,
            candles=candles,
            account={"balance": account.balance, "equity": account.equity,
                     "currency": account.currency},
            open_position=open_position,
        )

        if self.log_ai_responses:
            log.info("[%s] AI decision: %s", symbol, json.dumps(decision.__dict__))

        self._act_on_decision(symbol, decision, positions)

    def _act_on_decision(self, symbol: str, decision: TradeDecision, positions: list) -> None:
        if decision.action == "hold":
            return

        if decision.action == "close":
            if not positions:
                return
            for p in positions:
                self._close(symbol, p)
            return

        if positions:
            log.info("[%s] AI said %s but a position is already open under this magic number — skipping",
                      symbol, decision.action)
            return

        if decision.stop_loss is None:
            log.warning("[%s] AI gave no stop_loss for a %s signal — skipping (no SL = no trade)",
                        symbol, decision.action)
            return

        spread = self.mt5.spread_points(symbol)
        ok, reason = self.risk.can_open_new_trade(
            confidence=decision.confidence,
            open_position_count=len(self.mt5.open_positions(magic=self.magic)),
            spread_points=spread,
        )
        if not ok:
            log.info("[%s] Signal %s rejected by risk manager: %s", symbol, decision.action, reason)
            return

        tick = self.mt5.get_tick(symbol)
        is_buy = decision.action == "buy"
        entry = tick.ask if is_buy else tick.bid
        sl = decision.stop_loss
        tp = decision.take_profit
        if tp is None:
            dist = abs(entry - sl)
            tp = entry + dist * self.risk.limits.fallback_rr if is_buy else entry - dist * self.risk.limits.fallback_rr

        lots = self.mt5.lots_for_risk(symbol, self.risk.limits.max_risk_percent_per_trade, entry, sl)

        if self.risk.limits.dry_run:
            log.info("[DRY RUN] Would send %s %s lots=%.2f entry=%.5f sl=%.5f tp=%.5f reason=%s",
                      symbol, decision.action, lots, entry, sl, tp, decision.reasoning)
            self.risk.state.register_trade()
            return

        result = self.mt5.send_market_order(
            symbol=symbol, is_buy=is_buy, lots=lots, sl=sl, tp=tp,
            magic=self.magic, comment="mt5_ai_bridge",
        )
        log.info("[%s] order_send result: retcode=%s comment=%s", symbol,
                  getattr(result, "retcode", "?"), getattr(result, "comment", "?"))
        self.risk.state.register_trade()

    def _close(self, symbol: str, position) -> None:
        if self.risk.limits.dry_run:
            log.info("[DRY RUN] Would close %s ticket=%s", symbol, position.ticket)
            return
        result = self.mt5.close_position(position)
        log.info("[%s] close result: retcode=%s", symbol, getattr(result, "retcode", "?"))
