"""Thin wrapper around the MetaTrader5 Python package.

Requires a running MT5 terminal on the same machine (Windows, or Linux/Mac
under Wine) with the package's terminal64.exe reachable. See the MetaTrader5
package docs: https://www.mql5.com/en/docs/python_metatrader5
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import MetaTrader5 as mt5

log = logging.getLogger("mt5_ai_bridge.mt5_client")

TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}


class MT5ConnectionError(RuntimeError):
    pass


@dataclass
class AccountSnapshot:
    balance: float
    equity: float
    margin_free: float
    currency: str


class MT5Client:
    def __init__(self, terminal_path: str = "", login: int = 0,
                 password: str = "", server: str = ""):
        self._terminal_path = terminal_path or None
        self._login = login
        self._password = password
        self._server = server

    def connect(self) -> None:
        ok = mt5.initialize(path=self._terminal_path) if self._terminal_path else mt5.initialize()
        if not ok:
            raise MT5ConnectionError(f"mt5.initialize() failed: {mt5.last_error()}")

        if self._login:
            authed = mt5.login(self._login, password=self._password, server=self._server)
            if not authed:
                raise MT5ConnectionError(f"mt5.login() failed: {mt5.last_error()}")

        info = mt5.terminal_info()
        if info is None or not info.trade_allowed:
            log.warning(
                "Terminal connected but AutoTrading/trade_allowed is OFF — "
                "orders will be rejected until it's enabled in MT5."
            )
        log.info("Connected to MT5 terminal (build %s)", getattr(info, "build", "?"))

    def shutdown(self) -> None:
        mt5.shutdown()

    def account_snapshot(self) -> AccountSnapshot:
        a = mt5.account_info()
        if a is None:
            raise MT5ConnectionError(f"account_info() failed: {mt5.last_error()}")
        return AccountSnapshot(balance=a.balance, equity=a.equity,
                                margin_free=a.margin_free, currency=a.currency)

    def get_rates(self, symbol: str, timeframe: str, bars: int):
        tf = TIMEFRAME_MAP.get(timeframe.upper())
        if tf is None:
            raise ValueError(f"Unsupported timeframe: {timeframe}")
        rates = mt5.copy_rates_from_pos(symbol, tf, 0, bars)
        if rates is None or len(rates) == 0:
            raise MT5ConnectionError(f"copy_rates_from_pos failed for {symbol}: {mt5.last_error()}")
        return rates

    def get_rates_range(self, symbol: str, timeframe: str, date_from, date_to):
        """Pulls all bars between two datetimes — used by backtest.py, not the live loop
        (which only ever wants the most recent N bars via get_rates)."""
        tf = TIMEFRAME_MAP.get(timeframe.upper())
        if tf is None:
            raise ValueError(f"Unsupported timeframe: {timeframe}")
        rates = mt5.copy_rates_range(symbol, tf, date_from, date_to)
        if rates is None or len(rates) == 0:
            raise MT5ConnectionError(f"copy_rates_range failed for {symbol}: {mt5.last_error()}")
        return rates

    def get_tick(self, symbol: str):
        tick = mt5.symbol_info_tick(symbol)
        if tick is None:
            raise MT5ConnectionError(f"symbol_info_tick failed for {symbol}: {mt5.last_error()}")
        return tick

    def symbol_info(self, symbol: str):
        info = mt5.symbol_info(symbol)
        if info is None:
            raise MT5ConnectionError(f"symbol_info failed for {symbol}: {mt5.last_error()}")
        if not info.visible:
            mt5.symbol_select(symbol, True)
        return info

    def open_positions(self, symbol: str | None = None, magic: int | None = None):
        positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
        positions = list(positions or [])
        if magic is not None:
            positions = [p for p in positions if p.magic == magic]
        return positions

    def spread_points(self, symbol: str) -> float:
        info = self.symbol_info(symbol)
        tick = self.get_tick(symbol)
        if info.point == 0:
            return 0.0
        return (tick.ask - tick.bid) / info.point

    def send_market_order(self, symbol: str, is_buy: bool, lots: float,
                           sl: float, tp: float, magic: int, comment: str):
        tick = self.get_tick(symbol)
        order_type = mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL
        price = tick.ask if is_buy else tick.bid
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": lots,
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": magic,
            "comment": comment[:31],
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        result = mt5.order_send(request)
        if result is None:
            raise MT5ConnectionError(f"order_send returned None: {mt5.last_error()}")
        return result

    def close_position(self, position) -> "mt5.OrderSendResult":
        tick = self.get_tick(position.symbol)
        is_buy = position.type == mt5.POSITION_TYPE_BUY
        order_type = mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY
        price = tick.bid if is_buy else tick.ask
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": position.symbol,
            "volume": position.volume,
            "type": order_type,
            "position": position.ticket,
            "price": price,
            "deviation": 20,
            "magic": position.magic,
            "comment": "ai_bridge_close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        return mt5.order_send(request)

    def closed_position_result(self, ticket: int):
        """Returns (exit_price, total_profit) for a closed position, or None if not found yet."""
        deals = mt5.history_deals_get(position=ticket)
        if not deals:
            return None
        closing_deals = [d for d in deals if d.entry == mt5.DEAL_ENTRY_OUT]
        if not closing_deals:
            return None
        exit_price = closing_deals[-1].price
        total_profit = sum(d.profit for d in deals)
        return exit_price, total_profit

    def lots_for_risk(self, symbol: str, risk_percent: float, entry: float, sl: float) -> float:
        info = self.symbol_info(symbol)
        account = self.account_snapshot()
        risk_amount = account.equity * (risk_percent / 100.0)
        sl_distance = abs(entry - sl)
        if sl_distance <= 0 or info.trade_tick_value <= 0:
            return info.volume_min
        ticks = sl_distance / info.point
        value_per_lot = ticks * info.trade_tick_value
        if value_per_lot <= 0:
            return info.volume_min
        lots = risk_amount / value_per_lot
        step = info.volume_step or 0.01
        lots = max(info.volume_min, min(info.volume_max, round(lots / step) * step))
        return round(lots, 2)
