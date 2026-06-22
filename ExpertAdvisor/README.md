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

## Notes / disclaimer

This is a rules-based, mechanical interpretation of a discretionary visual
trading concept (swing/FVG detection uses simple fractal and 3-candle-gap
heuristics) — it will not perfectly match manual chart reading. **Backtest
and forward-test on a demo account before using real funds.** Nothing here
is financial advice.
