//+------------------------------------------------------------------+
//|                                    MMBM_LiquiditySweep_EA.mq5    |
//|                                                                  |
//| Strategy implemented (Smart Money / ICT concepts):               |
//|   1. HTF structure (swing highs/lows) sets directional bias.     |
//|   2. On the entry timeframe, price sweeps internal/external      |
//|      liquidity (a swing high/low) with a wick and rejects.       |
//|   3. A Market Structure Shift (MSS) confirms the reversal by     |
//|      breaking the most recent opposing minor swing.              |
//|   4. The Fair Value Gap (FVG) left behind during the MSS impulse |
//|      leg becomes the point of interest (POI) for re-entry        |
//|      (the "discount"/"premium" array, i.e. HTF POI / IRL).       |
//|   5. Entry is a limit order inside that FVG, stop loss beyond    |
//|      the liquidity sweep extreme, take profit at the next        |
//|      external liquidity (draw on liquidity) or a fixed RR.       |
//|                                                                  |
//| Every stage is drawn live on the chart: sweep marker + swept     |
//| liquidity level, MSS break level, FVG zone, and entry/SL/TP      |
//| lines once a pending order is placed.                            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.30"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- inputs -----------------------------------------------------------
input ENUM_TIMEFRAMES InpHTF_Timeframe        = PERIOD_H4;   // Higher timeframe used for directional bias
input ENUM_TIMEFRAMES InpLTF_Timeframe        = PERIOD_M15;  // Entry timeframe (sweep / MSS / FVG)
input int             InpSwingLeftRight       = 3;           // Bars each side required to confirm a swing point
input bool            InpRequireHTFBias       = true;        // Only trade in the direction of HTF structure
input int             InpMaxBarsAfterSweep    = 25;          // Max LTF bars allowed for MSS to occur after a sweep
input int             InpMaxBarsForFVGSearch  = 15;          // How far back from the MSS bar to search for the entry FVG
input double          InpMinFVGSizePoints     = 30;          // Minimum FVG size (points) to be tradable
input bool            InpEntryAtMidpoint      = true;        // true = limit @ 50% of FVG, false = limit @ far edge of FVG
input bool            InpSkipTestedFVG        = false;       // Skip the entry if price already wicked back into the FVG before MSS confirmed (a used-up zone)
input double          InpSweepBufferPoints    = 20;          // Extra buffer beyond the sweep extreme for the stop loss
input double          InpRiskPercent          = 1.0;         // Risk per trade, % of account equity
input double          InpFallbackRR           = 2.0;         // Reward:Risk used when no liquidity target is found
input int             InpPendingExpiryBars    = 20;          // Cancel an unfilled pending order after N LTF bars
input int             InpMaxSpreadPoints      = 30;          // Skip new entries if spread exceeds this
input ulong           InpMagicNumber          = 19380001;    // Magic number for this EA's orders
input bool            InpOneSetupAtATime      = true;        // Only manage one active setup per direction at a time
input bool            InpAutoTrade            = true;        // true = place real pending orders. false = signal/drawing only, no orders sent

input group "=== Chart Visuals ==="
input bool   InpShowDrawings        = true;         // Draw sweep/MSS/FVG/entry/SL/TP objects on the chart
input bool   InpClearInvalidatedSteps = true;        // Remove drawings for setups that fail before producing a trade
input bool   InpDeleteObjectsOnRemove = false;       // Wipe all EA drawings when the EA is removed from the chart
input bool   InpShowStatusComment   = true;          // Show a live status line via Comment()
input bool   InpShowDashboard       = true;          // Show the on-chart info panel (account/risk/setup/position state)
input color  InpColorSweepBull      = clrDodgerBlue; // Bullish sweep marker / swept level color
input color  InpColorSweepBear      = clrOrange;     // Bearish sweep marker / swept level color
input color  InpColorMSS            = clrBlue;       // MSS break level color
input color  InpColorFVGBull        = clrAqua;       // Bullish FVG zone fill color
input color  InpColorFVGBear        = clrLightPink;  // Bearish FVG zone fill color
input color  InpColorEntry          = clrGoldenrod;  // Entry line color
input color  InpColorSL             = clrRed;        // Stop loss line color
input color  InpColorTP             = clrLimeGreen;  // Take profit line color

input group "=== History ==="
input int    InpHistoryDays         = 5;             // Scan and draw completed setups from the past N days (0 = off)
input bool   InpHistoryComputeTPviaFallbackOnly = false; // true = always use fallback RR for historical TP, ignore liquidity target

//--- bookkeeping --------------------------------------------------------
enum SetupState
  {
   STATE_IDLE,         // looking for a liquidity sweep
   STATE_WAIT_MSS,     // sweep found, waiting for market structure shift
   STATE_WAIT_FILL,    // MSS confirmed, pending limit order placed at FVG
   STATE_IN_TRADE      // pending order filled, position open and being tracked until close
  };

struct Setup
  {
   SetupState state;
   bool       bullish;
   bool       isHistorical;
   int        setupId;
   double     sweepExtreme;    // price of the liquidity sweep wick
   double     liquidityLevel;  // the swing price that was swept
   datetime   liquidityTime;   // bar time of the original swing point that was later swept
   datetime   sweepTime;       // bar time of the sweep candle (stable across re-copies of rates[])
   datetime   mssTime;         // bar time of the MSS confirmation candle
   double     mssLevel;        // the price level broken to confirm MSS
   double     fvgHigh;
   double     fvgLow;
   datetime   fvgTimeLeft;     // time of the older of the two outer FVG candles
   datetime   fvgTimeRight;    // time of the newer of the two outer FVG candles
   bool       tested;          // price already wicked back into the FVG since it formed (a used-up zone)
   ulong      pendingTicket;
   int        pendingPlacedBar;
  };

Setup g_bull, g_bear;
int   g_setupCounter = 0;

CTrade        g_trade;
CSymbolInfo   g_symbol;

datetime g_lastLTFBarTime = 0;
bool     g_htfBullBias = true;
bool     g_htfBearBias = true;

#define OBJ_PREFIX "MMBM_"
#define DASH_PREFIX "MMBM_DASH_"

//+------------------------------------------------------------------+
int OnInit()
  {
   ZeroMemory(g_bull);
   ZeroMemory(g_bear);
   g_bull.bullish = true;
   g_bear.bullish = false;
   g_bull.state   = STATE_IDLE;
   g_bear.state   = STATE_IDLE;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   if(!g_symbol.Name(_Symbol))
      return INIT_FAILED;

   if(!InpShowDashboard)
      DeleteObjectsByPrefix(DASH_PREFIX);

   if(DrawingsAllowed() && InpHistoryDays > 0)
      ScanHistory();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| The EA's strategy logic always runs on InpLTF_Timeframe data     |
//| regardless of which chart it's attached to, but the chart-object |
//| drawings are anchored to LTF bar widths/positions - if the chart |
//| is showing a different period (e.g. H4) those tiny LTF-sized     |
//| objects get crammed together and look like overlapping clutter.  |
//| So drawings are only shown when the chart period matches.        |
//+------------------------------------------------------------------+
bool DrawingsAllowed()
  {
   return InpShowDrawings && (_Period == InpLTF_Timeframe);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpDeleteObjectsOnRemove)
      DeleteObjectsByPrefix(OBJ_PREFIX);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_symbol.RefreshRates();

   datetime curBarTime = iTime(_Symbol, InpLTF_Timeframe, 0);
   bool newBar = (curBarTime != g_lastLTFBarTime);
   if(newBar)
      g_lastLTFBarTime = curBarTime;

   ManagePendingExpiry(newBar);

   if(newBar)
     {
      GetHTFBias(g_htfBullBias, g_htfBearBias);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(_Symbol, InpLTF_Timeframe, 1, 200, rates);
      if(copied >= 2 * InpSwingLeftRight + 10)
        {
         if(g_htfBullBias)
            ProcessSetup(g_bull, rates, copied);
         if(g_htfBearBias)
            ProcessSetup(g_bear, rates, copied);
        }
     }

   // dashboard/comment refresh every tick (cheap) so equity/P&L/spread stay live
   if(InpShowStatusComment)
      UpdateStatusComment(g_htfBullBias, g_htfBearBias);
   if(InpShowDashboard)
      UpdateDashboard(g_htfBullBias, g_htfBearBias);
  }

//+------------------------------------------------------------------+
//| HTF structure (HH/HL vs LH/LL) -> directional bias                |
//+------------------------------------------------------------------+
void GetHTFBias(bool &bullBias, bool &bearBias)
  {
   bullBias = true;
   bearBias = true;
   if(!InpRequireHTFBias)
      return;

   MqlRates htf[];
   ArraySetAsSeries(htf, true);
   int n = CopyRates(_Symbol, InpHTF_Timeframe, 1, 300, htf);
   if(n < 2 * InpSwingLeftRight + 10)
      return;

   double swingHighs[]; double swingLows[];
   ArrayResize(swingHighs, 0); ArrayResize(swingLows, 0);

   for(int i = n - InpSwingLeftRight - 1; i >= InpSwingLeftRight; i--)
     {
      if(IsSwingHigh(htf, i, InpSwingLeftRight))
        {
         int sz = ArraySize(swingHighs);
         ArrayResize(swingHighs, sz + 1);
         swingHighs[sz] = htf[i].high;
        }
      if(IsSwingLow(htf, i, InpSwingLeftRight))
        {
         int sz = ArraySize(swingLows);
         ArrayResize(swingLows, sz + 1);
         swingLows[sz] = htf[i].low;
        }
      if(ArraySize(swingHighs) >= 2 && ArraySize(swingLows) >= 2)
         break;
     }

   if(ArraySize(swingHighs) < 2 || ArraySize(swingLows) < 2)
      return; // not enough structure -> stay neutral (both true)

   bool higherHigh = swingHighs[0] > swingHighs[1];
   bool higherLow  = swingLows[0]  > swingLows[1];
   bool lowerHigh  = swingHighs[0] < swingHighs[1];
   bool lowerLow   = swingLows[0]  < swingLows[1];

   if(higherHigh && higherLow)
     {
      bullBias = true;
      bearBias = false;
     }
   else if(lowerHigh && lowerLow)
     {
      bullBias = false;
      bearBias = true;
     }
   // else: mixed structure -> remain neutral, both directions allowed
  }

//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[], int idx, int k)
  {
   for(int j = 1; j <= k; j++)
     {
      if(idx - j < 0 || idx + j >= ArraySize(r))
         return false;
      if(r[idx - j].high >= r[idx].high || r[idx + j].high >= r[idx].high)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool IsSwingLow(const MqlRates &r[], int idx, int k)
  {
   for(int j = 1; j <= k; j++)
     {
      if(idx - j < 0 || idx + j >= ArraySize(r))
         return false;
      if(r[idx - j].low <= r[idx].low || r[idx + j].low <= r[idx].low)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Main per-direction state machine                                  |
//+------------------------------------------------------------------+
void ProcessSetup(Setup &s, const MqlRates &rates[], int total)
  {
   if(InpOneSetupAtATime && (s.state == STATE_WAIT_FILL))
      return; // already have a pending order working for this direction

   if(s.state == STATE_IDLE)
     {
      int sweepIdx; double sweepPrice; double liquidityLevel; datetime liquidityTime;
      if(FindLiquiditySweep(rates, total, s.bullish, sweepIdx, sweepPrice, liquidityLevel, liquidityTime))
        {
         s.state          = STATE_WAIT_MSS;
         s.setupId         = ++g_setupCounter;
         s.sweepTime       = rates[sweepIdx].time;
         s.sweepExtreme    = sweepPrice;
         s.liquidityLevel  = liquidityLevel;
         s.liquidityTime   = liquidityTime;
         s.mssTime         = 0;

         if(DrawingsAllowed())
            DrawSweep(s);
        }
      return;
     }

   if(s.state == STATE_WAIT_MSS)
     {
      int sweepIdx = -1;
      for(int i = 0; i < total; i++)
         if(rates[i].time == s.sweepTime) { sweepIdx = i; break; }

      // sweepIdx grows (bar gets "older", since array is series) as new bars form;
      // bail out if MSS hasn't happened within the allowed window, or if the sweep
      // bar has scrolled out of the buffer entirely.
      if(sweepIdx < 0 || sweepIdx > InpMaxBarsAfterSweep)
        {
         ResetSetup(s, InpClearInvalidatedSteps);
         return;
        }

      int mssIdx; double mssLevel;
      if(FindMarketStructureShift(rates, total, s.bullish, sweepIdx, mssIdx, mssLevel))
        {
         s.state    = STATE_WAIT_FILL;
         s.mssTime  = rates[mssIdx].time;
         s.mssLevel = mssLevel;

         if(DrawingsAllowed())
            DrawMSS(s);

         double fvgHigh, fvgLow; datetime fvgTimeLeft, fvgTimeRight;
         if(FindEntryFVG(rates, sweepIdx, mssIdx, s.bullish, fvgHigh, fvgLow, fvgTimeLeft, fvgTimeRight))
           {
            s.fvgHigh     = fvgHigh;
            s.fvgLow      = fvgLow;
            s.fvgTimeLeft  = fvgTimeLeft;
            s.fvgTimeRight = fvgTimeRight;

            int fvgIdx = -1;
            for(int t = 0; t < total; t++)
               if(rates[t].time == fvgTimeRight) { fvgIdx = t; break; }
            s.tested = ZoneTested(rates, fvgIdx, fvgLow, fvgHigh, g_symbol.Point(), InpSweepBufferPoints);

            if(DrawingsAllowed())
               DrawFVG(s);

            PlacePendingOrder(s, rates, total);
           }
         else
           {
            ResetSetup(s, InpClearInvalidatedSteps); // no usable FVG/POI -> abandon this setup
           }
        }
      return;
     }
  }

//+------------------------------------------------------------------+
//| Liquidity sweep: a wick pierces a prior swing low (bullish) or    |
//| swing high (bearish) and the candle closes back inside.           |
//+------------------------------------------------------------------+
bool FindLiquiditySweep(const MqlRates &r[], int total, bool bullish, int &sweepIdx, double &sweepPrice, double &liquidityLevel, datetime &liquidityTime)
  {
   int k = InpSwingLeftRight;
   // look for the most recent fully-formed swing point, then check if a later,
   // more recent candle has swept through it and closed back inside.
   for(int i = k + 1; i < total - k; i++)
     {
      if(bullish && IsSwingLow(r, i, k))
        {
         double level = r[i].low;
         for(int j = i - k - 1; j >= 0; j--)
           {
            if(r[j].low < level && r[j].close > level)
              {
               sweepIdx       = j;
               sweepPrice     = r[j].low;
               liquidityLevel = level;
               liquidityTime  = r[i].time;
               return true;
              }
           }
        }
      if(!bullish && IsSwingHigh(r, i, k))
        {
         double level = r[i].high;
         for(int j = i - k - 1; j >= 0; j--)
           {
            if(r[j].high > level && r[j].close < level)
              {
               sweepIdx       = j;
               sweepPrice     = r[j].high;
               liquidityLevel = level;
               liquidityTime  = r[i].time;
               return true;
              }
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Market Structure Shift: price closes beyond the most recent       |
//| opposing minor swing formed between the sweep and now.            |
//+------------------------------------------------------------------+
bool FindMarketStructureShift(const MqlRates &r[], int total, bool bullish, int sweepIdx, int &mssIdx, double &mssLevel)
  {
   int k = InpSwingLeftRight;
   // find the most recent minor swing high (bullish case) / swing low (bearish case)
   // that formed after the sweep, then see if price has closed beyond it.
   double refLevel = 0;
   bool   found     = false;

   for(int i = sweepIdx - k; i >= k; i--)
     {
      if(bullish && IsSwingHigh(r, i, k))
        {
         refLevel = r[i].high;
         found = true;
         break;
        }
      if(!bullish && IsSwingLow(r, i, k))
        {
         refLevel = r[i].low;
         found = true;
         break;
        }
     }
   if(!found)
      return false;

   for(int j = sweepIdx - 1; j >= 0; j--)
     {
      if(bullish && r[j].close > refLevel)
        {
         mssIdx   = j;
         mssLevel = refLevel;
         return true;
        }
      if(!bullish && r[j].close < refLevel)
        {
         mssIdx   = j;
         mssLevel = refLevel;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Fair Value Gap (3-candle imbalance) inside the impulse leg that   |
//| produced the MSS - the re-entry point of interest (POI).         |
//+------------------------------------------------------------------+
bool FindEntryFVG(const MqlRates &r[], int sweepIdx, int mssIdx, bool bullish, double &fvgHigh, double &fvgLow, datetime &fvgTimeLeft, datetime &fvgTimeRight)
  {
   double point = g_symbol.Point();
   double minSize = InpMinFVGSizePoints * point;

   int searchFrom = MathMin(sweepIdx, mssIdx + InpMaxBarsForFVGSearch);
   int searchTo   = mssIdx;

   // scan from the bar closest to "now" (mssIdx) backward toward the sweep,
   // so we pick the FVG nearest to current price action first.
   for(int i = searchTo + 1; i <= searchFrom - 1; i++)
     {
      // candle pattern uses three consecutive candles: i+1 (older), i (middle), i-1 (newer)
      // (series order: index 0 = newest, so the older candle has the larger index)
      if(i - 1 < 0 || i + 1 >= ArraySize(r))
         continue;

      if(bullish)
        {
         double gapLow  = r[i - 1].low;
         double gapHigh = r[i + 1].high;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow      = gapHigh;
            fvgHigh     = gapLow;
            fvgTimeLeft  = r[i + 1].time;
            fvgTimeRight = r[i - 1].time;
            return true;
           }
        }
      else
        {
         double gapHigh = r[i - 1].high;
         double gapLow  = r[i + 1].low;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow      = gapHigh;
            fvgHigh     = gapLow;
            fvgTimeLeft  = r[i + 1].time;
            fvgTimeRight = r[i - 1].time;
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| True if any candle strictly after the FVG formed (refIdx, the     |
//| newer outer candle of the 3-candle gap) already had a wick reach  |
//| into the zone -- i.e. the zone is already "used up" rather than   |
//| fresh, even though FindEntryFVG only checks the gap's existence,  |
//| not whether price has since retested it once already.            |
//+------------------------------------------------------------------+
bool ZoneTested(const MqlRates &r[], int refIdx, double lo, double hi, double point, double bufferPts)
  {
   if(refIdx <= 0)
      return false;
   double buf = bufferPts * point;
   double zlo = lo - buf, zhi = hi + buf;
   for(int idx = 0; idx < refIdx; idx++)
      if(r[idx].low <= zhi && r[idx].high >= zlo)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Same check for the ascending historical array: any candle between |
//| the FVG's formation (fvgRightIdx, exclusive) and the MSS bar       |
//| (exclusive -- that's when the pending order would have been       |
//| placed) that already wicked into the zone.                        |
//+------------------------------------------------------------------+
bool ZoneTestedAscending(const MqlRates &r[], int n, int fvgRightIdx, int mssIdx, double lo, double hi, double point, double bufferPts)
  {
   double buf = bufferPts * point;
   double zlo = lo - buf, zhi = hi + buf;
   for(int idx = fvgRightIdx + 1; idx < mssIdx; idx++)
     {
      if(idx < 0 || idx >= n)
         continue;
      if(r[idx].low <= zhi && r[idx].high >= zlo)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Next external liquidity beyond entry - used as the take profit    |
//| target (the "draw on liquidity").                                 |
//+------------------------------------------------------------------+
bool FindLiquidityTarget(const MqlRates &r[], int total, bool bullish, double entryPrice, double &target)
  {
   int k = InpSwingLeftRight;
   for(int i = k; i < total - k; i++)
     {
      if(bullish && IsSwingHigh(r, i, k) && r[i].high > entryPrice)
        {
         target = r[i].high;
         return true;
        }
      if(!bullish && IsSwingLow(r, i, k) && r[i].low < entryPrice)
        {
         target = r[i].low;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| bullish FVG: price retraces down into it from above, so the      |
//| nearest edge is fvgHigh and the deeper/"far" edge (better price,  |
//| harder fill) is fvgLow. bearish FVG: price retraces up into it    |
//| from below, so the far edge is fvgHigh.                          |
//+------------------------------------------------------------------+
void ComputeEntrySL(bool bullish, double fvgHigh, double fvgLow, double sweepExtreme, double &entry, double &sl)
  {
   double point = g_symbol.Point();
   entry = bullish
           ? (InpEntryAtMidpoint ? (fvgHigh + fvgLow) / 2.0 : fvgLow)
           : (InpEntryAtMidpoint ? (fvgHigh + fvgLow) / 2.0 : fvgHigh);

   sl = bullish
        ? sweepExtreme - InpSweepBufferPoints * point
        : sweepExtreme + InpSweepBufferPoints * point;
  }

//+------------------------------------------------------------------+
void PlacePendingOrder(Setup &s, const MqlRates &rates[], int total)
  {
   if((int)(g_symbol.Spread()) > InpMaxSpreadPoints)
     {
      ResetSetup(s, InpClearInvalidatedSteps);
      return;
     }

   if(InpSkipTestedFVG && s.tested)
     {
      ResetSetup(s, InpClearInvalidatedSteps);
      return;
     }

   double entry, sl;
   ComputeEntrySL(s.bullish, s.fvgHigh, s.fvgLow, s.sweepExtreme, entry, sl);

   double slDistance = MathAbs(entry - sl);
   if(slDistance <= 0)
     {
      ResetSetup(s, InpClearInvalidatedSteps);
      return;
     }

   double target;
   double tp;
   if(FindLiquidityTarget(rates, total, s.bullish, entry, target))
      tp = target;
   else
      tp = s.bullish ? entry + slDistance * InpFallbackRR
                      : entry - slDistance * InpFallbackRR;

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0)
     {
      ResetSetup(s, InpClearInvalidatedSteps);
      return;
     }

   entry = NormalizeDouble(entry, g_symbol.Digits());
   sl    = NormalizeDouble(sl, g_symbol.Digits());
   tp    = NormalizeDouble(tp, g_symbol.Digits());

   if(!InpAutoTrade)
     {
      // signal/drawing-only mode: show the levels that would have been
      // traded but don't send a real order, and free the slot for the
      // next setup since there's no pending ticket to track.
      if(DrawingsAllowed())
         DrawTradeLevels(s, entry, sl, tp);
      ResetSetup(s, false);
      return;
     }

   bool ok;
   if(s.bullish)
      ok = g_trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0,
                             "MMBM bullish FVG entry");
   else
      ok = g_trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0,
                              "MMBM bearish FVG entry");

   if(ok)
     {
      s.pendingTicket    = g_trade.ResultOrder();
      s.pendingPlacedBar = 0;

      if(DrawingsAllowed())
         DrawTradeLevels(s, entry, sl, tp);
     }
   else
     {
      ResetSetup(s, InpClearInvalidatedSteps);
     }
  }

//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return 0;

   double valuePerPriceUnit = tickValue / tickSize;
   double lossPerLot = slDistancePrice * valuePerPriceUnit;
   if(lossPerLot <= 0)
      return 0;

   double lots = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }

//+------------------------------------------------------------------+
void ManagePendingExpiry(bool newBar)
  {
   ManagePendingExpiryForSetup(g_bull, newBar);
   ManagePendingExpiryForSetup(g_bear, newBar);
   ManageOpenPosition(g_bull);
   ManageOpenPosition(g_bear);
  }

void ManagePendingExpiryForSetup(Setup &s, bool newBar)
  {
   if(s.state != STATE_WAIT_FILL || s.pendingTicket == 0)
      return;

   if(!OrderSelect(s.pendingTicket))
     {
      // order is gone: either filled (now a position) or already removed
      if(!PositionExistsForSetup(s))
        {
         ResetSetup(s, InpClearInvalidatedSteps);
        }
      else
        {
         // filled -> stop the entry line right here instead of letting it
         // ray on forever, and switch to tracking the open position so the
         // SL/TP lines can be capped at the bar the trade actually closes.
         if(DrawingsAllowed())
            TruncateLevelLine(SetupPrefix(s) + "Entry", iTime(_Symbol, InpLTF_Timeframe, 0));
         s.pendingTicket = 0;
         s.state         = STATE_IN_TRADE;
        }
      return;
     }

   if(!newBar)
      return;

   s.pendingPlacedBar++;
   if(s.pendingPlacedBar > InpPendingExpiryBars)
     {
      g_trade.OrderDelete(s.pendingTicket);
      ResetSetup(s, InpClearInvalidatedSteps);
     }
  }

void ManageOpenPosition(Setup &s)
  {
   if(s.state != STATE_IN_TRADE)
      return;

   if(!PositionExistsForSetup(s))
     {
      // trade closed (SL, TP, or manual) -> cap the SL/TP lines at the
      // closing bar instead of leaving them raying right indefinitely,
      // then free the slot so a new setup can be searched for.
      if(DrawingsAllowed())
        {
         datetime now = iTime(_Symbol, InpLTF_Timeframe, 0);
         TruncateLevelLine(SetupPrefix(s) + "SL", now);
         TruncateLevelLine(SetupPrefix(s) + "TP", now);
        }
      ResetSetup(s, false);
     }
  }

bool PositionExistsForSetup(Setup &s)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(s.bullish && ptype == POSITION_TYPE_BUY) return true;
      if(!s.bullish && ptype == POSITION_TYPE_SELL) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void ResetSetup(Setup &s, bool wipeDrawings)
  {
   if(wipeDrawings && s.setupId != 0)
      DeleteObjectsByPrefix(SetupPrefix(s));

   bool bullish = s.bullish;
   ZeroMemory(s);
   s.bullish = bullish;
   s.state   = STATE_IDLE;
  }

//+------------------------------------------------------------------+
//| Chart drawing helpers                                              |
//+------------------------------------------------------------------+
string SetupPrefix(const Setup &s)
  {
   return OBJ_PREFIX + (s.isHistorical ? "HIST_" : "") + (s.bullish ? "BUY_" : "SELL_") + IntegerToString(s.setupId) + "_";
  }

void DeleteObjectsByPrefix(string prefix)
  {
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
     }
  }

void DrawSweep(const Setup &s)
  {
   string pfx   = SetupPrefix(s);
   color  col   = s.bullish ? InpColorSweepBull : InpColorSweepBear;
   string tag   = s.bullish ? "SSL Sweep" : "BSL Sweep";

   string arrowName = pfx + "SweepArrow";
   ObjectCreate(0, arrowName, OBJ_ARROW, 0, s.sweepTime, s.sweepExtreme);
   ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, s.bullish ? 233 : 234);
   ObjectSetInteger(0, arrowName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, arrowName, OBJPROP_ANCHOR, s.bullish ? ANCHOR_TOP : ANCHOR_BOTTOM);

   // dotted ray runs from where the liquidity actually formed (the original
   // swing point) up to the sweep candle that grabbed it, so the level being
   // hunted is visually obvious instead of just appearing at the sweep bar.
   datetime levelStart = (s.liquidityTime != 0) ? s.liquidityTime : s.sweepTime;
   string levelName = pfx + "SweptLevel";
   ObjectCreate(0, levelName, OBJ_TREND, 0, levelStart, s.liquidityLevel,
                s.sweepTime, s.liquidityLevel);
   ObjectSetInteger(0, levelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, levelName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, levelName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, levelName, OBJPROP_RAY_RIGHT, false);

   string labelName = pfx + "SweptLevelLabel";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, s.sweepTime, s.liquidityLevel);
   ObjectSetString(0, labelName, OBJPROP_TEXT, " " + tag);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, s.bullish ? ANCHOR_RIGHT_LOWER : ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

void DrawMSS(const Setup &s)
  {
   string pfx = SetupPrefix(s);
   string name = pfx + "MSS";
   ObjectCreate(0, name, OBJ_TREND, 0, s.sweepTime, s.mssLevel,
                s.mssTime, s.mssLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorMSS);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);

   string labelName = pfx + "MSSLabel";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, s.mssTime, s.mssLevel);
   ObjectSetString(0, labelName, OBJPROP_TEXT, " MSS");
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, InpColorMSS);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

void DrawFVG(const Setup &s)
  {
   string pfx  = SetupPrefix(s);
   color  col  = s.bullish ? InpColorFVGBull : InpColorFVGBear;
   string name = pfx + "FVG";

   // bounded tightly to the actual 3-candle gap (the outer two candles'
   // timestamps), not stretched across the whole sweep->MSS impulse leg.
   datetime t1 = (s.fvgTimeLeft  != 0) ? s.fvgTimeLeft  : s.sweepTime;
   datetime t2raw = (s.fvgTimeRight != 0) ? s.fvgTimeRight : s.mssTime;
   datetime t2 = t2raw + PeriodSeconds(InpLTF_Timeframe); // include the right candle's full width

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, s.fvgHigh, t2, s.fvgLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   string labelName = pfx + "FVGLabel";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, t2, s.fvgHigh);
   ObjectSetString(0, labelName, OBJPROP_TEXT, s.tested ? " FVG / POI (tested)" : " FVG / POI");
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

void DrawTradeLevels(const Setup &s, double entry, double sl, double tp, datetime endTimeOverride = 0, bool rayRight = true)
  {
   string pfx = SetupPrefix(s);
   datetime t1 = s.mssTime;
   datetime t2 = (endTimeOverride != 0)
                 ? endTimeOverride
                 : TimeCurrent() + PeriodSeconds(InpLTF_Timeframe) * (InpPendingExpiryBars + 10);

   DrawLevelLine(pfx + "Entry", t1, t2, entry, InpColorEntry, STYLE_DASH, "Entry", rayRight);
   DrawLevelLine(pfx + "SL",    t1, t2, sl,    InpColorSL,    STYLE_SOLID, "SL", rayRight);
   DrawLevelLine(pfx + "TP",    t1, t2, tp,    InpColorTP,    STYLE_SOLID, "TP", rayRight);
  }

void DrawLevelLine(string name, datetime t1, datetime t2, double price, color col, ENUM_LINE_STYLE style, string tag, bool rayRight = true)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, rayRight);

   string labelName = name + "Label";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, t2, price);
   ObjectSetString(0, labelName, OBJPROP_TEXT, " " + tag + " " + DoubleToString(price, g_symbol.Digits()));
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

//+------------------------------------------------------------------+
//| Stops a previously-drawn level line (and its label) at newTime    |
//| instead of letting it ray right indefinitely - used when a       |
//| pending order fills (caps the Entry line) or a position closes   |
//| (caps the SL/TP lines), so live setups stop overlapping into      |
//| whatever the next setup draws.                                   |
//+------------------------------------------------------------------+
void TruncateLevelLine(string name, datetime newTime)
  {
   if(ObjectFind(0, name) < 0)
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, newTime);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);

   string labelName = name + "Label";
   if(ObjectFind(0, labelName) >= 0)
     {
      double price = ObjectGetDouble(0, labelName, OBJPROP_PRICE, 0);
      ObjectMove(0, labelName, 0, newTime, price);
     }
  }

//+------------------------------------------------------------------+
string StateToString(SetupState st)
  {
   switch(st)
     {
      case STATE_IDLE:      return "Idle (scanning for sweep)";
      case STATE_WAIT_MSS:  return "Sweep found, waiting for MSS";
      case STATE_WAIT_FILL: return "MSS confirmed, pending order at FVG";
      case STATE_IN_TRADE:  return "Position open, managing trade";
     }
   return "?";
  }

void UpdateStatusComment(bool bullBiasAllowed, bool bearBiasAllowed)
  {
   string txt = "=== MMBM Liquidity Sweep EA ===\n";
   txt += "Mode: " + (InpAutoTrade ? "AUTO-TRADE (live orders)" : "SIGNAL ONLY (no orders sent)") + "\n";
   if(_Period != InpLTF_Timeframe)
      txt += "WARNING: chart is on " + EnumToString((ENUM_TIMEFRAMES)_Period) + " but strategy TF is "
           + EnumToString(InpLTF_Timeframe) + " - drawings hidden here, attach to the " + EnumToString(InpLTF_Timeframe)
           + " chart to see them (trading still runs).\n";
   txt += "Bullish setup [" + (bullBiasAllowed ? "active" : "blocked by HTF bias") + "]: " + StateToString(g_bull.state) + "\n";
   txt += "Bearish setup [" + (bearBiasAllowed ? "active" : "blocked by HTF bias") + "]: " + StateToString(g_bear.state) + "\n";
   if(InpHistoryDays > 0)
      txt += "(History: last " + IntegerToString(InpHistoryDays) + " day(s) of completed setups drawn on chart)\n";
   Comment(txt);
  }

//+------------------------------------------------------------------+
//| On-chart dashboard: a fixed corner panel (not anchored to bars)  |
//| with live account/risk/setup/position info for running this as a |
//| real, supervised live-trading EA.                                |
//+------------------------------------------------------------------+
void EnsureDashboardObjects()
  {
   if(ObjectFind(0, DASH_PREFIX + "BG") >= 0)
      return;

   int x = 10, y = 20, w = 290, rowH = 16;
   string rows[] = {"Title","Mode","TF","Bias","Bull","Bear","Acct","Risk","Pos","Spread","Hist"};

   ObjectCreate(0, DASH_PREFIX + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_XDISTANCE, x - 6);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_YDISTANCE, y - 6);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_XSIZE, w);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_YSIZE, ArraySize(rows) * rowH + 12);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_BGCOLOR, C'18,18,18');
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, DASH_PREFIX + "BG", OBJPROP_HIDDEN, true);

   for(int i = 0; i < ArraySize(rows); i++)
     {
      string name = DASH_PREFIX + rows[i];
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y + i * rowH);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

void SetDashLine(string key, string text, color col)
  {
   string name = DASH_PREFIX + key;
   if(ObjectFind(0, name) < 0)
      return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
  }

void UpdateDashboard(bool bullBiasAllowed, bool bearBiasAllowed)
  {
   EnsureDashboardObjects();

   bool tfMatch = (_Period == InpLTF_Timeframe);

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   int posCount = 0; double posLots = 0; double posPnL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      posCount++;
      posLots += PositionGetDouble(POSITION_VOLUME);
      posPnL  += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }

   SetDashLine("Title", "=== MMBM Liquidity Sweep EA ===", clrYellow);
   SetDashLine("Mode",  "Mode: " + (InpAutoTrade ? "AUTO-TRADE" : "SIGNAL ONLY"),
               InpAutoTrade ? clrLimeGreen : clrOrange);
   SetDashLine("TF",    "Chart: " + EnumToString((ENUM_TIMEFRAMES)_Period) + (tfMatch ? "  [OK]" : "  [MISMATCH]"),
               tfMatch ? clrWhite : clrRed);
   SetDashLine("Bias",  "Bias: Buy " + (bullBiasAllowed ? "OK" : "blocked") + " | Sell " + (bearBiasAllowed ? "OK" : "blocked"), clrWhite);
   SetDashLine("Bull",  "Bull: " + StateToString(g_bull.state), clrDodgerBlue);
   SetDashLine("Bear",  "Bear: " + StateToString(g_bear.state), clrOrange);
   SetDashLine("Acct",  "Equity " + DoubleToString(equity, 2) + " | Bal " + DoubleToString(balance, 2), clrWhite);
   SetDashLine("Risk",  "Risk/trade: " + DoubleToString(InpRiskPercent, 2) + "%", clrWhite);
   SetDashLine("Pos",   "Open: " + IntegerToString(posCount) + " (" + DoubleToString(posLots, 2) + " lots)  P/L " + DoubleToString(posPnL, 2),
               posPnL >= 0 ? clrLimeGreen : clrRed);
   SetDashLine("Spread","Spread: " + IntegerToString((int)g_symbol.Spread()) + " pts (max " + IntegerToString(InpMaxSpreadPoints) + ")", clrWhite);
   SetDashLine("Hist",  InpHistoryDays > 0 ? ("History: last " + IntegerToString(InpHistoryDays) + "d drawn") : "History: off", clrSilver);
  }

//+------------------------------------------------------------------+
//| One-shot historical scan: walks the past InpHistoryDays of LTF    |
//| bars chronologically and draws every complete sweep -> MSS -> FVG |
//| sequence found, exactly like the live state machine would have,   |
//| but without placing any orders. Runs once on EA init (and again  |
//| automatically whenever an input is changed, since that re-fires   |
//| OnInit).                                                          |
//+------------------------------------------------------------------+
void ScanHistory()
  {
   datetime fromTime = TimeCurrent() - (long)InpHistoryDays * 86400;

   MqlRates hr[];
   ArraySetAsSeries(hr, false); // ascending: index 0 = oldest
   int n = CopyRates(_Symbol, InpLTF_Timeframe, fromTime, TimeCurrent(), hr);

   int k = InpSwingLeftRight;
   if(n < 2 * k + 10)
      return;

   ScanHistoryDirection(hr, n, true);
   ScanHistoryDirection(hr, n, false);
  }

void ScanHistoryDirection(const MqlRates &hr[], int n, bool bullish)
  {
   int k = InpSwingLeftRight;

   for(int i = k; i < n - k; i++)
     {
      bool isSwing = bullish ? IsSwingLow(hr, i, k) : IsSwingHigh(hr, i, k);
      if(!isSwing)
         continue;
      double level = bullish ? hr[i].low : hr[i].high;

      // forward search for the sweep candle
      int sweepIdx = -1; double sweepPrice = 0;
      for(int j = i + k + 1; j < n && j <= i + k + 1 + InpMaxBarsAfterSweep; j++)
        {
         if(bullish && hr[j].low < level && hr[j].close > level)  { sweepIdx = j; sweepPrice = hr[j].low;  break; }
         if(!bullish && hr[j].high > level && hr[j].close < level) { sweepIdx = j; sweepPrice = hr[j].high; break; }
        }
      if(sweepIdx < 0)
         continue;

      // From here on, any failure still advances the outer loop past this
      // sweep candle (instead of just i+1) so an adjacent swing point inside
      // the same consolidation can't re-detect the same sweep and produce
      // duplicate-looking drawings.

      // forward search for the opposing minor swing (the MSS reference level)
      double refLevel = 0; int refIdx = -1;
      for(int m = sweepIdx + k; m < n - k && m <= sweepIdx + InpMaxBarsAfterSweep; m++)
        {
         if(bullish && IsSwingHigh(hr, m, k))  { refLevel = hr[m].high; refIdx = m; break; }
         if(!bullish && IsSwingLow(hr, m, k))  { refLevel = hr[m].low;  refIdx = m; break; }
        }
      if(refIdx < 0)
        {
         i = sweepIdx;
         continue;
        }

      // forward search for the MSS confirmation (close beyond refLevel)
      int mssIdx = -1;
      for(int j = refIdx + 1; j < n && j <= sweepIdx + InpMaxBarsAfterSweep; j++)
        {
         if(bullish && hr[j].close > refLevel)  { mssIdx = j; break; }
         if(!bullish && hr[j].close < refLevel) { mssIdx = j; break; }
        }
      if(mssIdx < 0)
        {
         i = sweepIdx;
         continue;
        }

      // search the impulse leg (sweepIdx..mssIdx) for the entry FVG, nearest to mssIdx first
      double fvgHigh = 0, fvgLow = 0; datetime fvgTimeLeft = 0, fvgTimeRight = 0; int fvgRightIdx = -1;
      if(!FindEntryFVGAscending(hr, n, sweepIdx, mssIdx, bullish, fvgHigh, fvgLow, fvgTimeLeft, fvgTimeRight, fvgRightIdx))
        {
         i = mssIdx;
         continue;
        }

      Setup hs;
      ZeroMemory(hs);
      hs.bullish        = bullish;
      hs.isHistorical    = true;
      hs.setupId         = ++g_setupCounter;
      hs.sweepTime       = hr[sweepIdx].time;
      hs.sweepExtreme    = sweepPrice;
      hs.liquidityLevel  = level;
      hs.liquidityTime   = hr[i].time;
      hs.mssTime         = hr[mssIdx].time;
      hs.mssLevel        = refLevel;
      hs.fvgHigh         = fvgHigh;
      hs.fvgLow          = fvgLow;
      hs.fvgTimeLeft     = fvgTimeLeft;
      hs.fvgTimeRight    = fvgTimeRight;
      hs.tested          = ZoneTestedAscending(hr, n, fvgRightIdx, mssIdx, fvgLow, fvgHigh, g_symbol.Point(), InpSweepBufferPoints);

      DrawSweep(hs);
      DrawMSS(hs);
      DrawFVG(hs);

      double entry, sl;
      ComputeEntrySL(bullish, fvgHigh, fvgLow, sweepPrice, entry, sl);
      double slDistance = MathAbs(entry - sl);
      if(slDistance > 0)
        {
         double target, tp;
         if(!InpHistoryComputeTPviaFallbackOnly && FindLiquidityTargetAscending(hr, n, bullish, entry, mssIdx, target))
            tp = target;
         else
            tp = bullish ? entry + slDistance * InpFallbackRR : entry - slDistance * InpFallbackRR;

         datetime entryEnd, exitEnd; bool filled;
         ComputeHistoricalLifecycle(hr, n, mssIdx, bullish, entry, sl, tp, entryEnd, filled, exitEnd);
         DrawHistoricalTradeLevels(hs, entry, sl, tp, hr[mssIdx].time, entryEnd, exitEnd, filled);
        }

      // resume scanning after this setup's MSS bar so overlapping duplicates aren't found
      i = mssIdx;
     }
  }

//+------------------------------------------------------------------+
//| Same 3-candle FVG search as FindEntryFVG, but for an ascending    |
//| (oldest-first) historical array.                                  |
//+------------------------------------------------------------------+
bool FindEntryFVGAscending(const MqlRates &r[], int n, int sweepIdx, int mssIdx, bool bullish, double &fvgHigh, double &fvgLow, datetime &fvgTimeLeft, datetime &fvgTimeRight, int &fvgRightIdx)
  {
   double point = g_symbol.Point();
   double minSize = InpMinFVGSizePoints * point;

   int searchFrom = MathMax(sweepIdx, mssIdx - InpMaxBarsForFVGSearch);

   // scan from the bar closest to "now" (mssIdx) backward toward the sweep
   // (ascending order: index 0 = oldest, so the older candle has the smaller index)
   for(int i = mssIdx - 1; i > searchFrom; i--)
     {
      if(i - 1 < 0 || i + 1 >= n)
         continue;

      if(bullish)
        {
         double gapLow  = r[i + 1].low;
         double gapHigh = r[i - 1].high;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow      = gapHigh;
            fvgHigh     = gapLow;
            fvgTimeLeft  = r[i - 1].time;
            fvgTimeRight = r[i + 1].time;
            fvgRightIdx  = i + 1;
            return true;
           }
        }
      else
        {
         double gapHigh = r[i + 1].high;
         double gapLow  = r[i - 1].low;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow      = gapHigh;
            fvgHigh     = gapLow;
            fvgTimeLeft  = r[i - 1].time;
            fvgTimeRight = r[i + 1].time;
            fvgRightIdx  = i + 1;
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Walks forward through history to find when the entry would have  |
//| been filled, and after that, when price first reaches SL or TP -  |
//| so historical lines can stop at that "first re-test" bar instead  |
//| of running for a fixed window and overlapping the next setup.    |
//+------------------------------------------------------------------+
void ComputeHistoricalLifecycle(const MqlRates &hr[], int n, int mssIdx, bool bullish,
                                 double entry, double sl, double tp,
                                 datetime &entryEnd, bool &filled, datetime &exitEnd)
  {
   filled   = false;
   entryEnd = hr[mssIdx].time + PeriodSeconds(InpLTF_Timeframe) * InpPendingExpiryBars;
   exitEnd  = 0;

   int fillIdx = -1;
   int maxFillIdx = MathMin(n - 1, mssIdx + InpPendingExpiryBars);
   for(int j = mssIdx + 1; j <= maxFillIdx; j++)
     {
      bool touched = bullish ? (hr[j].low <= entry) : (hr[j].high >= entry);
      if(touched) { fillIdx = j; break; }
     }
   if(fillIdx < 0)
      return; // pending order would have expired unfilled

   filled   = true;
   entryEnd = hr[fillIdx].time;

   for(int j = fillIdx; j < n; j++)
     {
      bool hitSL = bullish ? (hr[j].low <= sl) : (hr[j].high >= sl);
      bool hitTP = bullish ? (hr[j].high >= tp) : (hr[j].low <= tp);
      if(hitSL || hitTP)
        {
         exitEnd = hr[j].time;
         return;
        }
     }
   exitEnd = hr[n - 1].time; // still open at the edge of the scanned history window
  }

void DrawHistoricalTradeLevels(const Setup &s, double entry, double sl, double tp,
                                datetime entryStart, datetime entryEnd, datetime exitEnd, bool filled)
  {
   string pfx = SetupPrefix(s);
   DrawLevelLine(pfx + "Entry", entryStart, entryEnd, entry, InpColorEntry, STYLE_DASH,
                 filled ? "Entry" : "Entry (unfilled)", false);

   // only draw SL/TP if the order would actually have been filled - otherwise
   // there's no real trade for them to represent.
   if(filled)
     {
      DrawLevelLine(pfx + "SL", entryEnd, exitEnd, sl, InpColorSL, STYLE_SOLID, "SL", false);
      DrawLevelLine(pfx + "TP", entryEnd, exitEnd, tp, InpColorTP, STYLE_SOLID, "TP", false);
     }
  }

//+------------------------------------------------------------------+
//| Same liquidity-target search as FindLiquidityTarget, but searches |
//| forward through the ascending historical array starting after the |
//| MSS bar.                                                          |
//+------------------------------------------------------------------+
bool FindLiquidityTargetAscending(const MqlRates &r[], int n, bool bullish, double entryPrice, int fromIdx, double &target)
  {
   int k = InpSwingLeftRight;
   for(int i = fromIdx; i < n - k; i++)
     {
      if(bullish && IsSwingHigh(r, i, k) && r[i].high > entryPrice)
        {
         target = r[i].high;
         return true;
        }
      if(!bullish && IsSwingLow(r, i, k) && r[i].low < entryPrice)
        {
         target = r[i].low;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
