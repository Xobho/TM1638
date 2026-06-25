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
   Each FVG also carries a **tested** flag — true if price already wicked
   back into the zone at some point between the FVG forming and the MSS
   confirming (a used-up zone, drawn with a dotted outline and "(tested)" in
   its label instead of a solid one). `InpSkipTestedFVG` (default off) can
   skip placing the order entirely on a tested FVG, for a stricter,
   fresh-zones-only filter.
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
| Arrow + dotted ray | The liquidity sweep candle. The dotted ray now runs from the original swing point that formed the liquidity all the way to the candle that swept it, so it's clear *which* level got hunted, not just where the sweep happened |
| Blue segment, "MSS" | The market structure shift break level |
| Filled rectangle, "FVG / POI" | The fair value gap used as the entry zone — bounded tightly to the actual 3-candle gap, not stretched across the whole impulse leg |
| Dashed line, "Entry" | The pending limit order price. Stops where it was actually filled (or at expiry if it never filled), rather than raying on forever |
| Red line, "SL" | Stop loss, beyond the sweep extreme. Starts at the fill and stops at the bar the trade closed |
| Green line, "TP" | Take profit, at the next liquidity pool (or fallback RR). Same start/stop behavior as SL |

**Drawings only appear when the attached chart's period matches
`InpLTF_Timeframe`.** The strategy itself always operates on
`InpLTF_Timeframe` data regardless of which chart the EA is running on, but
the sweep/MSS/FVG/entry objects are sized to LTF bars — viewed on a higher
timeframe chart (e.g. H4 while the strategy runs on M15) they'd be crammed
into a tiny sliver of a single H4 candle and look like overlapping clutter.
If you attach the EA to a chart on a different period, trading still runs
normally, but you'll see a "chart/strategy timeframe mismatch" warning in
the status comment and dashboard instead of garbled drawings — switch the
chart to `InpLTF_Timeframe` to see them.

Objects are named `MMBM_<BUY|SELL>_<setupId>_...`, so each setup's drawings
are independent and won't collide. By default (`InpClearInvalidatedSteps =
true`) a setup's drawings are removed automatically if it never produces a
filled trade (sweep without MSS, no FVG found, order expires unfilled) — so
the chart only accumulates a permanent visual record for setups that actually
traded. Set it to `false` to keep every attempt, including failed ones, for
review. A one-line live status (`InpShowStatusComment`) is also shown via
`Comment()` in the chart's top-left corner indicating each direction's
current stage (idle / waiting for MSS / pending order placed / in trade).

## Dashboard

A fixed info panel in the top-left corner (toggle with `InpShowDashboard`,
on by default) shows, refreshed every tick:

- Trading mode (auto-trade vs. signal-only) and whether the chart's
  timeframe matches the strategy's `InpLTF_Timeframe`
- HTF bias (buy/sell allowed or blocked)
- Each direction's current state (idle / waiting for MSS / pending order /
  in trade)
- Account equity and balance, and the configured risk per trade
- Open positions for this EA (count, lots, floating P/L)
- Current spread vs. the spread filter

Unlike `Comment()`, this is a real chart object panel (`OBJ_RECTANGLE_LABEL`
+ `OBJ_LABEL` rows) so it persists independently of any other comment usage
and is meant to be the primary live-monitoring view for running this as a
supervised live-trading EA.

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
- The history scanner advances past a sweep candle as soon as one is found,
  even if the later MSS or FVG search for that sweep fails, instead of only
  advancing on full success. This prevents an adjacent swing point inside the
  same consolidation from re-detecting the same sweep and drawing
  near-duplicate Sweep/MSS/FVG labels on top of each other.

## Live trading

The EA places real pending orders (`BuyLimit`/`SellLimit`) the moment a setup
completes (sweep → MSS → FVG), sized by `InpRiskPercent` of equity. Two
things are required for it to actually trade:

1. **`InpAutoTrade = true`** (default). Set it to `false` to switch the EA
   into signal/drawing-only mode: every completed setup is still drawn in
   full (sweep, MSS, FVG, entry/SL/TP) but no order is sent — useful for
   watching the strategy call setups live before risking money.
2. **MT5's "AutoTrading" button** (top toolbar) must be enabled, and the EA
   must be allowed to trade in its Common tab settings — this is a
   terminal-level switch independent of `InpAutoTrade` and MT5 will silently
   refuse to send orders without it.

The current mode is shown on the first line of the on-chart status comment
(`InpShowStatusComment`).

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
| `InpAutoTrade` | `true` = place real orders, `false` = draw setups only, no orders sent |
| `InpShowDrawings` | Master toggle for all chart objects (only renders when chart period == `InpLTF_Timeframe`) |
| `InpShowDashboard` | Toggle the live info panel (account/risk/setup/position state) |
| `InpClearInvalidatedSteps` | Auto-remove drawings for setups that never filled |
| `InpDeleteObjectsOnRemove` | Wipe all EA drawings when removed from the chart |
| `InpHistoryDays` | Days of history to scan and draw on init (0 = off) |
| `InpSkipTestedFVG` | Skip the entry if the FVG was already wicked back into before MSS confirmed |

## Ideas to make the strategy more effective

Not implemented yet — listed here as candidates if you want to take this
further:

- **Killzone / session time filter.** Only arm the state machine during
  specific session windows (e.g. London/NY open) instead of 24/5 — ICT
  liquidity sweeps are far more reliable inside known killzones than at
  random times.
- **Displacement filter on the MSS leg.** Require the MSS candle (or the
  leg into it) to be a strong-bodied, above-average-range candle, not just
  any close beyond the reference swing — filters out weak/grindy breaks.
- **Equal highs/lows as additional liquidity pools.** Current sweep
  detection only uses fractal swing points; adding equal-highs/equal-lows
  clusters as extra liquidity targets (common ICT POI) would catch more
  valid setups and better TP targets.
- **Daily/weekly bias layer above the current H4 bias** for a stronger
  top-down directional filter.
- **Partial take-profit / breakeven management** once price reaches a
  first liquidity pool, instead of one fixed TP.
- **Max daily risk / max trades per day guard** to cap drawdown from a bad
  session.
- **News/high-impact-event filter** to avoid placing pending orders into
  known volatility spikes.

## Notes / disclaimer

This is a rules-based, mechanical interpretation of a discretionary visual
trading concept (swing/FVG detection uses simple fractal and 3-candle-gap
heuristics) — it will not perfectly match manual chart reading. **Backtest
and forward-test on a demo account before using real funds.** Nothing here
is financial advice.

---

# MMBM ICT Suite EA (7 strategies)

File: [`MMBM_ICT_Suite_EA.mq5`](MMBM_ICT_Suite_EA.mq5)

The single-strategy EA above implements one play (sweep → MSS → FVG) with a
full pending-order state machine and history scan. The **Suite EA** is the
chart counterpart of the Python bridge's `ict.py`: it evaluates a whole
**suite of seven ICT strategies** every new bar, for both directions, draws
each detected setup live, and can optionally trade the best "ready" one. It's
a deliberately simpler *detect-and-draw-per-bar* design (no per-strategy
pending-order lifecycle), so it's easy to read and tune as you go.

## The seven strategies

| Code | Strategy | Entry idea |
|---|---|---|
| `SWEEP` | Liquidity Sweep + MSS | Wick sweeps a swing & closes back inside → market-structure shift → entry in the impulse-leg FVG. Stages: swept → mss → ready |
| `OB` | Order Block | Last opposing candle before a break of structure; retrace into it |
| `FVG` | Fair Value Gap | Standalone unfilled 3-candle imbalance; retrace into the gap |
| `BRK` | Breaker Block | Order block of a failed sweep that flipped with structure; retest |
| `TS` | Turtle Soup | False breakout of the prior N-bar range extreme that closes back inside |
| `OTE` | Optimal Trade Entry | The 0.62–0.79 fib retracement zone of the most recent impulse leg |
| `CONT` | Continuation Retest | A broken swing level retested from the breakout side — a trend-*continuation* entry (the only non-reversal of the seven) |

Each strategy can be toggled independently (`InpEnableSweep`, `InpEnableOB`,
…). All detection runs on `InpLTF_Timeframe`; HTF bias (`InpHTF_Timeframe`)
gates which directions are shown exactly as in the single-strategy EA.

Toggling a strategy (or any input) takes effect immediately — `OnInit` runs
a full live rescan as soon as you click OK, rather than waiting for the next
new bar to repopulate the chart.

## Stage and "tested"

Every setup carries two key attributes shown in its label and the dashboard:

- **stage**: `ready` (price is in the zone / at the level *now* — actionable
  on a market order) vs `forming` (structure is valid but price must still
  retrace into it). `SWEEP` also shows its progression `swept` → `mss` →
  `ready`.
- **tested**: `true` if price has already wicked back into the zone since it
  formed (even without closing inside). A *tested* zone is a weaker, used-up
  version of the setup — it's drawn with a dotted (rather than solid) outline,
  and `InpSkipTestedSetups` (default on) keeps auto-trade from entering one.

## Chart visuals

Drawings only render when the chart period matches `InpLTF_Timeframe` (same
reason as the other EA — the objects are LTF-bar-sized). Each (strategy,
direction) slot is redrawn each bar and named
`ICTS_<CODE>_<B|S>_...`, so at most 14 setups show at once, replaced in place:

- **Filled rectangle** for zone strategies (`OB`/`FVG`/`BRK`/`OTE`/ready
  `SWEEP`), bounded to the zone and extended `InpZoneExtendBars` to the right.
- **Horizontal line** for level strategies (`TS`, `CONT`, and pre-ready
  `SWEEP` stages).
- A **label** with the strategy code, stage, `(tested)`, and reward:risk.
- **Entry / SL / TP lines** — only for `ready`, actionable setups (toggle with
  `InpDrawTradeLines`) to keep the chart readable.

Bullish setups use `InpColorBull`, bearish use `InpColorBear`.

## Dashboard

A top-left panel (`InpShowDashboard`) lists mode, chart/strategy TF match,
HTF bias, then **one row per strategy** showing each direction's live state
(e.g. `OB  B READY*  S form` — the `*` marks tested), plus account equity,
open positions for this EA, and spread.

## Trading

`InpAutoTrade` defaults to **false** (scan/draw only — no orders). When on,
the EA picks the single best actionable setup — preferring untested ones, then
the highest reward:risk — and sends a **market order**, one position at a time
per magic number, sized by `InpRiskPercent` and gated by `InpMaxSpreadPoints`.
As always, MT5's terminal-level "AutoTrading" button must also be enabled.

`InpTriggerMode` decides *when* a setup becomes actionable:

- **`TRIGGER_TOUCH`** (default) — checked **every tick**. The instant live
  price (including just a wick) reaches into the zone band
  (`zoneLow .. zoneHigh` ± `InpSweepBufferPoints`), the trade fires. Catches
  fast touches that reverse before the candle closes. The setups themselves are
  still *detected* only on closed bars (no repaint) — only the entry trigger is
  intrabar.
- **`TRIGGER_CLOSE`** — checked only on **bar close**. A candle must actually
  *close* inside the zone (`stage == ready`) before the trade fires. Fewer,
  cleaner entries; ignores wick-and-reverse touches. This was the original
  behavior.

The active mode shows on the dashboard's Mode line, e.g. `AUTO-TRADE (touch)`.

This is intentionally a simpler execution model than the other EA's pending
limits — it's meant as a starting point to forward-test the suite on a demo
and adjust. Backtest before risking real funds.

### Context filters

The trigger decides *when* to enter; these gates decide *whether a setup is
eligible at all*. They sit on top of every strategy and stop the EA taking a
pattern with no surrounding ICT context (e.g. a stop-hunt entry in the wrong
half of the range, or in a dead session). Both are on by default:

- **Premium / Discount** (`InpUsePremiumDiscount`): a dealing range is built
  from the high/low of the last `InpPDRangeBars` bars (default 50); its 50%
  is equilibrium. **Buys are only allowed at/below equilibrium (discount),
  sells at/above (premium)** — the core ICT rule that you buy cheap and sell
  expensive within the range. Setups that fail this are still drawn, just not
  traded.
- **Killzones** (`InpUseKillzones`): trades fire only inside two configurable
  session windows — `InpKZ1StartHour..InpKZ1EndHour` (London) and
  `InpKZ2StartHour..InpKZ2EndHour` (New York). **Hours are broker/SERVER
  time**, not your local or EST time, so set them to match your broker (the
  dashboard shows the current server time next to `KZ IN`/`KZ OUT` to help you
  calibrate). End hour is exclusive; a window may wrap past midnight.

The dashboard's `Ctx` line shows both at a glance, e.g.
`Ctx: KZ IN 09:42 | Discount` (turns orange when the session is closed).

## Seeing history

Like the single-strategy EA, this one can backfill the chart with completed
setups from before it was attached:

- `InpHistoryDays` (default 5, `0` disables it) and `InpMaxHistoricalPerSetup`
  (default 5) control how far back to scan and how many historical finds to
  draw per strategy+direction (14 slots total) — that cap, plus only drawing
  the zone/level + a label (no entry/SL/TP lines), is what keeps the scan from
  creating hundreds of objects across all seven strategies.
- The scan runs **once**, in `OnInit` (on attach, or whenever you open Inputs
  and click OK — MT5 re-fires `OnInit` on any input change) — never per-tick,
  so it can't slow down live chart updates. It fetches the historical bars
  with a single `CopyRates` call, builds one descending copy of that range,
  and then walks it bar-by-bar feeding each of the seven detectors a cheap
  slice of that one array — no repeated history fetches per strategy.
  Only `stage == "ready"` finds are drawn, and a persisting setup (same zone,
  many consecutive "ready" bars) only counts once.
- Historical objects use the `ICTS_HIST_<CODE>_<B|S>_<n>_` prefix (vs.
  `ICTS_<CODE>_<B|S>_` for live ones) so the two never collide, and are drawn
  as an unfilled outline (dotted if `tested`) to stay visually distinct from
  the live, filled zones. Because there's no fill behind them, historical
  zones use their own brighter colors — `InpColorHistBull` (default
  `clrDeepSkyBlue`) and `InpColorHistBear` (default `clrMagenta`) — plus a
  thicker line and slightly larger label than the live zones, which can
  afford paler `InpColorBull`/`InpColorBear` colors since their fill carries
  the contrast.
- Like the live scanner, historical setups are **not** filtered by HTF bias
  and never place real orders — visual review only.

