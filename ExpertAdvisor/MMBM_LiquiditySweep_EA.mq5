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
#property version   "1.10"

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
input double          InpSweepBufferPoints    = 20;          // Extra buffer beyond the sweep extreme for the stop loss
input double          InpRiskPercent          = 1.0;         // Risk per trade, % of account equity
input double          InpFallbackRR           = 2.0;         // Reward:Risk used when no liquidity target is found
input int             InpPendingExpiryBars    = 20;          // Cancel an unfilled pending order after N LTF bars
input int             InpMaxSpreadPoints      = 30;          // Skip new entries if spread exceeds this
input ulong           InpMagicNumber          = 19380001;    // Magic number for this EA's orders
input bool            InpOneSetupAtATime      = true;        // Only manage one active setup per direction at a time

input group "=== Chart Visuals ==="
input bool   InpShowDrawings        = true;         // Draw sweep/MSS/FVG/entry/SL/TP objects on the chart
input bool   InpClearInvalidatedSteps = true;        // Remove drawings for setups that fail before producing a trade
input bool   InpDeleteObjectsOnRemove = false;       // Wipe all EA drawings when the EA is removed from the chart
input bool   InpShowStatusComment   = true;          // Show a live status line via Comment()
input color  InpColorSweepBull      = clrDodgerBlue; // Bullish sweep marker / swept level color
input color  InpColorSweepBear      = clrOrange;     // Bearish sweep marker / swept level color
input color  InpColorMSS            = clrBlue;       // MSS break level color
input color  InpColorFVGBull        = clrAqua;       // Bullish FVG zone fill color
input color  InpColorFVGBear        = clrLightPink;  // Bearish FVG zone fill color
input color  InpColorEntry          = clrGoldenrod;  // Entry line color
input color  InpColorSL             = clrRed;        // Stop loss line color
input color  InpColorTP             = clrLimeGreen;  // Take profit line color

//--- bookkeeping --------------------------------------------------------
enum SetupState
  {
   STATE_IDLE,         // looking for a liquidity sweep
   STATE_WAIT_MSS,     // sweep found, waiting for market structure shift
   STATE_WAIT_FILL     // MSS confirmed, pending limit order placed at FVG
  };

struct Setup
  {
   SetupState state;
   bool       bullish;
   int        setupId;
   double     sweepExtreme;    // price of the liquidity sweep wick
   double     liquidityLevel;  // the swing price that was swept
   datetime   sweepTime;       // bar time of the sweep candle (stable across re-copies of rates[])
   datetime   mssTime;         // bar time of the MSS confirmation candle
   double     mssLevel;        // the price level broken to confirm MSS
   double     fvgHigh;
   double     fvgLow;
   ulong      pendingTicket;
   int        pendingPlacedBar;
  };

Setup g_bull, g_bear;
int   g_setupCounter = 0;

CTrade        g_trade;
CSymbolInfo   g_symbol;

datetime g_lastLTFBarTime = 0;

#define OBJ_PREFIX "MMBM_"

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

   return INIT_SUCCEEDED;
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

   if(!newBar)
      return;

   bool htfBullBias = true, htfBearBias = true;
   GetHTFBias(htfBullBias, htfBearBias);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpLTF_Timeframe, 1, 200, rates);
   if(copied < 2 * InpSwingLeftRight + 10)
      return;

   if(htfBullBias)
      ProcessSetup(g_bull, rates, copied);
   if(htfBearBias)
      ProcessSetup(g_bear, rates, copied);

   if(InpShowStatusComment)
      UpdateStatusComment(htfBullBias, htfBearBias);
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
      int sweepIdx; double sweepPrice; double liquidityLevel;
      if(FindLiquiditySweep(rates, total, s.bullish, sweepIdx, sweepPrice, liquidityLevel))
        {
         s.state          = STATE_WAIT_MSS;
         s.setupId         = ++g_setupCounter;
         s.sweepTime       = rates[sweepIdx].time;
         s.sweepExtreme    = sweepPrice;
         s.liquidityLevel  = liquidityLevel;
         s.mssTime         = 0;

         if(InpShowDrawings)
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

         if(InpShowDrawings)
            DrawMSS(s);

         double fvgHigh, fvgLow;
         if(FindEntryFVG(rates, sweepIdx, mssIdx, s.bullish, fvgHigh, fvgLow))
           {
            s.fvgHigh = fvgHigh;
            s.fvgLow  = fvgLow;

            if(InpShowDrawings)
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
bool FindLiquiditySweep(const MqlRates &r[], int total, bool bullish, int &sweepIdx, double &sweepPrice, double &liquidityLevel)
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
bool FindEntryFVG(const MqlRates &r[], int sweepIdx, int mssIdx, bool bullish, double &fvgHigh, double &fvgLow)
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
      if(i - 1 < 0 || i + 1 >= ArraySize(r))
         continue;

      if(bullish)
        {
         double gapLow  = r[i - 1].low;
         double gapHigh = r[i + 1].high;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow  = gapHigh;
            fvgHigh = gapLow;
            return true;
           }
        }
      else
        {
         double gapHigh = r[i - 1].high;
         double gapLow  = r[i + 1].low;
         if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
           {
            fvgLow  = gapHigh;
            fvgHigh = gapLow;
            return true;
           }
        }
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
void PlacePendingOrder(Setup &s, const MqlRates &rates[], int total)
  {
   if((int)(g_symbol.Spread()) > InpMaxSpreadPoints)
     {
      ResetSetup(s, InpClearInvalidatedSteps);
      return;
     }

   double point = g_symbol.Point();
   // bullish FVG: price retraces down into it from above, so the nearest edge is
   // fvgHigh and the deeper/"far" edge (better price, harder fill) is fvgLow.
   // bearish FVG: price retraces up into it from below, so the far edge is fvgHigh.
   double entry = s.bullish
                  ? (InpEntryAtMidpoint ? (s.fvgHigh + s.fvgLow) / 2.0 : s.fvgLow)
                  : (InpEntryAtMidpoint ? (s.fvgHigh + s.fvgLow) / 2.0 : s.fvgHigh);

   double sl = s.bullish
               ? s.sweepExtreme - InpSweepBufferPoints * point
               : s.sweepExtreme + InpSweepBufferPoints * point;

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

      if(InpShowDrawings)
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
  }

void ManagePendingExpiryForSetup(Setup &s, bool newBar)
  {
   if(s.state != STATE_WAIT_FILL || s.pendingTicket == 0)
      return;

   if(!OrderSelect(s.pendingTicket))
     {
      // order is gone: either filled (now a position) or already removed
      if(!PositionExistsForSetup(s))
         ResetSetup(s, InpClearInvalidatedSteps);
      else
        {
         // filled -> keep all drawings as the permanent trade record, just
         // free up the slot so a new setup can be searched for.
         ResetSetup(s, false);
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
   return OBJ_PREFIX + (s.bullish ? "BUY_" : "SELL_") + IntegerToString(s.setupId) + "_";
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

   string levelName = pfx + "SweptLevel";
   ObjectCreate(0, levelName, OBJ_TREND, 0, s.sweepTime, s.liquidityLevel,
                s.sweepTime + PeriodSeconds(InpLTF_Timeframe) * 40, s.liquidityLevel);
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

   datetime t2 = s.mssTime + PeriodSeconds(InpLTF_Timeframe) * (InpPendingExpiryBars + 5);

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, s.sweepTime, s.fvgHigh, t2, s.fvgLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   string labelName = pfx + "FVGLabel";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, s.mssTime, s.fvgHigh);
   ObjectSetString(0, labelName, OBJPROP_TEXT, " FVG / POI");
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

void DrawTradeLevels(const Setup &s, double entry, double sl, double tp)
  {
   string pfx = SetupPrefix(s);
   datetime t1 = s.mssTime;
   datetime t2 = TimeCurrent() + PeriodSeconds(InpLTF_Timeframe) * (InpPendingExpiryBars + 10);

   DrawLevelLine(pfx + "Entry", t1, t2, entry, InpColorEntry, STYLE_DASH, "Entry");
   DrawLevelLine(pfx + "SL",    t1, t2, sl,    InpColorSL,    STYLE_SOLID, "SL");
   DrawLevelLine(pfx + "TP",    t1, t2, tp,    InpColorTP,    STYLE_SOLID, "TP");
  }

void DrawLevelLine(string name, datetime t1, datetime t2, double price, color col, ENUM_LINE_STYLE style, string tag)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);

   string labelName = name + "Label";
   ObjectCreate(0, labelName, OBJ_TEXT, 0, t2, price);
   ObjectSetString(0, labelName, OBJPROP_TEXT, " " + tag + " " + DoubleToString(price, g_symbol.Digits()));
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
  }

//+------------------------------------------------------------------+
string StateToString(SetupState st)
  {
   switch(st)
     {
      case STATE_IDLE:      return "Idle (scanning for sweep)";
      case STATE_WAIT_MSS:  return "Sweep found, waiting for MSS";
      case STATE_WAIT_FILL: return "MSS confirmed, pending order at FVG";
     }
   return "?";
  }

void UpdateStatusComment(bool bullBiasAllowed, bool bearBiasAllowed)
  {
   string txt = "=== MMBM Liquidity Sweep EA ===\n";
   txt += "Bullish setup [" + (bullBiasAllowed ? "active" : "blocked by HTF bias") + "]: " + StateToString(g_bull.state) + "\n";
   txt += "Bearish setup [" + (bearBiasAllowed ? "active" : "blocked by HTF bias") + "]: " + StateToString(g_bear.state) + "\n";
   Comment(txt);
  }
//+------------------------------------------------------------------+
