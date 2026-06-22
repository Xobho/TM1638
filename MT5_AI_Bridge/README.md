# MT5 AI Bridge

A Python agent that connects to a **running MT5 terminal**, pulls live chart
and account data, sends it to Claude for analysis, and (optionally) places
real trades — separate from the MQL5 EA in [`../ExpertAdvisor`](../ExpertAdvisor).

This is an external process, not an Expert Advisor: it talks to MT5 through
the official [`MetaTrader5`](https://pypi.org/project/MetaTrader5/) Python
package, which requires the MT5 terminal to be installed and running on the
**same machine** (Windows natively, or Linux/macOS via Wine — the package
does not work over a remote connection to a terminal on another machine).

## How it works

1. Every `poll_seconds`, for each configured symbol, the bridge checks if a
   new candle has closed on the configured timeframe.
2. On a new candle, it pulls the last `bars` candles plus account/position
   state and sends them to Claude with a strict JSON-only response format:
   `action` (buy/sell/close/hold), `confidence`, `stop_loss`, `take_profit`,
   `reasoning`.
3. The decision passes through `RiskManager` (`mt5_ai_bridge/risk.py`) before
   anything touches the broker: minimum confidence, max open positions, max
   trades/day, max spread. A `buy`/`sell` with no `stop_loss` is rejected
   outright — no stop-loss, no trade.
4. Position size is computed from `risk.max_risk_percent_per_trade` of
   current equity and the stop-loss distance, via
   `MT5Client.lots_for_risk()`.
5. If `risk.dry_run: true` (**the default**), every decision is logged as
   "would send" with full details and nothing is sent to the broker. Only
   set `dry_run: false` once you've watched it run for a while.

## Setup

```bash
cd MT5_AI_Bridge
pip install -r requirements.txt
cp config.example.yaml config.yaml   # edit symbols/timeframe/risk to taste
export ANTHROPIC_API_KEY=sk-ant-...
```

`config.yaml` is gitignored — it's where your MT5 login (if needed) and risk
settings live, never commit it.

If MT5 is already running and logged into your account, leave
`mt5.login`/`password`/`server` blank in `config.yaml` — the bridge just
attaches to the running terminal. Fill them in only if you want this script
to log in itself.

Run a single test pass (no loop, exits after one check per symbol):

```bash
python run.py --once
```

Run continuously:

```bash
python run.py
```

## Volatility-spike trigger (catching fast intra-candle moves)

Normal analysis only runs once per closed candle — fine most of the time,
but it means a fast, news-driven sweep-and-reverse that fully plays out
*inside* one candle (common around high-impact news) can resolve before the
bridge ever looks at it again. `trading.volatility_trigger` in
`config.yaml` closes that gap:

```yaml
volatility_trigger:
  enabled: true
  check_seconds: 5          # how often to sample price
  window_seconds: 60        # look-back window for the move
  points: 150               # min move within that window to count as a spike
  cooldown_seconds: 120     # min time between two spike-triggered calls
```

Independently of the candle clock, the bridge samples price every
`check_seconds` and fires an immediate, out-of-cycle AI call the moment price
moves more than `points` within `window_seconds` — so a sudden spike gets
analyzed within seconds instead of waiting for the next candle close. The
`cooldown_seconds` prevents one sustained move from triggering repeated calls
back-to-back. This runs on top of, not instead of, the normal once-per-candle
analysis. Tune `points`/`window_seconds` per symbol — gold needs a much
larger point threshold than EURUSD to mean the same thing.

## Regime detection and performance memory (real adaptiveness, no fine-tuning)

The AI itself is stateless — each call starts fresh with no memory of past
decisions and the model's weights are never updated. Real, working
adaptiveness instead comes from two deterministic pieces that wrap the AI:

1. **`mt5_ai_bridge/regime.py`** computes a market-condition label —
   `trending`/`ranging` from ADX, `high`/`normal`/`low` from ATR percentile
   — purely from indicator math, no AI involved. Every signal and trade in
   the journal gets tagged with the regime active at that moment (e.g.
   `trending-highvol`).
2. **`mt5_ai_bridge/performance.py`** pulls rolling win-rate and average-R
   stats from `trade_journal.jsonl` — both overall for the symbol, and
   specifically for the *current* regime — and `agent.py` feeds that
   summary into every single AI call, alongside the candles. The system
   prompt in `ai_analyst.py` explicitly tells the model to use this as real
   feedback: tighten up if its recent record in the current regime is poor,
   don't over-trust a regime with only a handful of trades either way.

This means the AI's judgment each call is genuinely informed by its own
logged track record under similar conditions, even though there's no
gradient descent happening — it's feedback via context, not training.
`report.py`'s "BY MARKET REGIME" section is the same data in human-readable
form, showing which conditions the AI actually performs well or poorly in
over time — the basis for eventually deciding which decision logic (AI
judgment, or a coded rules-based strategy) should be trusted in which
regime, rather than running one approach blindly in all conditions.

## Reporting — what's actually working

Every decision the AI makes (including holds) and every trade outcome —
whether it's a real fill or just a dry-run "would-have" trade — is recorded
to `logs/trade_journal.jsonl`. `_check_open_trades()` in `agent.py` polls
the current price each cycle to detect when a virtual (dry-run) or real
position would have hit its SL/TP, and logs the result; real position
closes are confirmed against MT5's own deal history
(`MT5Client.closed_position_result`), not just inferred from price.

Run the report any time, while the bridge keeps running:

```bash
python report.py
```

It breaks down: signal distribution (buy/sell/hold counts), win rate and
average R multiple overall, by symbol, by the AI's own stated confidence
bucket, and by direction (buy vs. sell) — so you can see, for example,
whether the AI's "high confidence" calls actually win more than its
"medium confidence" ones, or whether it's better at one symbol/direction
than another. Use `--journal <path>` to point at a different journal file.

## Safety notes — read before setting `dry_run: false`

- **Start in `dry_run: true` and watch the logs** (`logs/bridge.log`) for at
  least several sessions before risking real money. Confirm the decisions it
  *would* have made line up with what you'd actually trade.
- MT5's own **AutoTrading** toggle and the account's algo-trading permission
  are independent of this script — even with `dry_run: false`, MT5 will
  reject orders if AutoTrading is off.
- `risk.max_daily_trades`, `risk.max_open_positions`, and
  `risk.max_risk_percent_per_trade` are hard caps enforced in
  `RiskManager` — tune them conservatively before going live, not after.
- The AI is given only the data explicitly passed to it (recent candles +
  account/position snapshot). It has no memory between calls and no access
  to news, fundamentals, or any data source beyond what `agent.py` sends it.
- This is independent from the MQL5 `MMBM_LiquiditySweep_EA` — the two do
  not currently share state, signals, or positions (separate `magic_number`
  recommended if running both on the same account).

## Files

| File | Purpose |
|---|---|
| `run.py` | CLI entry point |
| `mt5_ai_bridge/config.py` | Loads `config.yaml` |
| `mt5_ai_bridge/mt5_client.py` | MT5 terminal connection, rates/positions/orders |
| `mt5_ai_bridge/ai_analyst.py` | Builds the prompt, calls Claude, parses the JSON decision |
| `mt5_ai_bridge/risk.py` | All trade-approval guardrails in one place |
| `mt5_ai_bridge/agent.py` | Main loop tying the above together |

## Disclaimer

Nothing here is financial advice. This connects an LLM's output directly to
order placement on a live trading account — test thoroughly on a demo
account first, and never run unattended with `dry_run: false` without risk
limits you fully understand and accept.
