"""Sends recent price action to Claude and parses back a structured trade decision."""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass

import anthropic

log = logging.getLogger("mt5_ai_bridge.ai_analyst")

SYSTEM_PROMPT = """You are a disciplined trading analyst assisting with a live MetaTrader 5 account.
You will be given, for one symbol/timeframe: recent OHLC candles; the current account state; a
deterministic market-regime classification (trend strength via ADX, volatility level via ATR
percentile — computed by code, not by you); a summary of your own recent track record (overall for
this symbol and specifically in the current regime); and a deterministic ICT/SMC structure read.

The "ict" object is computed by code (the same liquidity-sweep / market-structure-shift / fair-value-gap
logic an existing Expert Advisor uses), so you don't have to re-derive that structure from raw candles:
- "htf_bias": higher-timeframe directional bias ("bullish" / "bearish" / "neutral").
- "context": the recent dealing range — "price_zone" (premium = upper third, favor sells; discount =
  lower third, favor buys; equilibrium = middle), plus the nearest swing high/low (liquidity pools
  price may draw toward).
- "bullish_setup"/"bearish_setup": each is null if nothing is forming, else has a "stage":
  "sweep_only" (liquidity swept, no confirmation yet), "mss_confirmed" (structure shift confirmed),
  or "ready" (sweep + MSS + a fair value gap, with "suggested_entry", "suggested_sl", "suggested_tp",
  "rr" — the levels the EA would trade).

Respond with ONLY a single JSON object, no prose, no markdown fences, matching this schema:
{
  "action": "buy" | "sell" | "close" | "hold",
  "confidence": number between 0 and 1,
  "stop_loss": number or null,
  "take_profit": number or null,
  "reasoning": "short string, max 2 sentences"
}

Rules:
- The ict read is a strong, structured input — but you are NOT limited to it and NOT required to take
  every "ready" setup. Treat it as a second set of eyes: it tells you what known ICT structure code
  detected. You may also act on a clear setup you see in the candles that it didn't flag, and you may
  decline or fade a "ready" setup when the regime, premium/discount location, HTF bias, or your own
  track record argue against it. When you do take a detected setup, a market order fills at current
  price — so only act now if price is already at or near the suggested_entry / point of interest;
  otherwise hold and wait for the retracement. You may use the suggested_sl / suggested_tp or your own.
- Only output "buy" or "sell" when you see a clear, well-defined setup. Default to "hold" when uncertain.
- "close" means close any existing open position on this symbol because the thesis is invalidated.
- stop_loss and take_profit must be real price levels consistent with the action, or null for hold/close.
- Be conservative. Low confidence signals should not be acted on by the caller, so be honest about confidence.
- Use the performance summary as real feedback: if your recent record in the current regime is
  poor (low win rate, negative average R), raise your bar for what counts as a clear setup and/or
  lower your confidence in that regime. If a regime has a small sample (low count), don't over-trust
  it either way. If a regime has a strong positive record, that's not license to force a trade — it
  only means a genuine setup in those conditions deserves a bit more confidence.
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
    def __init__(self, api_key_env: str, model: str, max_retries: int = 4):
        api_key = os.environ.get(api_key_env)
        if not api_key:
            raise RuntimeError(
                f"Environment variable {api_key_env} is not set. "
                "Export your Anthropic API key before running the bridge."
            )
        # The SDK retries transient errors on its own; we add an outer backoff
        # loop on top for 529 (overloaded) / 429 (rate limit) which can persist
        # longer than the SDK's default budget during API-wide load spikes.
        self._client = anthropic.Anthropic(api_key=api_key)
        self._model = model
        self._max_retries = max_retries

    def analyze(self, symbol: str, timeframe: str, candles: list[dict],
                account: dict, open_position: dict | None,
                regime: dict | None = None, performance: dict | None = None,
                ict: dict | None = None) -> TradeDecision:
        user_payload = {
            "symbol": symbol,
            "timeframe": timeframe,
            "candles": candles,
            "account": account,
            "open_position": open_position,
            "market_regime": regime,
            "my_recent_performance": performance,
            "ict": ict,
        }
        message = self._create_with_backoff(user_payload, symbol)
        text = "".join(block.text for block in message.content if block.type == "text").strip()
        if not text:
            log.warning("Empty response text from model (stop_reason=%s, usage=%s)",
                        message.stop_reason, message.usage)
        return self._parse(text)

    def _create_with_backoff(self, user_payload: dict, symbol: str):
        delay = 2.0
        for attempt in range(1, self._max_retries + 1):
            try:
                return self._client.messages.create(
                    model=self._model,
                    max_tokens=700,
                    system=SYSTEM_PROMPT,
                    messages=[{"role": "user", "content": json.dumps(user_payload)}],
                )
            except (anthropic.OverloadedError, anthropic.RateLimitError,
                    anthropic.APIConnectionError) as exc:
                if attempt == self._max_retries:
                    raise
                log.warning("[%s] Anthropic API transient error (%s), retry %d/%d in %.0fs",
                            symbol, type(exc).__name__, attempt, self._max_retries - 1, delay)
                time.sleep(delay)
                delay *= 2

    def _parse(self, text: str) -> TradeDecision:
        text = text.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text[3:]
            if text.rstrip().endswith("```"):
                text = text.rstrip()[:-3]
            text = text.strip()
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
