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
this symbol, specifically in the current regime, and — once enough trades exist — broken down by
which ICT strategy was traded, in "my_recent_performance.by_strategy"); and a deterministic ICT/SMC
structure read.

"my_recent_performance.by_strategy" only lists a strategy once it has at least 10 completed trades
for this symbol (smaller samples are omitted as statistically meaningless, not shown as zero/poor).
When a strategy you're considering acting on appears there, treat its win_rate/avg_r as real evidence
about how that specific setup has performed for you on this symbol — weigh it the same way you already
weigh overall/regime performance. A strategy absent from this dict has no track record yet; judge it
purely on the structure itself.

The "ict" object is computed by code (the same family of structure-detection logic an Expert Advisor
uses), so you don't have to re-derive structure from raw candles:
- "htf_bias": higher-timeframe directional bias ("bullish" / "bearish" / "neutral").
- "context": the recent dealing range — "price_zone" (premium = upper third, favor sells; discount =
  lower third, favor buys; equilibrium = middle), the nearest swing high/low, and any "equal_highs"/
  "equal_lows" (resting liquidity pools price may draw toward).
- "setups": a list of every ICT setup currently detected, across BOTH directions and SEVERAL
  strategies. Each entry has a "strategy", a "direction" ("bullish"/"bearish"), a "stage", and (when
  actionable) "suggested_entry" / "suggested_sl" / "suggested_tp" / "rr" plus the relevant zone. Each
  entry also has "formed_by": the candle "time" values of the specific candles whose wicks/closes
  produced that zone or level, in case you need to reference exactly which candles a setup is built from.
  The strategies are:
    - "liquidity_sweep_mss": sweep of liquidity -> market-structure shift -> fair-value-gap entry.
      Its stage progresses "sweep_only" -> "mss_confirmed" -> "ready".
    - "order_block": last opposing candle before a break of structure; entry on the retrace into it.
    - "fair_value_gap": a standalone unfilled 3-candle imbalance; entry on the retrace into the gap.
    - "breaker_block": an order block that failed and flipped; entry on the retest.
    - "turtle_soup": a false breakout of the prior range extreme that closed back inside (reversal).
    - "optimal_trade_entry": the 0.62-0.79 fib retracement zone of the most recent impulse leg.
    - "continuation_retest": a swing level price has already broken through, now being retested from
      the breakout side. Unlike the five strategies above (all reversal/retracement entries that wait
      for a pullback INTO a zone), this is a trend-CONTINUATION entry: the level has flipped from
      resistance to support (or vice versa) and price is testing that flip without a deep retrace.
      Use it for strong trending moves that run through retracement zones without pausing in them.
  For the zone strategies, stage "ready" means price is AT the point of interest now (actionable on a
  market order); "forming" means the structure is valid but price must still retrace into the zone.
  An empty "setups" list means code found no clean structure this candle. Most setups also carry a
  "tested" boolean: true means price has already wicked back into this zone/level at least once since
  it formed (even if it never closed inside), regardless of whether it's "ready" right now. "stage" alone
  can't distinguish a never-touched zone from one already tested and rejected once — "tested": true is a
  weaker, used-up version of the setup (the market already had its first shot at it and continued), so
  treat a tested zone with more caution / lower conviction than a fresh, untested one of the same stage.

The "volume_profile" object (may be null if there isn't enough data) is a tick-volume profile of the
visible candle window — "poc" (point of control, the most-traded price), "value_area_high"/"value_area_low"
(the range holding ~70% of volume), and "hvn_zones"/"lvn_zones" (high/low tick-volume price bands). Its
own "note" field reminds you this is tick volume (a proxy for activity), not true traded volume, so treat
it ONLY as a soft confluence adjustment — e.g. a setup's zone overlapping an HVN or the POC is a mildly
supportive sign; a setup sitting in a LVN deserves a bit more caution since price may have moved through
that level quickly without real interest. Never let volume_profile alone justify a trade or override clear
ICT structure / htf_bias.

Your entire reply must be exactly one JSON object: the very first character must be "{" and the last
must be "}". No prose, no headers, no markdown fences, no analysis before or after it — put any
reasoning you need inside the "reasoning" field itself, matching this schema:
{
  "action": "buy" | "sell" | "close" | "hold",
  "confidence": number between 0 and 1,
  "stop_loss": number or null,
  "take_profit": number or null,
  "strategy": one of the strategy names above if you acted on a detected setup, "discretionary" if you
              acted on your own read of the candles, or null for hold/close,
  "reasoning": "short string, max 2 sentences"
}

Rules:
- The "setups" list is a strong, structured input — but you are NOT limited to it and NOT required to
  take every "ready" setup. Treat it as several sets of eyes: it tells you what known ICT structures
  code detected right now. Multiple setups can be present at once (even conflicting long/short ones);
  it is your job to judge which, if any, deserves a trade given htf_bias, premium/discount location,
  regime, and your own track record. You may also act on a clear setup in the candles that none of the
  detectors flagged (set "strategy": "discretionary"), and you may decline or fade a "ready" setup.
  When you act on a detected setup, a market order fills at current price — so only act now if price is
  at/near that setup's suggested_entry / zone; otherwise hold and wait for the retracement. You may use
  the setup's suggested_sl / suggested_tp or your own. Always set "strategy" to whatever you acted on.
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
    strategy: str | None = None

    @staticmethod
    def hold(reason: str) -> "TradeDecision":
        return TradeDecision(action="hold", confidence=0.0, stop_loss=None,
                              take_profit=None, reasoning=reason, strategy=None)


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
                ict: dict | None = None, volume_profile: dict | None = None) -> TradeDecision:
        user_payload = {
            "symbol": symbol,
            "timeframe": timeframe,
            "candles": candles,
            "account": account,
            "open_position": open_position,
            "market_regime": regime,
            "my_recent_performance": performance,
            "ict": ict,
            "volume_profile": volume_profile,
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
                    max_tokens=1024,
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
            data = self._extract_json(text)
            action = str(data.get("action", "hold")).lower()
            if action not in ("buy", "sell", "close", "hold"):
                action = "hold"
            strategy = data.get("strategy")
            strategy = str(strategy) if strategy not in (None, "") else None
            return TradeDecision(
                action=action,
                confidence=float(data.get("confidence", 0.0)),
                stop_loss=data.get("stop_loss"),
                take_profit=data.get("take_profit"),
                reasoning=str(data.get("reasoning", "")),
                strategy=strategy,
            )
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            log.warning("Could not parse AI response as JSON (%s): %s", exc, text[:300])
            return TradeDecision.hold(f"unparseable AI response: {exc}")

    @staticmethod
    def _extract_json(text: str) -> dict:
        """The model is told to respond with ONLY JSON, but occasionally adds
        prose/markdown around or before it anyway. Try a straight parse first;
        if that fails, fall back to the first balanced {...} object found
        anywhere in the text rather than giving up and forcing a hold."""
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass
        start = text.find("{")
        if start == -1:
            raise json.JSONDecodeError("no JSON object found", text, 0)
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    return json.loads(text[start:i + 1])
        raise json.JSONDecodeError("no balanced JSON object found", text, start)
