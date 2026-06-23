"""Email notifications for trade events (open, SL/TP hit, AI-initiated close).

Failure to send must never interrupt the trading loop, so every send is
best-effort and logs+swallows its own exceptions.
"""

from __future__ import annotations

import logging
import os
import smtplib
from email.message import EmailMessage

log = logging.getLogger("mt5_ai_bridge.notify")


class EmailNotifier:
    def __init__(self, enabled: bool, smtp_host: str, smtp_port: int, smtp_user: str,
                 password_env: str, from_addr: str, to_addr: str, notify_dry_run: bool):
        self.enabled = enabled
        self.smtp_host = smtp_host
        self.smtp_port = smtp_port
        self.smtp_user = smtp_user
        self.password = os.environ.get(password_env, "")
        self.from_addr = from_addr
        self.to_addr = to_addr
        self.notify_dry_run = notify_dry_run
        if enabled and not self.password:
            log.warning("notifications.enabled is true but %s is not set — emails will fail", password_env)

    def send(self, subject: str, body: str, dry_run: bool = False) -> None:
        if not self.enabled:
            return
        if dry_run and not self.notify_dry_run:
            return
        try:
            msg = EmailMessage()
            msg["Subject"] = subject
            msg["From"] = self.from_addr
            msg["To"] = self.to_addr
            msg.set_content(body)
            with smtplib.SMTP(self.smtp_host, self.smtp_port, timeout=15) as server:
                server.starttls()
                server.login(self.smtp_user, self.password)
                server.send_message(msg)
        except Exception:
            log.exception("Failed to send notification email: %s", subject)

    def trade_opened(self, symbol: str, action: str, entry: float, sl: float, tp: float,
                     lots: float, confidence: float, strategy: str | None, dry_run: bool) -> None:
        tag = "[DRY RUN] " if dry_run else ""
        self.send(
            f"{tag}{symbol} {action.upper()} opened",
            f"{symbol} {action.upper()}\n"
            f"Entry: {entry}\nSL: {sl}\nTP: {tp}\nLots: {lots}\n"
            f"Confidence: {confidence:.2f}\nStrategy: {strategy or 'discretionary'}\n"
            f"{'DRY RUN — no real order sent' if dry_run else 'LIVE order sent'}",
            dry_run=dry_run,
        )

    def trade_closed(self, symbol: str, result: str, exit_price: float,
                     pnl: float | None, dry_run: bool) -> None:
        tag = "[DRY RUN] " if dry_run else ""
        pnl_line = f"P/L: {pnl:+.2f}\n" if pnl is not None else ""
        self.send(
            f"{tag}{symbol} closed ({result.upper()})",
            f"{symbol} closed\nResult: {result}\nExit price: {exit_price}\n{pnl_line}"
            f"{'DRY RUN — virtual trade' if dry_run else 'LIVE position'}",
            dry_run=dry_run,
        )
