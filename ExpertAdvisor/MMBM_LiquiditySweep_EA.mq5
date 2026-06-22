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
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- inputs -----------------------------------------------------------
input ENUM_TIMEFRAMES InpHTF_Timeframe        = PERIOD_H4;   // Higher timeframe used for directional bias
input ENUM_TIMEFRAMES InpLTF_Timeframe        = PERIOD_M15;  // Entry timeframe (sweep / MSS / FVG)
input int             InpSwingLeftRight       = 3;           // Bars each side required to confirm a swing point
input bool            InpRequireHTFBias       = true;        // Only trade in the direction of HTF structure
input int             InpMaxBarsAfterSweep    = 25;           // Max LTF bars allowed for MSS to occur after a sweep
input int             InpMaxBarsForFVGSearch  = 15;           // How far back from the MSS bar to search for the entry FVG
input double          InpMinFVGSizePoints     = 30;           // Minimum FVG size (points) to be tradable
input bool            InpEntryAtMidpoint      = true;         // true = limit @ 50% of FVG, false = limit @ far edge of FVG
input double          InpSweepBufferPoints    = 20;           // Extra buffer beyond the sweep extreme for the stop loss
input double          InpRiskPercent          = 1.0;          // Risk per trade, % of account equity
input double          InpFallbackRR           = 2.0;          // Reward:Risk used when no liquidity target is found
input int             InpPendingExpiryBars    = 20;           // Cancel an unfilled pending order after N LTF bars
input int             InpMaxSpreadPoints      = 30;           // Skip new entries if spread exceeds this
input ulong           InpMagicNumber          = 19380001;     // Magic number for this EA's orders
input bool            InpOneSetupAtATime      = true;         // Only manage one active setup per direction at a time

//--- bookkeeping --------------------------------------------------------
enum SetupState
  {
   STATE_IDLE,        // looking for a liquidity sweep
   STATE_WAIT_MSS,     // sweep found, waiting for market structure shift
   STATE_WAIT_FILL     // MSS confirmed, pending limit order placed at FVG
  };

struct Setup
  {
   SetupState state;
   bool       bullish;
   double     sweepExtreme;  // price of the liquidity sweep wick
   datetime   sweepTime;     // bar time of the sweep candle (stable across re-copies of rates[])
   datetime   mssTime;       // bar time of the MSS confirmation candle
   double     fvgHigh;
   double     fvgLow;
   ulong      pendingTicket;
   int        pendingPlacedBar;
  };

Setup g_bull, g_bear;

CTrade        g_trade;
CSymbolInfo   g_symbol;

datetime g_lastLTFBarTime = 0;

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
      int sweepIdx; double sweepPrice;
      if(FindLiquiditySweep(rates, total, s.bullish, sweepIdx, sweepPrice))
        {
         s.state        = STATE_WAIT_MSS;
         s.sweepTime     = rates[sweepIdx].time;
         s.sweepExtreme  = sweepPrice;
         s.mssTime       = 0;
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
         ResetSetup(s);
         return;
        }

      int mssIdx;
      if(FindMarketStructureShift(rates, total, s.bullish, sweepIdx, mssIdx))
        {
         s.state   = STATE_WAIT_FILL;
         s.mssTime = rates[mssIdx].time;

         double fvgHigh, fvgLow;
         if(FindEntryFVG(rates, sweepIdx, mssIdx, s.bullish, fvgHigh, fvgLow))
           {
            s.fvgHigh = fvgHigh;
            s.fvgLow  = fvgLow;
            PlacePendingOrder(s, rates, total);
           }
         else
           {
            ResetSetup(s); // no usable FVG/POI -> abandon this setup
           }
        }
      return;
     }
  }

//+------------------------------------------------------------------+
//| Liquidity sweep: a wick pierces a prior swing low (bullish) or    |
//| swing high (bearish) and the candle closes back inside.           |
//+------------------------------------------------------------------+
bool FindLiquiditySweep(const MqlRates &r[], int total, bool bullish, int &sweepIdx, double &sweepPrice)
  {
   int k = InpSwingLeftRight;
   // look for the most recent fully-formed swing point, then check if a later,
   // more recent candle has swept through it and closed back inside.
   for(int i = k + 1; i < total - k; i++)
     {
      if(bullish && IsSwingLow(r, i, k))
        {
         double liquidityLevel = r[i].low;
         for(int j = i - k - 1; j >= 0; j--)
           {
            if(r[j].low < liquidityLevel && r[j].close > liquidityLevel)
              {
               sweepIdx   = j;
               sweepPrice = r[j].low;
               return true;
              }
           }
        }
      if(!bullish && IsSwingHigh(r, i, k))
        {
         double liquidityLevel = r[i].high;
         for(int j = i - k - 1; j >= 0; j--)
           {
            if(r[j].high > liquidityLevel && r[j].close < liquidityLevel)
              {
               sweepIdx   = j;
               sweepPrice = r[j].high;
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
bool FindMarketStructureShift(const MqlRates &r[], int total, bool bullish, int sweepIdx, int &mssIdx)
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
         mssIdx = j;
         return true;
        }
      if(!bullish && r[j].close < refLevel)
        {
         mssIdx = j;
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
      ResetSetup(s);
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
      ResetSetup(s);
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
      ResetSetup(s);
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
     }
   else
     {
      ResetSetup(s);
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
         ResetSetup(s);
      else
        {
         s.state = STATE_IDLE; // filled -> hand off management to SL/TP, free up the slot
         s.pendingTicket = 0;
        }
      return;
     }

   if(!newBar)
      return;

   s.pendingPlacedBar++;
   if(s.pendingPlacedBar > InpPendingExpiryBars)
     {
      g_trade.OrderDelete(s.pendingTicket);
      ResetSetup(s);
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
void ResetSetup(Setup &s)
  {
   bool bullish = s.bullish;
   ZeroMemory(s);
   s.bullish = bullish;
   s.state   = STATE_IDLE;
  }
//+------------------------------------------------------------------+
