# MMBM Liquidity Sweep EA

An MT5 (MQL5) Expert Advisor implementing the Smart Money / ICT-style concept
shown in the reference charts: **Liquidity Sweep → Market Structure Shift (MSS)
→ Fair Value Gap (FVG) entry**, with higher-timeframe (HTF) structure used as a
directional bias filter.

File: [`MMBM_LiquiditySweep_EA.mq5`](MMBM_LiquiditySweep_EA.mq5)

## Strategy logic

1. **HTF bias** (`InpHTF_Timeframe`, default H4): the last two confirmed swing
   highs/lows are compared. Higher-high + higher-low → bullish bias (only buy
   setups are tracked). Lower-high + lower-low → bearish bias. Mixed structure
   → both directions allowed.
2. **Liquidity sweep** (entry timeframe, `InpLTF_Timeframe`, default M15): a
   candle wicks through a prior confirmed swing low (bullish case) or swing
   high (bearish case) and closes back inside it — the classic stop-hunt /
   SSL or BSL grab (the "SMR" / sweep in the MMBM diagram).
3. **Market Structure Shift (MSS)**: after the sweep, price must close beyond
   the most recent opposing minor swing point (the last lower-high before the
   sweep low, or last higher-low before the sweep high) within
   `InpMaxBarsAfterSweep` bars.
4. **FVG / point of interest**: the EA scans the impulse leg between the
   sweep and the MSS bar for a 3-candle Fair Value Gap, picking the one
   closest to current price (the re-accumulation/re-distribution POI in the
   diagram). A limit order is placed inside it — either at the midpoint
   (`InpEntryAtMidpoint = true`, the ICT "consequent encroachment") or at the
   far edge of the gap (more favorable price, lower fill probability).
5. **Risk**: stop loss sits beyond the sweep extreme plus a buffer
   (`InpSweepBufferPoints`); take profit targets the next external liquidity
   pool (opposing swing point) found ahead of price, falling back to a fixed
   `InpFallbackRR` reward:risk if none is found. Position size is derived
   from `InpRiskPercent` of account equity.
6. Pending orders that aren't filled within `InpPendingExpiryBars` LTF bars
   are cancelled and the setup resets.

## Chart visuals

Every stage of the setup is drawn live on the chart (toggle with
`InpShowDrawings`):

| Object | What it shows |
|---|---|
| Arrow + dotted ray | The liquidity sweep candle and the swept swing level (SSL/BSL) |
| Blue segment, "MSS" | The market structure shift break level |
| Filled rectangle, "FVG / POI" | The fair value gap used as the entry zone |
| Dashed line, "Entry" | The pending limit order price |
| Red line, "SL" | Stop loss, beyond the sweep extreme |
| Green line, "TP" | Take profit, at the next liquidity pool (or fallback RR) |

Objects are named `MMBM_<BUY|SELL>_<setupId>_...`, so each setup's drawings
are independent and won't collide. By default (`InpClearInvalidatedSteps =
true`) a setup's drawings are removed automatically if it never produces a
filled trade (sweep without MSS, no FVG found, order expires unfilled) — so
the chart only accumulates a permanent visual record for setups that actually
traded. Set it to `false` to keep every attempt, including failed ones, for
review. A one-line live status (`InpShowStatusComment`) is also shown via
`Comment()` in the chart's top-left corner indicating each direction's
current stage (idle / waiting for MSS / pending order placed).

## Seeing history

By default the EA only draws a setup once it actually happens live, going
forward from the moment it's attached — it won't retroactively show what
happened before that. To see the last few days of completed setups
immediately:

- Set `InpHistoryDays` (default 5) to however many days back you want
  scanned. `0` disables it.
- The scan runs once, automatically, in `OnInit` — i.e. the moment you
  attach the EA, or any time you open its Inputs dialog and click OK (MT5
  re-runs `OnInit` whenever inputs change, so tweaking `InpHistoryDays` and
  hitting OK re-scans immediately without removing/re-adding the EA).
- Historical setups are drawn with every stage — sweep, MSS, FVG, and the
  entry/SL/TP it *would have* taken — using the exact same detection logic
  as the live state machine, just walked forward through past bars instead
  of bar-by-bar in real time. Their entry/SL/TP lines are bounded to a fixed
  window after the setup (they don't ray out to the current bar) so they
  don't visually clash with live ones.
- Historical objects are named `MMBM_HIST_<BUY|SELL>_<id>_...` (vs.
  `MMBM_<BUY|SELL>_<id>_...` for live ones), so the two sets never collide
  and `InpDeleteObjectsOnRemove` clears both.
- Historical setups are **not** filtered by HTF bias and never place real
  orders — they're for visual review only.

## Key inputs

| Input | Purpose |
|---|---|
| `InpHTF_Timeframe` / `InpLTF_Timeframe` | Bias timeframe / entry timeframe |
| `InpSwingLeftRight` | Bars each side required to confirm a fractal swing point |
| `InpRequireHTFBias` | Disable to trade both directions regardless of HTF structure |
| `InpMaxBarsAfterSweep` | Sweep→MSS confirmation window |
| `InpMinFVGSizePoints` | Minimum imbalance size to be considered tradable |
| `InpRiskPercent` | Risk per trade as % of equity |
| `InpMaxSpreadPoints` | Spread filter at order placement time |
| `InpShowDrawings` | Master toggle for all chart objects |
| `InpClearInvalidatedSteps` | Auto-remove drawings for setups that never filled |
| `InpDeleteObjectsOnRemove` | Wipe all EA drawings when removed from the chart |
| `InpHistoryDays` | Days of history to scan and draw on init (0 = off) |

## Notes / disclaimer

This is a rules-based, mechanical interpretation of a discretionary visual
trading concept (swing/FVG detection uses simple fractal and 3-candle-gap
heuristics) — it will not perfectly match manual chart reading. **Backtest
and forward-test on a demo account before using real funds.** Nothing here
is financial advice.
