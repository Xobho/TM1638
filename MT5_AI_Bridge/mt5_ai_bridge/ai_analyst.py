"""Sends recent price action to Claude and parses back a structured trade decision."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

import anthropic

log = logging.getLogger("mt5_ai_bridge.ai_analyst")

SYSTEM_PROMPT = """You are a disciplined trading analyst assisting with a live MetaTrader 5 account.
You will be given recent OHLC candles for one symbol/timeframe and the current account state.

Respond with ONLY a single JSON object, no prose, no markdown fences, matching this schema:
{
  "action": "buy" | "sell" | "close" | "hold",
  "confidence": number between 0 and 1,
  "stop_loss": number or null,
  "take_profit": number or null,
  "reasoning": "short string, max 2 sentences"
}

Rules:
- Only output "buy" or "sell" when you see a clear, well-defined setup (e.g. liquidity sweep,
  structure shift, fair value gap, clean support/resistance reaction). Default to "hold" when uncertain.
- "close" means close any existing open position on this symbol because the thesis is invalidated.
- stop_loss and take_profit must be real price levels consistent with the action, or null for hold/close.
- Be conservative. Low confidence signals should not be acted on by the caller, so be honest about confidence.
- Never invent data you were not given.
"""


@dataclass
class TradeDecision:
    action: str
    confidence: float
    stop_loss: float | None
    take_profit: float | None
    reasoning: str

    @staticmethod
    def hold(reason: str) -> "TradeDecision":
        return TradeDecision(action="hold", confidence=0.0, stop_loss=None,
                              take_profit=None, reasoning=reason)


class AIAnalyst:
    def __init__(self, api_key_env: str, model: str):
        api_key = os.environ.get(api_key_env)
        if not api_key:
            raise RuntimeError(
                f"Environment variable {api_key_env} is not set. "
                "Export your Anthropic API key before running the bridge."
            )
        self._client = anthropic.Anthropic(api_key=api_key)
        self._model = model

    def analyze(self, symbol: str, timeframe: str, candles: list[dict],
                account: dict, open_position: dict | None) -> TradeDecision:
        user_payload = {
            "symbol": symbol,
            "timeframe": timeframe,
            "candles": candles,
            "account": account,
            "open_position": open_position,
        }
        message = self._client.messages.create(
            model=self._model,
            max_tokens=400,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": json.dumps(user_payload)}],
        )
        text = "".join(block.text for block in message.content if block.type == "text").strip()
        return self._parse(text)

    def _parse(self, text: str) -> TradeDecision:
        try:
            data = json.loads(text)
            action = str(data.get("action", "hold")).lower()
            if action not in ("buy", "sell", "close", "hold"):
                action = "hold"
            return TradeDecision(
                action=action,
                confidence=float(data.get("confidence", 0.0)),
                stop_loss=data.get("stop_loss"),
                take_profit=data.get("take_profit"),
                reasoning=str(data.get("reasoning", "")),
            )
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            log.warning("Could not parse AI response as JSON (%s): %s", exc, text[:300])
            return TradeDecision.hold(f"unparseable AI response: {exc}")
