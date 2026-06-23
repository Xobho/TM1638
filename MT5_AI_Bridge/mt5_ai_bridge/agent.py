"""Main polling loop: pulls candles from MT5, asks Claude for a decision,
runs it through risk checks, then acts (or just logs, in dry_run mode)."""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import MetaTrader5 as mt5

from .ai_analyst import AIAnalyst, TradeDecision
from .analytics import candles_to_dicts
from .config import Config
from .ict import compute_ict_features
from .journal import TradeJournal
from .mt5_client import MT5Client
from .notify import EmailNotifier
from .performance import rolling_stats
from .regime import compute_regime
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

        ic = t.get("ict", {})
        self.ict_enabled: bool = ic.get("enabled", True)
        self.htf_timeframe: str = t.get("htf_timeframe", "H4")
        self.htf_bars: int = ic.get("htf_bars", 300)
        self.ict_params = dict(
            swing_lr=ic.get("swing_left_right", 3),
            min_fvg_points=ic.get("min_fvg_points", 30.0),
            sweep_buffer_points=ic.get("sweep_buffer_points", 20.0),
            entry_midpoint=ic.get("entry_at_midpoint", True),
            fallback_rr=ic.get("fallback_rr", r.get("fallback_rr", 2.0)),
            require_htf_bias=ic.get("require_htf_bias", True),
        )

        vt = t.get("volatility_trigger", {})
        self.vt_enabled: bool = vt.get("enabled", False)
        self.vt_check_seconds: int = vt.get("check_seconds", 5)
        self.vt_window_seconds: int = vt.get("window_seconds", 60)
        self.vt_points: float = vt.get("points", 150)
        self.vt_cooldown_seconds: int = vt.get("cooldown_seconds", 120)
        self._tick_history: dict[str, list[tuple[float, float]]] = {}
        self._last_vt_trigger: dict[str, float] = {}

        self.log_ai_responses = config.logging_cfg.get("log_ai_responses", True)
        self._last_bar_time: dict[str, int] = {}

        n = config.notifications
        self.notifier = EmailNotifier(
            enabled=n.get("enabled", False),
            smtp_host=n.get("smtp_host", ""),
            smtp_port=n.get("smtp_port", 587),
            smtp_user=n.get("smtp_user", ""),
            password_env=n.get("password_env", "BRIDGE_EMAIL_PASSWORD"),
            from_addr=n.get("from_addr", n.get("smtp_user", "")),
            to_addr=n.get("to_addr", ""),
            notify_dry_run=n.get("notify_dry_run", True),
        )

        log_dir = config.logging_cfg.get("log_dir", "logs")
        self.journal = TradeJournal(str(Path(log_dir) / "trade_journal.jsonl"))
        self._virtual_trades: dict[str, dict] = {}   # dry-run open "trades" by symbol
        self._open_tickets: dict[str, int] = {}      # real open position tickets by symbol

        if self.risk.limits.dry_run:
            log.warning("DRY RUN MODE — no real orders will be sent. Set risk.dry_run: false to go live.")
        else:
            log.warning("LIVE TRADING MODE — real orders WILL be sent to your account.")

    def run_forever(self) -> None:
        self.mt5.connect()
        last_poll = 0.0
        sleep_step = min(self.vt_check_seconds, self.poll_seconds) if self.vt_enabled else self.poll_seconds
        try:
            while True:
                now = time.time()
                for symbol in self.symbols:
                    try:
                        self._check_open_trades(symbol)
                        if self.vt_enabled:
                            self._check_volatility_trigger(symbol, now)
                    except Exception:
                        log.exception("Error checking %s", symbol)

                if now - last_poll >= self.poll_seconds:
                    last_poll = now
                    for symbol in self.symbols:
                        try:
                            self._process_symbol(symbol)
                        except Exception:
                            log.exception("Error processing %s", symbol)

                time.sleep(sleep_step)
        finally:
            self.mt5.shutdown()

    def run_once(self) -> None:
        self.mt5.connect()
        try:
            for symbol in self.symbols:
                self._check_open_trades(symbol)
                self._process_symbol(symbol, force=True)
        finally:
            self.mt5.shutdown()

    def _check_open_trades(self, symbol: str) -> None:
        """Detects fills/closes since the last poll and writes outcomes to the journal."""
        v = self._virtual_trades.get(symbol)
        if v is not None:
            tick = self.mt5.get_tick(symbol)
            is_buy = v["action"] == "buy"
            price = tick.bid if is_buy else tick.ask
            hit_sl = price <= v["sl"] if is_buy else price >= v["sl"]
            hit_tp = price >= v["tp"] if is_buy else price <= v["tp"]
            if hit_sl or hit_tp:
                exit_price = v["sl"] if hit_sl else v["tp"]
                result = "sl" if hit_sl else "tp"
                self.journal.log_close(symbol, exit_price, result=result, pnl=None, dry_run=True)
                log.info("[%s] [DRY RUN] virtual trade closed: %s", symbol, "SL hit" if hit_sl else "TP hit")
                self.notifier.trade_closed(symbol, result, exit_price, pnl=None, dry_run=True)
                del self._virtual_trades[symbol]

        ticket = self._open_tickets.get(symbol)
        if ticket is not None:
            if self.mt5.open_positions(symbol=symbol, magic=self.magic):
                return
            result = self.mt5.closed_position_result(ticket)
            if result is not None:
                exit_price, profit = result
                result = "win" if profit > 0 else "loss"
                self.journal.log_close(symbol, exit_price, result=result, pnl=profit, dry_run=False)
                log.info("[%s] position closed: profit=%.2f", symbol, profit)
                self.notifier.trade_closed(symbol, result, exit_price, pnl=profit, dry_run=False)
                del self._open_tickets[symbol]

    def _check_volatility_trigger(self, symbol: str, now: float) -> None:
        """Fires an immediate, out-of-cycle AI call if price moves abnormally fast.

        Normal analysis only runs once per closed candle, which can miss a
        fast intra-candle move (e.g. a news spike that sweeps and reverses
        before the candle closes). This samples price independently of the
        candle clock and triggers early when it sees a real spike.
        """
        tick = self.mt5.get_tick(symbol)
        price = (tick.bid + tick.ask) / 2.0
        hist = self._tick_history.setdefault(symbol, [])
        hist.append((now, price))
        cutoff = now - self.vt_window_seconds
        while hist and hist[0][0] < cutoff:
            hist.pop(0)
        if len(hist) < 2:
            return

        info = self.mt5.symbol_info(symbol)
        if info.point <= 0:
            return
        move_points = abs(price - hist[0][1]) / info.point

        last_trigger = self._last_vt_trigger.get(symbol, 0.0)
        if move_points >= self.vt_points and (now - last_trigger) >= self.vt_cooldown_seconds:
            log.warning("[%s] Volatility spike: %.1f points in %ds — triggering immediate AI check",
                        symbol, move_points, self.vt_window_seconds)
            self._last_vt_trigger[symbol] = now
            hist.clear()
            try:
                self._process_symbol(symbol, force=True)
            except Exception:
                log.exception("Error in volatility-triggered analysis for %s", symbol)

    def _process_symbol(self, symbol: str, force: bool = False) -> None:
        rates = self.mt5.get_rates(symbol, self.timeframe, self.bars)
        latest_bar_time = int(rates[-1]["time"])
        if not force and self._last_bar_time.get(symbol) == latest_bar_time:
            return
        self._last_bar_time[symbol] = latest_bar_time

        account = self.mt5.account_snapshot()
        positions = self.mt5.open_positions(symbol=symbol, magic=self.magic)
        virtual = self._virtual_trades.get(symbol)
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
        elif virtual is not None:
            # Dry run: no real position exists, but a virtual one is open — tell
            # the AI so it doesn't act as if flat (mirrors live one-trade-per-symbol).
            open_position = {
                "type": virtual["action"],
                "volume": virtual["lots"],
                "price_open": virtual["entry"],
                "sl": virtual["sl"],
                "tp": virtual["tp"],
                "profit": None,
            }

        candles = candles_to_dicts(rates, self.bars)
        regime = compute_regime(candles)
        performance = {
            "overall": rolling_stats(self.journal.path, symbol, regime_label=None, lookback=30),
            "current_regime": rolling_stats(self.journal.path, symbol,
                                             regime_label=regime["label"], lookback=30),
        }
        ict = self._compute_ict(symbol, candles)

        decision = self.analyst.analyze(
            symbol=symbol,
            timeframe=self.timeframe,
            candles=candles,
            account={"balance": account.balance, "equity": account.equity,
                     "currency": account.currency},
            open_position=open_position,
            regime=regime,
            performance=performance,
            ict=ict,
        )

        if self.log_ai_responses:
            log.info("[%s] regime=%-18s action=%-4s conf=%.2f strategy=%s sl=%s tp=%s",
                      symbol, regime["label"], decision.action, decision.confidence,
                      decision.strategy or "-", decision.stop_loss, decision.take_profit)
            log.info("[%s]   reasoning: %s", symbol, decision.reasoning)

        self.journal.log_signal(symbol, decision.action, decision.confidence, decision.reasoning,
                                 regime=regime["label"], strategy=decision.strategy)
        self._act_on_decision(symbol, decision, positions, virtual, regime["label"])

    def _compute_ict(self, symbol: str, candles: list[dict]) -> dict | None:
        """Deterministic ICT/SMC structure (same logic as the MQL5 EA) fed to the
        AI as features. Failure here must never kill the analysis cycle."""
        if not self.ict_enabled:
            return None
        try:
            point = self.mt5.symbol_info(symbol).point
            htf_candles = None
            if self.ict_params["require_htf_bias"]:
                htf_rates = self.mt5.get_rates(symbol, self.htf_timeframe, self.htf_bars)
                htf_candles = candles_to_dicts(htf_rates, self.htf_bars)
            return compute_ict_features(candles, htf_candles, point, **self.ict_params)
        except Exception:
            log.exception("[%s] ICT feature computation failed — sending no ICT context", symbol)
            return None

    def _act_on_decision(self, symbol: str, decision: TradeDecision, positions: list,
                          virtual: dict | None, regime_label: str) -> None:
        if decision.action == "hold":
            return

        if decision.action == "close":
            if positions:
                for p in positions:
                    self._close(symbol, p)
            elif virtual is not None:
                tick = self.mt5.get_tick(symbol)
                exit_price = tick.bid if virtual["action"] == "buy" else tick.ask
                log.info("[%s] [DRY RUN] Would close virtual trade on AI 'close' signal", symbol)
                self.journal.log_close(symbol, exit_price, result="closed", pnl=None, dry_run=True)
                self.notifier.trade_closed(symbol, "closed", exit_price, pnl=None, dry_run=True)
                del self._virtual_trades[symbol]
            return

        if positions or virtual is not None:
            log.info("[%s] AI said %s but a position is already open under this magic number — skipping",
                      symbol, decision.action)
            return

        if decision.stop_loss is None:
            log.warning("[%s] AI gave no stop_loss for a %s signal — skipping (no SL = no trade)",
                        symbol, decision.action)
            return

        spread = self.mt5.spread_points(symbol)
        open_count = len(self._virtual_trades) if self.risk.limits.dry_run \
            else len(self.mt5.open_positions(magic=self.magic))
        ok, reason = self.risk.can_open_new_trade(
            confidence=decision.confidence,
            open_position_count=open_count,
            spread_points=spread,
        )
        if not ok:
            log.info("[%s] Signal %s rejected by risk manager: %s", symbol, decision.action, reason)
            self.journal.log_rejected(symbol, decision.action, decision.confidence, reason,
                                       regime=regime_label, strategy=decision.strategy)
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
            self.journal.log_open(symbol, decision.action, entry, sl, tp, lots,
                                   decision.confidence, decision.reasoning, dry_run=True,
                                   regime=regime_label, strategy=decision.strategy)
            self._virtual_trades[symbol] = {"action": decision.action, "entry": entry, "sl": sl,
                                             "tp": tp, "lots": lots}
            self.notifier.trade_opened(symbol, decision.action, entry, sl, tp, lots,
                                        decision.confidence, decision.strategy, dry_run=True)
            self.risk.state.register_trade()
            return

        result = self.mt5.send_market_order(
            symbol=symbol, is_buy=is_buy, lots=lots, sl=sl, tp=tp,
            magic=self.magic, comment="mt5_ai_bridge",
        )
        log.info("[%s] order_send result: retcode=%s comment=%s", symbol,
                  getattr(result, "retcode", "?"), getattr(result, "comment", "?"))
        if result is not None and result.retcode == mt5.TRADE_RETCODE_DONE:
            self.journal.log_open(symbol, decision.action, entry, sl, tp, lots,
                                   decision.confidence, decision.reasoning, dry_run=False,
                                   regime=regime_label, ticket=result.order, strategy=decision.strategy)
            self._open_tickets[symbol] = result.order
            self.notifier.trade_opened(symbol, decision.action, entry, sl, tp, lots,
                                        decision.confidence, decision.strategy, dry_run=False)
        self.risk.state.register_trade()

    def _close(self, symbol: str, position) -> None:
        if self.risk.limits.dry_run:
            log.info("[DRY RUN] Would close %s ticket=%s", symbol, position.ticket)
            return
        result = self.mt5.close_position(position)
        log.info("[%s] close result: retcode=%s", symbol, getattr(result, "retcode", "?"))
