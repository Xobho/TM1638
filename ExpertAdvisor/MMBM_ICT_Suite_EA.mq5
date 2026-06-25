//+------------------------------------------------------------------+
//|                                     MMBM_ICT_Suite_EA.mq5        |
//|                                                                  |
//|  A full-suite ICT/SMC scanner + (optional) trader. This is the   |
//|  Expert Advisor counterpart of the Python bridge's ict.py: it    |
//|  evaluates SEVEN ICT strategies every new bar, for BOTH          |
//|  directions, draws each detected setup live on the chart, and    |
//|  (when auto-trade is on) takes the best "ready" setup.           |
//|                                                                  |
//|  It is deliberately a clean, stateless detector-per-bar design   |
//|  (mirroring ict.py) rather than a per-strategy pending-order     |
//|  state machine -- so it's easy to read, draw, and adjust. The    |
//|  original single-strategy MMBM_LiquiditySweep_EA.mq5 remains the |
//|  reference for the full sweep->MSS->FVG pending-order lifecycle. |
//|                                                                  |
//|  ============================ RULES ============================ |
//|  HTF bias (InpHTF_Timeframe): HH+HL => bullish-only, LH+LL =>    |
//|    bearish-only, mixed => both directions allowed. When          |
//|    InpRequireHTFBias is off, both directions always allowed.     |
//|                                                                  |
//|  All detection runs on InpLTF_Timeframe (the entry timeframe).   |
//|  A "swing" needs InpSwingLeftRight bars lower/higher on each     |
//|  side. Each setup gets a stage and a "tested" flag:              |
//|    stage "ready"   = price is inside the zone/at the level NOW   |
//|                      (actionable on a market order).             |
//|    stage "forming" = the structure is valid but price must still |
//|                      retrace into the zone first.                |
//|    "tested" = price has already wicked back into this zone since |
//|               it formed (even if it never closed inside) -- a    |
//|               used-up zone, weaker than a fresh one.             |
//|                                                                  |
//|  The seven strategies (each long & short):                       |
//|   1. Liquidity Sweep + MSS (SWEEP): wick sweeps a swing & closes |
//|      back inside -> market-structure shift -> entry in the FVG   |
//|      of the impulse leg. Stages: swept -> mss -> ready.          |
//|   2. Order Block (OB): last opposing candle before a break of    |
//|      structure; entry on the retrace into that candle's range.   |
//|   3. Fair Value Gap (FVG): standalone unfilled 3-candle          |
//|      imbalance; entry on the retrace into the gap.               |
//|   4. Breaker Block (BRK): the order block of a failed sweep that |
//|      flipped with structure; entry on the retest.               |
//|   5. Turtle Soup (TS): false breakout of the prior N-bar range   |
//|      extreme that closes back inside (a liquidity grab).         |
//|   6. Optimal Trade Entry (OTE): the 0.62-0.79 fib retracement    |
//|      zone of the most recent impulse leg.                        |
//|   7. Continuation Retest (CONT): a swing level price already     |
//|      broke through, retested from the breakout side -- a trend-  |
//|      continuation entry (the only non-reversal of the seven).    |
//|                                                                  |
//|  Stop loss sits beyond the structure (sweep extreme / zone edge /|
//|  swing); take profit is the next external liquidity (draw on     |
//|  liquidity) or InpFallbackRR if none is found.                  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- when a setup becomes actionable for auto-trade -------------------
enum ENUM_TRIGGER_MODE
  {
   TRIGGER_CLOSE = 0,   // Close-confirm: a candle must CLOSE inside the zone (checked on bar close)
   TRIGGER_TOUCH = 1    // Touch: fire the instant live price (incl. a wick) reaches into the zone
  };

//--- inputs -----------------------------------------------------------
input ENUM_TIMEFRAMES InpHTF_Timeframe        = PERIOD_H4;   // Higher timeframe used for directional bias
input ENUM_TIMEFRAMES InpLTF_Timeframe        = PERIOD_M15;  // Entry timeframe (all detection runs here)
input int             InpSwingLeftRight       = 3;           // Bars each side required to confirm a swing point
input bool            InpRequireHTFBias       = true;        // Only show/trade setups aligned with HTF structure
input int             InpMaxBarsAfterSweep    = 25;          // Max bars a sweep/break may be old and still count
input int             InpMaxBarsForFVGSearch  = 15;          // How far back from the MSS bar to search the entry FVG
input double          InpMinFVGSizePoints     = 30;          // Minimum FVG size (points) to be tradable
input bool            InpEntryAtMidpoint      = true;        // SWEEP entry at 50% of FVG (false = far edge)
input double          InpSweepBufferPoints    = 20;          // Stop buffer + zone tolerance (points) for all strategies
input double          InpFallbackRR           = 2.0;         // Reward:Risk used when no liquidity target is found

input group "=== Strategy toggles ==="
input bool   InpEnableSweep   = true;   // 1. Liquidity Sweep + MSS
input bool   InpEnableOB      = true;   // 2. Order Block
input bool   InpEnableFVG     = true;   // 3. Fair Value Gap (standalone)
input bool   InpEnableBreaker = true;   // 4. Breaker Block
input bool   InpEnableTurtle  = true;   // 5. Turtle Soup
input bool   InpEnableOTE     = true;   // 6. Optimal Trade Entry
input bool   InpEnableCont    = true;   // 7. Continuation Retest

input group "=== Trading ==="
input bool   InpAutoTrade         = false;   // false = scan/draw only (NO orders). true = trade the best ready setup
input ENUM_TRIGGER_MODE InpTriggerMode = TRIGGER_TOUCH; // When to fire: TOUCH (wick into zone, intrabar) or CLOSE (candle closes inside)
input double InpRiskPercent       = 1.0;     // Risk per trade, % of account equity
input int    InpMaxSpreadPoints   = 30;      // Skip entries if spread exceeds this
input bool   InpSkipTestedSetups  = true;    // Don't enter a zone that has already been tested once
input ulong  InpMagicNumber       = 19380002; // Magic number for this EA's orders

input group "=== Chart Visuals ==="
input bool   InpShowDrawings      = true;          // Draw detected setups on the chart
input bool   InpDrawTradeLines    = true;          // Draw entry/SL/TP lines for "ready" setups
input int    InpZoneExtendBars    = 12;            // How many bars to extend zone/level drawings to the right
input bool   InpShowDashboard     = true;          // Show the on-chart info panel
input color  InpColorBull         = clrAqua;       // Bullish zone/level color
input color  InpColorBear         = clrLightPink;  // Bearish zone/level color
input color  InpColorEntry        = clrGoldenrod;  // Entry line color
input color  InpColorSL           = clrRed;        // Stop loss line color
input color  InpColorTP           = clrLimeGreen;  // Take profit line color

input group "=== History ==="
input int    InpHistoryDays            = 5;   // Scan and draw completed "ready" setups from the past N days (0 = off)
input int    InpMaxHistoricalPerSetup  = 5;   // Cap historical drawings per strategy+direction (bounds scan time & object count)
input color  InpColorHistBull          = clrDeepSkyBlue; // Historical bullish setup color (more saturated than live -- outline-only needs the contrast)
input color  InpColorHistBear          = clrMagenta;     // Historical bearish setup color

//--- constants (mirror ict.py) ----------------------------------------
#define FVG_SCAN_BARS    60   // how far back a standalone FVG may be and still count
#define TURTLE_LOOKBACK  20   // range window for the turtle-soup false-break check
#define NUM_STRATEGIES    7
#define NUM_SLOTS        (NUM_STRATEGIES * 2)

#define OBJ_PREFIX  "ICTS_"
#define DASH_PREFIX "ICTS_DASH_"

//--- one detected setup ------------------------------------------------
struct IctSetup
  {
   bool     valid;
   int      stratNum;     // 0..6, index into the STRATEGIES order
   string   shortCode;    // "SWEEP","OB","FVG","BRK","TS","OTE","CONT"
   string   fullName;     // human-readable strategy name
   bool     bullish;
   string   stage;        // "ready" / "forming" / "sweep_only" / "mss_confirmed"
   bool     tested;       // price already revisited the zone/level since it formed
   bool     isZone;       // true = rectangle zone, false = single horizontal level
   double   zoneHigh;
   double   zoneLow;      // == zoneHigh for level setups
   datetime zoneTime;     // left anchor for drawing (the formation candle)
   bool     hasTrade;     // entry/sl/tp computed (actionable)
   double   entry;
   double   sl;
   double   tp;
   double   rr;
  };

//--- globals -----------------------------------------------------------
CTrade        g_trade;
CSymbolInfo   g_symbol;
datetime      g_lastLTFBarTime = 0;
bool          g_htfBullBias = true;
bool          g_htfBearBias = true;

IctSetup      g_slots[NUM_SLOTS];   // current detections, indexed by SlotIndex()
bool          g_slotActive[NUM_SLOTS];

string ShortCode(int n)
  {
   switch(n)
     {
      case 0: return "SWEEP";
      case 1: return "OB";
      case 2: return "FVG";
      case 3: return "BRK";
      case 4: return "TS";
      case 5: return "OTE";
      case 6: return "CONT";
     }
   return "?";
  }
string FullName(int n)
  {
   switch(n)
     {
      case 0: return "Liquidity Sweep+MSS";
      case 1: return "Order Block";
      case 2: return "Fair Value Gap";
      case 3: return "Breaker Block";
      case 4: return "Turtle Soup";
      case 5: return "Optimal Trade Entry";
      case 6: return "Continuation Retest";
     }
   return "?";
  }
bool StrategyEnabled(int n)
  {
   switch(n)
     {
      case 0: return InpEnableSweep;
      case 1: return InpEnableOB;
      case 2: return InpEnableFVG;
      case 3: return InpEnableBreaker;
      case 4: return InpEnableTurtle;
      case 5: return InpEnableOTE;
      case 6: return InpEnableCont;
     }
   return false;
  }
int SlotIndex(int stratNum, bool bull) { return stratNum * 2 + (bull ? 0 : 1); }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   if(!g_symbol.Name(_Symbol))
      return INIT_FAILED;

   for(int i = 0; i < NUM_SLOTS; i++)
     {
      ZeroMemory(g_slots[i]);
      g_slotActive[i] = false;
     }

   if(!InpShowDashboard)
      DeleteObjectsByPrefix(DASH_PREFIX);

   if(InpHistoryDays > 0 && DrawingsAllowed())
      ScanHistory();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   DeleteObjectsByPrefix(OBJ_PREFIX);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Drawings are anchored to LTF bar widths; only show them when the |
//| chart period matches the strategy timeframe (otherwise the tiny  |
//| LTF objects get crammed together into clutter).                  |
//+------------------------------------------------------------------+
bool DrawingsAllowed() { return InpShowDrawings && (_Period == InpLTF_Timeframe); }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_symbol.RefreshRates();

   datetime curBarTime = iTime(_Symbol, InpLTF_Timeframe, 0);
   bool newBar = (curBarTime != g_lastLTFBarTime);

   if(newBar)
     {
      g_lastLTFBarTime = curBarTime;
      ScanAllStrategies();
     }

   // Touch mode evaluates every tick so a wick into a zone fires immediately,
   // not only on bar close. The setups themselves are still detected on closed
   // bars (in ScanAllStrategies) -- only the entry trigger is intrabar here.
   if(InpAutoTrade && InpTriggerMode == TRIGGER_TOUCH)
      TradeBestSetup(true);

   if(InpShowDashboard)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Per-bar: compute bias, run every enabled detector for both       |
//| directions, draw the results, then (optionally) trade.           |
//+------------------------------------------------------------------+
void ScanAllStrategies()
  {
   GetHTFBias(g_htfBullBias, g_htfBearBias);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);              // index 0 = newest, like ict.py's reversed series
   int total = CopyRates(_Symbol, InpLTF_Timeframe, 1, 200, rates);
   if(total < 2 * InpSwingLeftRight + 10)
      return;

   for(int n = 0; n < NUM_STRATEGIES; n++)
     {
      for(int d = 0; d < 2; d++)
        {
         bool bull = (d == 0);
         int slot = SlotIndex(n, bull);

         bool allowed = StrategyEnabled(n) && (bull ? g_htfBullBias : g_htfBearBias);

         IctSetup s;
         ZeroMemory(s);
         bool found = allowed && RunDetector(n, bull, rates, total, s);

         if(found)
           {
            g_slots[slot]      = s;
            g_slotActive[slot] = true;
            if(DrawingsAllowed())
               DrawSetup(s);
            else
               ClearSlotDrawing(n, bull);
           }
         else
           {
            g_slotActive[slot] = false;
            ClearSlotDrawing(n, bull);
           }
        }
     }

   if(InpAutoTrade && InpTriggerMode == TRIGGER_CLOSE)
      TradeBestSetup(false);
  }

//+------------------------------------------------------------------+
//| Dispatch to the right detector for a strategy number.             |
//+------------------------------------------------------------------+
bool RunDetector(int n, bool bull, const MqlRates &r[], int total, IctSetup &o)
  {
   switch(n)
     {
      case 0: return Detect_SweepMSS(r, total, bull, o);
      case 1: return Detect_OrderBlock(r, total, bull, o);
      case 2: return Detect_FVG(r, total, bull, o);
      case 3: return Detect_Breaker(r, total, bull, o);
      case 4: return Detect_TurtleSoup(r, total, bull, o);
      case 5: return Detect_OTE(r, total, bull, o);
      case 6: return Detect_Continuation(r, total, bull, o);
     }
   return false;
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

   for(int i = InpSwingLeftRight; i < n - InpSwingLeftRight; i++)
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

   if(higherHigh && higherLow)      { bullBias = true;  bearBias = false; }
   else if(lowerHigh && lowerLow)   { bullBias = false; bearBias = true;  }
   // else mixed -> both remain true
  }

//+------------------------------------------------------------------+
//| Swing helpers (identical to the original EA)                      |
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
//| Index of the most recent confirmed swing high/low, or -1.         |
//+------------------------------------------------------------------+
int RecentSwing(const MqlRates &r[], int total, bool wantHigh)
  {
   int k = InpSwingLeftRight;
   for(int i = k; i < total - k; i++)
     {
      if(wantHigh && IsSwingHigh(r, i, k))   return i;
      if(!wantHigh && IsSwingLow(r, i, k))   return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Next external liquidity beyond entry = the draw-on-liquidity TP.  |
//+------------------------------------------------------------------+
bool FindLiquidityTarget(const MqlRates &r[], int total, bool bullish, double entryPrice, double &target)
  {
   int k = InpSwingLeftRight;
   for(int i = k; i < total - k; i++)
     {
      if(bullish && IsSwingHigh(r, i, k) && r[i].high > entryPrice)  { target = r[i].high; return true; }
      if(!bullish && IsSwingLow(r, i, k) && r[i].low < entryPrice)   { target = r[i].low;  return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| stage + tested helpers (mirror ict.py _stage_from_zone /          |
//| _zone_tested). buffer = InpSweepBufferPoints for every strategy.  |
//+------------------------------------------------------------------+
string StageFromZone(const MqlRates &r[], double lo, double hi)
  {
   double price = r[0].close;
   double buf   = InpSweepBufferPoints * g_symbol.Point();
   return (lo - buf <= price && price <= hi + buf) ? "ready" : "forming";
  }

bool ZoneTested(const MqlRates &r[], int refIdx, double lo, double hi)
  {
   if(refIdx <= 0)
      return false;
   double buf = InpSweepBufferPoints * g_symbol.Point();
   double zlo = lo - buf, zhi = hi + buf;
   for(int idx = 0; idx < refIdx; idx++)
      if(r[idx].low <= zhi && r[idx].high >= zlo)
         return true;
   return false;
  }

double ComputeRR(double entry, double sl, double tp)
  {
   double d = MathAbs(entry - sl);
   return (d > 0) ? MathAbs(tp - entry) / d : 0.0;
  }

int TimeToIndex(const MqlRates &r[], int total, datetime t)
  {
   for(int i = 0; i < total; i++)
      if(r[i].time == t)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Strategy 1: Liquidity Sweep -> MSS -> FVG (stages: swept/mss/ready)|
//+------------------------------------------------------------------+
bool FindLiquiditySweep(const MqlRates &r[], int total, bool bullish, int &sweepIdx, double &sweepPrice, double &liquidityLevel, datetime &liquidityTime)
  {
   int k = InpSwingLeftRight;
   for(int i = k + 1; i < total - k; i++)
     {
      if(bullish && IsSwingLow(r, i, k))
        {
         double level = r[i].low;
         for(int j = i - k - 1; j >= 0; j--)
            if(r[j].low < level && r[j].close > level)
              { sweepIdx = j; sweepPrice = r[j].low; liquidityLevel = level; liquidityTime = r[i].time; return true; }
        }
      if(!bullish && IsSwingHigh(r, i, k))
        {
         double level = r[i].high;
         for(int j = i - k - 1; j >= 0; j--)
            if(r[j].high > level && r[j].close < level)
              { sweepIdx = j; sweepPrice = r[j].high; liquidityLevel = level; liquidityTime = r[i].time; return true; }
        }
     }
   return false;
  }

bool FindMarketStructureShift(const MqlRates &r[], int total, bool bullish, int sweepIdx, int &mssIdx, double &mssLevel)
  {
   int k = InpSwingLeftRight;
   double refLevel = 0; bool found = false;
   for(int i = sweepIdx - k; i >= k; i--)
     {
      if(bullish && IsSwingHigh(r, i, k))  { refLevel = r[i].high; found = true; break; }
      if(!bullish && IsSwingLow(r, i, k))  { refLevel = r[i].low;  found = true; break; }
     }
   if(!found)
      return false;
   for(int j = sweepIdx - 1; j >= 0; j--)
     {
      if(bullish && r[j].close > refLevel)  { mssIdx = j; mssLevel = refLevel; return true; }
      if(!bullish && r[j].close < refLevel) { mssIdx = j; mssLevel = refLevel; return true; }
     }
   return false;
  }

bool FindEntryFVG(const MqlRates &r[], int sweepIdx, int mssIdx, bool bullish, double &fvgHigh, double &fvgLow, datetime &fvgTimeLeft, datetime &fvgTimeRight)
  {
   double minSize = InpMinFVGSizePoints * g_symbol.Point();
   int searchFrom = MathMin(sweepIdx, mssIdx + InpMaxBarsForFVGSearch);
   for(int i = mssIdx + 1; i < searchFrom; i++)
     {
      if(i - 1 < 0 || i + 1 >= ArraySize(r))
         continue;
      double gapLow, gapHigh;
      if(bullish) { gapLow = r[i - 1].low;  gapHigh = r[i + 1].high; }
      else        { gapHigh = r[i - 1].high; gapLow = r[i + 1].low;  }
      if(gapLow > gapHigh && (gapLow - gapHigh) >= minSize)
        {
         fvgLow = gapHigh; fvgHigh = gapLow;
         fvgTimeLeft = r[i + 1].time; fvgTimeRight = r[i - 1].time;
         return true;
        }
     }
   return false;
  }

void ComputeEntrySL_Sweep(bool bullish, double fvgHigh, double fvgLow, double sweepExtreme, double &entry, double &sl)
  {
   double point = g_symbol.Point();
   entry = bullish
           ? (InpEntryAtMidpoint ? (fvgHigh + fvgLow) / 2.0 : fvgLow)
           : (InpEntryAtMidpoint ? (fvgHigh + fvgLow) / 2.0 : fvgHigh);
   sl = bullish ? sweepExtreme - InpSweepBufferPoints * point
                : sweepExtreme + InpSweepBufferPoints * point;
  }

bool Detect_SweepMSS(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   int sweepIdx; double sweepPrice, liqLevel; datetime liqTime;
   if(!FindLiquiditySweep(r, total, bullish, sweepIdx, sweepPrice, liqLevel, liqTime))
      return false;
   if(sweepIdx > InpMaxBarsAfterSweep)
      return false;

   FillSetupCommon(o, 0, bullish);
   o.isZone = false; o.stage = "sweep_only"; o.tested = false; o.hasTrade = false;
   o.zoneHigh = liqLevel; o.zoneLow = liqLevel; o.zoneTime = liqTime;

   int mssIdx; double mssLevel;
   if(!FindMarketStructureShift(r, total, bullish, sweepIdx, mssIdx, mssLevel))
      return true; // stays at sweep_only

   o.stage = "mss_confirmed";
   o.zoneHigh = mssLevel; o.zoneLow = mssLevel; o.zoneTime = r[mssIdx].time;

   double fvgHigh, fvgLow; datetime ftl, ftr;
   if(!FindEntryFVG(r, sweepIdx, mssIdx, bullish, fvgHigh, fvgLow, ftl, ftr))
      return true; // stays at mss_confirmed

   o.stage = "ready"; o.isZone = true;
   o.zoneHigh = fvgHigh; o.zoneLow = fvgLow; o.zoneTime = ftl;
   int fvgIdx = TimeToIndex(r, total, ftr);
   if(fvgIdx < 0) fvgIdx = 0;
   o.tested = ZoneTested(r, fvgIdx, fvgLow, fvgHigh);

   double entry, sl;
   ComputeEntrySL_Sweep(bullish, fvgHigh, fvgLow, sweepPrice, entry, sl);
   double slDist = MathAbs(entry - sl);
   double tp, tgt;
   if(FindLiquidityTarget(r, total, bullish, entry, tgt))  tp = tgt;
   else tp = bullish ? entry + slDist * InpFallbackRR : entry - slDist * InpFallbackRR;

   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 2: Order Block                                           |
//+------------------------------------------------------------------+
bool Detect_OrderBlock(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   double zoneLo, zoneHi, entry, sl, tp, tgt;
   int ob = -1;

   if(bullish)
     {
      int sh = RecentSwing(r, total, true);
      if(sh < 0) return false;
      double level = r[sh].high;
      int brk = -1;
      for(int b = sh - 1; b >= 0; b--) if(r[b].close > level) { brk = b; break; }
      if(brk < 0) return false;
      int hi = MathMin(sh + 2, total);
      for(int oo = brk + 1; oo < hi; oo++) if(r[oo].close < r[oo].open) { ob = oo; break; }
      if(ob < 0) return false;
      zoneLo = r[ob].low; zoneHi = r[ob].high;
      entry = (zoneLo + zoneHi) / 2.0; sl = zoneLo - InpSweepBufferPoints * pt;
      if(FindLiquidityTarget(r, total, true, entry, tgt)) tp = tgt; else tp = entry + MathAbs(entry - sl) * InpFallbackRR;
     }
   else
     {
      int slw = RecentSwing(r, total, false);
      if(slw < 0) return false;
      double level = r[slw].low;
      int brk = -1;
      for(int b = slw - 1; b >= 0; b--) if(r[b].close < level) { brk = b; break; }
      if(brk < 0) return false;
      int hi = MathMin(slw + 2, total);
      for(int oo = brk + 1; oo < hi; oo++) if(r[oo].close > r[oo].open) { ob = oo; break; }
      if(ob < 0) return false;
      zoneLo = r[ob].low; zoneHi = r[ob].high;
      entry = (zoneLo + zoneHi) / 2.0; sl = zoneHi + InpSweepBufferPoints * pt;
      if(FindLiquidityTarget(r, total, false, entry, tgt)) tp = tgt; else tp = entry - MathAbs(entry - sl) * InpFallbackRR;
     }

   FillSetupCommon(o, 1, bullish);
   o.isZone = true; o.zoneHigh = zoneHi; o.zoneLow = zoneLo; o.zoneTime = r[ob].time;
   o.stage = StageFromZone(r, zoneLo, zoneHi); o.tested = ZoneTested(r, ob, zoneLo, zoneHi);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 3: standalone Fair Value Gap                             |
//+------------------------------------------------------------------+
bool Detect_FVG(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   double minSize = InpMinFVGSizePoints * pt;
   double price = r[0].close;
   double buf = InpSweepBufferPoints * pt;
   int lim = MathMin(total - 1, FVG_SCAN_BARS);

   for(int i = 1; i < lim; i++)
     {
      double olderHigh = r[i + 1].high, olderLow = r[i + 1].low;
      double newerHigh = r[i - 1].high, newerLow = r[i - 1].low;
      double zoneLo, zoneHi, entry, sl, tp, tgt;

      if(bullish)
        {
         if(newerLow - olderHigh < minSize) continue;
         zoneLo = olderHigh; zoneHi = newerLow;
         if(price < zoneLo - buf) continue;
         entry = (zoneLo + zoneHi) / 2.0; sl = zoneLo - InpSweepBufferPoints * pt;
         if(FindLiquidityTarget(r, total, true, entry, tgt)) tp = tgt; else tp = entry + MathAbs(entry - sl) * InpFallbackRR;
        }
      else
        {
         if(olderLow - newerHigh < minSize) continue;
         zoneLo = newerHigh; zoneHi = olderLow;
         if(price > zoneHi + buf) continue;
         entry = (zoneLo + zoneHi) / 2.0; sl = zoneHi + InpSweepBufferPoints * pt;
         if(FindLiquidityTarget(r, total, false, entry, tgt)) tp = tgt; else tp = entry - MathAbs(entry - sl) * InpFallbackRR;
        }

      FillSetupCommon(o, 2, bullish);
      o.isZone = true; o.zoneHigh = zoneHi; o.zoneLow = zoneLo; o.zoneTime = r[i + 1].time;
      o.stage = StageFromZone(r, zoneLo, zoneHi); o.tested = ZoneTested(r, i - 1, zoneLo, zoneHi);
      SetTrade(o, entry, sl, tp);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Strategy 4: Breaker Block                                         |
//+------------------------------------------------------------------+
bool Detect_Breaker(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   int sweepIdx; double sweepPrice, liqLevel; datetime liqTime;
   if(!FindLiquiditySweep(r, total, bullish, sweepIdx, sweepPrice, liqLevel, liqTime))
      return false;
   if(sweepIdx > InpMaxBarsAfterSweep)
      return false;
   int mssIdx; double mssLevel;
   if(!FindMarketStructureShift(r, total, bullish, sweepIdx, mssIdx, mssLevel))
      return false;
   int loI = mssIdx + 1, hiI = sweepIdx;
   if(loI > hiI) return false;

   int ob = -1;
   double zoneLo, zoneHi, entry, sl, tp, tgt;
   if(bullish)
     {
      double best = DBL_MAX;
      for(int oo = loI; oo <= hiI; oo++) if(r[oo].close < r[oo].open && r[oo].low < best) { best = r[oo].low; ob = oo; }
      if(ob < 0) return false;
      zoneLo = r[ob].low; zoneHi = r[ob].high;
      entry = (zoneLo + zoneHi) / 2.0; sl = zoneLo - InpSweepBufferPoints * pt;
      if(FindLiquidityTarget(r, total, true, entry, tgt)) tp = tgt; else tp = entry + MathAbs(entry - sl) * InpFallbackRR;
     }
   else
     {
      double best = -DBL_MAX;
      for(int oo = loI; oo <= hiI; oo++) if(r[oo].close > r[oo].open && r[oo].high > best) { best = r[oo].high; ob = oo; }
      if(ob < 0) return false;
      zoneLo = r[ob].low; zoneHi = r[ob].high;
      entry = (zoneLo + zoneHi) / 2.0; sl = zoneHi + InpSweepBufferPoints * pt;
      if(FindLiquidityTarget(r, total, false, entry, tgt)) tp = tgt; else tp = entry - MathAbs(entry - sl) * InpFallbackRR;
     }

   FillSetupCommon(o, 3, bullish);
   o.isZone = true; o.zoneHigh = zoneHi; o.zoneLow = zoneLo; o.zoneTime = r[ob].time;
   o.stage = StageFromZone(r, zoneLo, zoneHi); o.tested = ZoneTested(r, ob, zoneLo, zoneHi);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 5: Turtle Soup (false break of the prior N-bar range)    |
//+------------------------------------------------------------------+
bool Detect_TurtleSoup(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   int k = InpSwingLeftRight;
   if(total < TURTLE_LOOKBACK + 4)
      return false;

   for(int i = 0; i < k + 3; i++)
     {
      if(i + 1 + TURTLE_LOOKBACK > total)
         break;
      double winHi = -DBL_MAX, winLo = DBL_MAX;
      for(int j = i + 1; j < i + 1 + TURTLE_LOOKBACK; j++)
        {
         if(r[j].high > winHi) winHi = r[j].high;
         if(r[j].low  < winLo) winLo = r[j].low;
        }
      double entry, sl, tp; bool ok = false;
      if(bullish && r[i].low < winLo && r[i].close > winLo)        { entry = r[i].close; sl = r[i].low - InpSweepBufferPoints * pt;  tp = winHi; ok = true; }
      else if(!bullish && r[i].high > winHi && r[i].close < winHi) { entry = r[i].close; sl = r[i].high + InpSweepBufferPoints * pt; tp = winLo; ok = true; }
      if(!ok)
         continue;

      double ext = bullish ? r[i].low : r[i].high;
      FillSetupCommon(o, 4, bullish);
      o.isZone = false; o.zoneHigh = ext; o.zoneLow = ext; o.zoneTime = r[i].time;
      o.stage = (i <= 2) ? "ready" : "forming";
      o.tested = ZoneTested(r, i, ext, ext);
      SetTrade(o, entry, sl, tp);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Strategy 6: Optimal Trade Entry (0.62-0.79 fib of the impulse)    |
//+------------------------------------------------------------------+
bool Detect_OTE(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   int sh = RecentSwing(r, total, true);
   int slw = RecentSwing(r, total, false);
   if(sh < 0 || slw < 0)
      return false;

   double zHi, zLo, entry, sl, tp;
   if(bullish)
     {
      if(!(slw > sh)) return false;             // up leg: low older than high
      double legLow = r[slw].low, legHigh = r[sh].high;
      double rng = legHigh - legLow; if(rng <= 0) return false;
      zHi = legHigh - 0.62 * rng; zLo = legHigh - 0.79 * rng;
      entry = (zHi + zLo) / 2.0; sl = legLow - InpSweepBufferPoints * pt; tp = legHigh;
     }
   else
     {
      if(!(sh > slw)) return false;             // down leg: high older than low
      double legHigh = r[sh].high, legLow = r[slw].low;
      double rng = legHigh - legLow; if(rng <= 0) return false;
      zLo = legLow + 0.62 * rng; zHi = legLow + 0.79 * rng;
      entry = (zHi + zLo) / 2.0; sl = legHigh + InpSweepBufferPoints * pt; tp = legLow;
     }

   int refIdx = bullish ? sh : slw;
   FillSetupCommon(o, 5, bullish);
   o.isZone = true; o.zoneHigh = zHi; o.zoneLow = zLo; o.zoneTime = r[refIdx].time;
   o.stage = StageFromZone(r, zLo, zHi); o.tested = ZoneTested(r, refIdx, zLo, zHi);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 7: Continuation Retest (break of a swing, retested)      |
//+------------------------------------------------------------------+
bool Detect_Continuation(const MqlRates &r[], int total, bool bullish, IctSetup &o)
  {
   double pt = g_symbol.Point();
   double price = r[0].close;
   double buf = InpSweepBufferPoints * pt;
   double invalidation = buf * 3;
   double level, entry, sl, tp, tgt;
   int swingIdx = -1, brk = -1;

   if(bullish)
     {
      int sh = RecentSwing(r, total, true);
      if(sh < 0) return false;
      swingIdx = sh; level = r[sh].high;
      for(int b = sh - 1; b >= 0; b--) if(r[b].close > level) { brk = b; break; }
      if(brk < 0 || brk > InpMaxBarsAfterSweep) return false;
      if(price < level - invalidation) return false;
      entry = level; sl = level - invalidation;
      if(FindLiquidityTarget(r, total, true, entry, tgt)) tp = tgt; else tp = entry + MathAbs(entry - sl) * InpFallbackRR;
     }
   else
     {
      int slw = RecentSwing(r, total, false);
      if(slw < 0) return false;
      swingIdx = slw; level = r[slw].low;
      for(int b = slw - 1; b >= 0; b--) if(r[b].close < level) { brk = b; break; }
      if(brk < 0 || brk > InpMaxBarsAfterSweep) return false;
      if(price > level + invalidation) return false;
      entry = level; sl = level + invalidation;
      if(FindLiquidityTarget(r, total, false, entry, tgt)) tp = tgt; else tp = entry - MathAbs(entry - sl) * InpFallbackRR;
     }

   FillSetupCommon(o, 6, bullish);
   o.isZone = false; o.zoneHigh = level; o.zoneLow = level; o.zoneTime = r[swingIdx].time;
   o.stage = StageFromZone(r, level, level); o.tested = ZoneTested(r, brk, level, level);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Setup helpers                                                     |
//+------------------------------------------------------------------+
void FillSetupCommon(IctSetup &o, int stratNum, bool bullish)
  {
   o.valid     = true;
   o.stratNum  = stratNum;
   o.shortCode = ShortCode(stratNum);
   o.fullName  = FullName(stratNum);
   o.bullish   = bullish;
   o.hasTrade  = false;
   o.tested    = false;
  }

void SetTrade(IctSetup &o, double entry, double sl, double tp)
  {
   int dg = g_symbol.Digits();
   o.entry    = NormalizeDouble(entry, dg);
   o.sl       = NormalizeDouble(sl, dg);
   o.tp       = NormalizeDouble(tp, dg);
   o.rr       = ComputeRR(o.entry, o.sl, o.tp);
   o.hasTrade = (MathAbs(o.entry - o.sl) > 0);
  }

//+------------------------------------------------------------------+
//| Auto-trade: take the single best actionable setup, one at a time.|
//| touchMode=false -> the closed candle must be inside the zone     |
//|   (stage "ready"); touchMode=true -> live price (incl. a wick)   |
//|   is currently inside the zone band.                             |
//| Selection: triggered + actionable, prefer untested, then top RR. |
//+------------------------------------------------------------------+
void TradeBestSetup(bool touchMode)
  {
   if(PositionExistsForEA())
      return;
   if((int)g_symbol.Spread() > InpMaxSpreadPoints)
      return;

   double buf = InpSweepBufferPoints * g_symbol.Point();
   double px  = g_symbol.Bid();

   int best = -1;
   for(int i = 0; i < NUM_SLOTS; i++)
     {
      if(!g_slotActive[i]) continue;
      IctSetup s = g_slots[i];
      if(!s.hasTrade) continue;
      bool triggered = touchMode
                       ? (s.zoneLow - buf <= px && px <= s.zoneHigh + buf)
                       : (s.stage == "ready");
      if(!triggered) continue;
      if(InpSkipTestedSetups && s.tested) continue;
      if(best < 0) { best = i; continue; }
      IctSetup b = g_slots[best];
      // prefer the untested one; if equal, prefer the higher reward:risk
      if(b.tested && !s.tested) { best = i; continue; }
      if(b.tested == s.tested && s.rr > b.rr) best = i;
     }
   if(best < 0)
      return;

   IctSetup t = g_slots[best];
   double slDist = MathAbs(t.entry - t.sl);
   double lots = CalculateLotSize(slDist);
   if(lots <= 0)
      return;

   string cmt = "ICTS " + t.shortCode + (t.bullish ? " buy" : " sell");
   bool ok = t.bullish
             ? g_trade.Buy(lots, _Symbol, 0.0, t.sl, t.tp, cmt)
             : g_trade.Sell(lots, _Symbol, 0.0, t.sl, t.tp, cmt);
   if(ok)
      PrintFormat("[ICTS] %s %s entered: lots=%.2f sl=%.5f tp=%.5f rr=%.2f tested=%s",
                  t.shortCode, (t.bullish ? "BUY" : "SELL"), lots, t.sl, t.tp, t.rr,
                  (t.tested ? "yes" : "no"));
  }

bool PositionExistsForEA()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      return true;
     }
   return false;
  }

double CalculateLotSize(double slDistancePrice)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return 0;
   double lossPerLot = slDistancePrice * (tickValue / tickSize);
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
//| Drawing                                                          |
//+------------------------------------------------------------------+
string SlotBase(int stratNum, bool bull)
  {
   return OBJ_PREFIX + ShortCode(stratNum) + "_" + (bull ? "B" : "S") + "_";
  }

void ClearSlotDrawing(int stratNum, bool bull)
  {
   DeleteObjectsByPrefix(SlotBase(stratNum, bull));
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

void DrawSetup(const IctSetup &s)
  {
   string base = SlotBase(s.stratNum, s.bullish);
   DeleteObjectsByPrefix(base);                       // replace previous drawing for this slot

   color col = s.bullish ? InpColorBull : InpColorBear;
   datetime tRight = TimeCurrent() + PeriodSeconds(InpLTF_Timeframe) * InpZoneExtendBars;

   string tag = s.shortCode + " " + s.stage + (s.tested ? " (tested)" : "")
              + (s.hasTrade ? "  rr " + DoubleToString(s.rr, 1) : "");

   if(s.isZone)
     {
      string zname = base + "Zone";
      ObjectCreate(0, zname, OBJ_RECTANGLE, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneLow);
      ObjectSetInteger(0, zname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, zname, OBJPROP_FILL, true);
      ObjectSetInteger(0, zname, OBJPROP_BACK, true);
      ObjectSetInteger(0, zname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, zname, OBJPROP_WIDTH, 1);

      string lname = base + "Lbl";
      ObjectCreate(0, lname, OBJ_TEXT, 0, s.zoneTime, s.zoneHigh);
      ObjectSetString(0, lname, OBJPROP_TEXT, " " + tag);
      ObjectSetInteger(0, lname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, lname, OBJPROP_ANCHOR, s.bullish ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);
     }
   else
     {
      string lvlname = base + "Level";
      ObjectCreate(0, lvlname, OBJ_TREND, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneHigh);
      ObjectSetInteger(0, lvlname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, lvlname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_DASH);
      ObjectSetInteger(0, lvlname, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, lvlname, OBJPROP_RAY_RIGHT, false);

      string lname = base + "Lbl";
      ObjectCreate(0, lname, OBJ_TEXT, 0, s.zoneTime, s.zoneHigh);
      ObjectSetString(0, lname, OBJPROP_TEXT, " " + tag);
      ObjectSetInteger(0, lname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);
     }

   // entry / SL / TP lines only for ready, actionable setups (keeps the chart clean)
   if(InpDrawTradeLines && s.hasTrade && s.stage == "ready")
     {
      DrawHLine(base + "Entry", s.zoneTime, tRight, s.entry, InpColorEntry, STYLE_DASH,  "Entry");
      DrawHLine(base + "SL",    s.zoneTime, tRight, s.sl,    InpColorSL,    STYLE_SOLID, "SL");
      DrawHLine(base + "TP",    s.zoneTime, tRight, s.tp,    InpColorTP,    STYLE_SOLID, "TP");
     }
  }

void DrawHLine(string name, datetime t1, datetime t2, double price, color col, ENUM_LINE_STYLE style, string tag)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);

   string lbl = name + "Lbl";
   ObjectCreate(0, lbl, OBJ_TEXT, 0, t2, price);
   ObjectSetString(0, lbl, OBJPROP_TEXT, " " + tag + " " + DoubleToString(price, g_symbol.Digits()));
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, col);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 7);
  }

//+------------------------------------------------------------------+
//| One-shot historical scan: runs once on init (and again whenever  |
//| an input changes, since that re-fires OnInit) -- never per-tick. |
//| Single ascending CopyRates fetch is reversed into one descending |
//| array ONCE, then each "as of bar j" view fed to the live         |
//| detectors is just a cheap slice of that array, not a fresh       |
//| CopyRates. Drawings are capped per strategy+direction (no entry/ |
//| SL/TP lines, 2 objects per find) to keep object count and scan   |
//| time bounded regardless of how many days are requested.         |
//+------------------------------------------------------------------+
void ScanHistory()
  {
   DeleteObjectsByPrefix(OBJ_PREFIX + "HIST_");

   datetime fromTime = TimeCurrent() - (long)InpHistoryDays * 86400;
   MqlRates asc[];
   ArraySetAsSeries(asc, false);            // ascending: index 0 = oldest
   int total = CopyRates(_Symbol, InpLTF_Timeframe, fromTime, TimeCurrent(), asc);
   int k = InpSwingLeftRight;
   if(total < 2 * k + 30)
      return;

   int cap = 3000;                          // hard ceiling on worst-case scan cost
   if(total > cap)
     {
      int drop = total - cap;
      for(int i = 0; i < cap; i++)
         asc[i] = asc[i + drop];
      total = cap;
     }

   MqlRates desc[];
   ArrayResize(desc, total);
   for(int i = 0; i < total; i++)
      desc[i] = asc[total - 1 - i];

   int windowLen = 200;                     // matches the live scan's lookback depth
   int counts[NUM_SLOTS];
   datetime lastDrawTime[NUM_SLOTS];
   for(int i = 0; i < NUM_SLOTS; i++) { counts[i] = 0; lastDrawTime[i] = 0; }

   for(int j = windowLen; j < total - 1; j++)
     {
      int pos  = total - 1 - j;
      int wlen = MathMin(windowLen, total - pos);

      MqlRates win[];
      ArrayResize(win, wlen);
      for(int w = 0; w < wlen; w++)
         win[w] = desc[pos + w];

      for(int n = 0; n < NUM_STRATEGIES; n++)
        {
         if(!StrategyEnabled(n))
            continue;
         for(int d = 0; d < 2; d++)
           {
            bool bull = (d == 0);
            int slot = SlotIndex(n, bull);
            if(counts[slot] >= InpMaxHistoricalPerSetup)
               continue;

            IctSetup s;
            ZeroMemory(s);
            if(!RunDetector(n, bull, win, wlen, s))
               continue;
            if(s.stage != "ready" || s.zoneTime == lastDrawTime[slot])
               continue;                    // same persisting setup as the previous bar -- skip duplicate

            DrawHistoricalSetup(s, counts[slot]);
            counts[slot]++;
            lastDrawTime[slot] = s.zoneTime;
           }
        }
     }
  }

void DrawHistoricalSetup(const IctSetup &s, int seq)
  {
   string base = OBJ_PREFIX + "HIST_" + s.shortCode + "_" + (s.bullish ? "B" : "S") + "_" + IntegerToString(seq) + "_";
   color  col  = s.bullish ? InpColorHistBull : InpColorHistBear;   // brighter/more saturated than live colors: historical zones are outline-only with no fill behind them
   datetime tRight = s.zoneTime + PeriodSeconds(InpLTF_Timeframe) * InpZoneExtendBars;
   string tag = "H " + s.shortCode + (s.tested ? " (tested)" : "");

   if(s.isZone)
     {
      string zname = base + "Zone";
      ObjectCreate(0, zname, OBJ_RECTANGLE, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneLow);
      ObjectSetInteger(0, zname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, zname, OBJPROP_FILL, false);   // unfilled outline: lighter to render, visually distinct from live zones
      ObjectSetInteger(0, zname, OBJPROP_BACK, true);
      ObjectSetInteger(0, zname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, zname, OBJPROP_WIDTH, 2);
     }
   else
     {
      string lname = base + "Level";
      ObjectCreate(0, lname, OBJ_TREND, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneHigh);
      ObjectSetInteger(0, lname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, lname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_DASH);
      ObjectSetInteger(0, lname, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, lname, OBJPROP_RAY_RIGHT, false);
     }

   string lblName = base + "Lbl";
   ObjectCreate(0, lblName, OBJ_TEXT, 0, s.zoneTime, s.zoneHigh);
   ObjectSetString(0, lblName, OBJPROP_TEXT, " " + tag);
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, col);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void EnsureDashboardObjects()
  {
   if(ObjectFind(0, DASH_PREFIX + "BG") >= 0)
      return;

   int x = 10, y = 20, w = 330, rowH = 16;
   // Title, Mode, TF, Bias, 7 strategy rows, Acct, Pos, Spread
   string rows[] = {"Title","Mode","TF","Bias",
                    "S0","S1","S2","S3","S4","S5","S6",
                    "Acct","Pos","Spread","Hist"};

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

string StageShort(string stage)
  {
   if(stage == "ready")         return "READY";
   if(stage == "forming")       return "form";
   if(stage == "sweep_only")    return "swept";
   if(stage == "mss_confirmed") return "mss";
   return "-";
  }

string StrategyRowText(int stratNum)
  {
   string code = ShortCode(stratNum);
   string parts[2];
   for(int d = 0; d < 2; d++)
     {
      bool bull = (d == 0);
      int slot = SlotIndex(stratNum, bull);
      string side = bull ? "B " : "S ";
      if(!StrategyEnabled(stratNum))
         parts[d] = side + "off";
      else if(g_slotActive[slot])
         parts[d] = side + StageShort(g_slots[slot].stage) + (g_slots[slot].tested ? "*" : "");
      else
         parts[d] = side + "-";
     }
   return StringFormat("%-6s %-12s %-12s", code, parts[0], parts[1]);
  }

void UpdateDashboard()
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

   SetDashLine("Title", "=== MMBM ICT Suite (7 strategies) ===", clrYellow);
   SetDashLine("Mode",  "Mode: " + (InpAutoTrade ? ("AUTO-TRADE (" + (InpTriggerMode == TRIGGER_TOUCH ? "touch" : "close") + ")") : "SCAN ONLY"),
               InpAutoTrade ? clrLimeGreen : clrOrange);
   SetDashLine("TF",    "Chart: " + EnumToString((ENUM_TIMEFRAMES)_Period) + (tfMatch ? "  [OK]" : "  [MISMATCH-drawings hidden]"),
               tfMatch ? clrWhite : clrRed);
   SetDashLine("Bias",  "HTF bias: Buy " + (g_htfBullBias ? "OK" : "blk") + " | Sell " + (g_htfBearBias ? "OK" : "blk"), clrWhite);

   for(int n = 0; n < NUM_STRATEGIES; n++)
      SetDashLine("S" + IntegerToString(n), StrategyRowText(n), clrSilver);

   SetDashLine("Acct",  "Equity " + DoubleToString(equity, 2) + " | Bal " + DoubleToString(balance, 2), clrWhite);
   SetDashLine("Pos",   "Open: " + IntegerToString(posCount) + " (" + DoubleToString(posLots, 2) + " lots)  P/L " + DoubleToString(posPnL, 2),
               posPnL >= 0 ? clrLimeGreen : clrRed);
   SetDashLine("Spread","Spread: " + IntegerToString((int)g_symbol.Spread()) + " pts (max " + IntegerToString(InpMaxSpreadPoints) + ")", clrWhite);
   SetDashLine("Hist",  InpHistoryDays > 0 ? ("History: last " + IntegerToString(InpHistoryDays) + "d drawn") : "History: off", clrSilver);
  }
//+------------------------------------------------------------------+
