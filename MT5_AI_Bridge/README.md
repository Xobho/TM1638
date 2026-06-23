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

## ICT/SMC structure detection (giving the AI the EA's eyes)

The AI sees raw OHLC numbers, not a chart. Asking it to spot a liquidity
sweep, structure shift, or fair value gap by eyeballing 200 rows of numbers
every call is unreliable — so it tends to default to `hold`. Code is good at
exactly that mechanical pattern-spotting, so `mt5_ai_bridge/ict.py` runs a
*suite* of deterministic ICT/SMC strategy detectors every call and hands the
results to the AI as an `ict` feature block alongside the candles.

**Six strategies are evaluated each candle, in both directions:**

| `strategy` | What it detects |
|---|---|
| `liquidity_sweep_mss` | Sweep of swing liquidity → market-structure shift → fair-value-gap entry (the original MQL5 EA model). Reversal. |
| `order_block` | The last opposing candle before a break of structure; entry on the retrace into that order block. |
| `fair_value_gap` | A standalone unfilled 3-candle imbalance; entry on the retrace into the gap. |
| `breaker_block` | An order block that failed and flipped (price swept it and shifted structure the other way); entry on the retest. |
| `turtle_soup` | A false breakout of the prior N-bar range extreme that closes back inside (a liquidity grab); reversal. |
| `optimal_trade_entry` | The 0.62–0.79 fib retracement zone of the most recent impulse leg (ICT "OTE"). |

Each call's `ict` block contains:

- **`htf_bias`** — higher-timeframe directional bias (HH/HL → bullish,
  LH/LL → bearish, mixed → neutral), from `trading.htf_timeframe` (default H4).
- **`context`** — the recent dealing range: `price_zone`
  (premium/discount/equilibrium), the nearest swing high/low, and any
  `equal_highs`/`equal_lows` (resting liquidity pools price may draw toward).
- **`setups`** — a list of every setup the detectors currently see (both
  directions, all strategies). Each entry is tagged with its `strategy`,
  `direction`, and a `stage`: `ready` (price is at the point of interest now,
  actionable on a market order) or `forming` (valid structure, but price must
  still retrace into the zone). `liquidity_sweep_mss` reports its own
  progression — `sweep_only` → `mss_confirmed` → `ready`. Actionable
  (`ready`) setups are sorted to the front; each carries `suggested_entry` /
  `suggested_sl` / `suggested_tp` / `rr`.

**Which strategy did the AI actually use?** The AI's JSON response includes a
`strategy` field — the name of the detected setup it traded, `discretionary`
if it acted on its own read of the candles, or `null` for hold/close. That's
written to the journal on every signal and trade, so `report.py`'s
**BY ICT STRATEGY** section shows win rate and average R *per strategy* —
the whole point of running several at once is to learn from live data which
ones actually work, for this symbol, in which regime.

Crucially, **the AI is not forced to take any of these setups.** The system
prompt frames `setups` as several sets of eyes: multiple (even conflicting)
setups can be present at once, and it's the AI's job to judge which — if any —
deserves a trade given HTF bias, premium/discount location, regime, and its own
track record. It can fade a `ready` setup, or trade something none of the
detectors caught (`strategy: "discretionary"`). Since the bridge fills with
market orders, it's told to only act on a detected setup when price is already
at/near that setup's suggested entry, otherwise wait for the retracement. Tune
the detectors under `trading.ict` in `config.yaml` (swing size, min FVG size,
stop/zone buffer, HTF bias on/off).

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

## Backtesting (accumulating data faster than real time)

`backtest.py` replays historical candles through the same `AIAnalyst` the
live bridge uses, one closed-candle decision at a time, in chronological
order — so the regime/performance context at each simulated decision only
ever sees data that would actually have been available at that moment (no
lookahead). Results go to a **separate journal**
(`logs/backtest_journal.jsonl` by default) so they never mix with the live
bridge's own performance memory.

This makes real, billed Anthropic API calls — one per closed candle in the
requested window. It always prints a cost estimate first and requires
typing `y` to confirm (or pass `--yes` to skip the prompt) before spending
anything:

```bash
python backtest.py --symbol EURUSD --timeframe M15 --days 30
```

The estimate is a rough heuristic (chars/4 ≈ tokens, fixed $3/$15 per
million input/output tokens) — check the real rate for your model on
[the Anthropic pricing page](https://docs.anthropic.com/en/docs/about-claude/pricing)
before relying on it. As a reference point, 200-bar lookback windows on
`M15`: ~30 days ≈ 2,680 calls ≈ $50-55; ~7 days ≈ 470 calls ≈ $9-10.

Trade simulation fills at the close of the decision candle and resolves
SL/TP by scanning forward through subsequent historical bars — it does not
place anything on the broker. Run `python report.py --journal
logs/backtest_journal.jsonl` afterward to see the same win-rate/avg-R/regime
breakdown as live trading.

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
| `mt5_ai_bridge/ict.py` | Suite of deterministic ICT/SMC strategy detectors (sweep/MSS/FVG, order block, FVG, breaker, turtle soup, OTE) + bias/premium-discount context |
| `mt5_ai_bridge/agent.py` | Main loop tying the above together |
| `backtest.py` | Walk-forward backtest against historical candles, with a cost estimate gate before any API spend |

## Disclaimer

Nothing here is financial advice. This connects an LLM's output directly to
order placement on a live trading account — test thoroughly on a demo
account first, and never run unattended with `dry_run: false` without risk
limits you fully understand and accept.
