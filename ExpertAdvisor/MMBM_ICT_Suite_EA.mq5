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
//|  THREE strategies, each long & short. All three share ONE        |
//|  ordered sequence -- a liquidity SWEEP, then a Break Of Structure |
//|  (BOS) in the opposite direction -- and differ only in WHICH zone |
//|  price retests for the entry:                                     |
//|   1. FVG  (Sweep -> BOS -> FVG): entry in the fair value gap left |
//|      inside the BOS impulse leg, in the new bias direction.       |
//|   2. IFVG (Sweep -> BOS -> Inversion FVG): an opposing FVG that   |
//|      the BOS move CLOSED THROUGH (inverted); entry on the retest  |
//|      of that flipped zone.                                        |
//|   3. BRK  (Sweep -> BOS -> Breaker Block): the opposing order     |
//|      block that the BOS move VIOLATED (closed through) and        |
//|      flipped; entry on the retest of that breaker.                |
//|                                                                  |
//|  The Sweep -> BOS sequence is MANDATORY for all three: a zone     |
//|  with no sweep+BOS in front of it is never reported. Each setup   |
//|  is "forming" until price retraces into the zone, then "ready".   |
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

//--- where inside the retest zone the entry price sits ----------------
enum ENUM_ENTRY_MODE
  {
   ENTRY_FIRST_TOUCH = 0,  // Proximal edge: the wick's FIRST touch of the zone (no waiting for a deeper fill)
   ENTRY_MIDPOINT    = 1,  // 50% of the zone (consequent encroachment / CE)
   ENTRY_FAR_EDGE    = 2   // Distal edge: the deepest fill at the far side of the zone
  };

//--- inputs -----------------------------------------------------------
input ENUM_TIMEFRAMES InpHTF_Timeframe        = PERIOD_H4;   // Higher timeframe used for directional bias
input ENUM_TIMEFRAMES InpLTF_Timeframe        = PERIOD_M15;  // Entry timeframe (all detection runs here)
input int             InpSwingLeftRight       = 3;           // Bars each side to confirm a general structure swing
input int             InpLiquiditySwingBars   = 5;           // Bars each side to confirm a PROPER swing for the sweep / BOS / TP liquidity (>= InpSwingLeftRight = stronger, more significant pivots)
input bool            InpRequireHTFBias       = true;        // Only show/trade setups aligned with HTF structure
input double          InpLookbackHours        = 72.0;        // How far back (hours) the live scan searches for liquidity pools/structure -- a pool can take days to build, so this is time-based, not a fixed bar count
input double          InpSweepFreshnessHours  = 6.0;         // Max age (hours) a sweep/break may be and still count as a live, tradable setup
input int             InpMaxBarsForFVGSearch  = 15;          // How far back from the MSS bar to search the entry FVG
input double          InpMinFVGSizePoints     = 30;          // Minimum FVG size (points) to be tradable
input ENUM_ENTRY_MODE InpEntryMode            = ENTRY_FIRST_TOUCH; // Entry price inside the zone: first-touch (wick) / midpoint / far edge
input double          InpSweepBufferPoints    = 20;          // Stop buffer + zone tolerance (points) for all strategies
input double          InpFallbackRR           = 2.0;         // Reward:Risk used when no liquidity target is found
input double          InpMinRR                = 2.0;         // Minimum reward:risk (2.0 = 1:2). Setups below this are skipped (not drawn or traded)

input group "=== Strategy toggles ==="
input bool   InpEnableFVG     = true;   // 1. Sweep -> BOS -> FVG
input bool   InpEnableIFVG    = true;   // 2. Sweep -> BOS -> Inversion FVG
input bool   InpEnableBreaker = true;   // 3. Sweep -> BOS -> Breaker Block

input group "=== Trading ==="
input bool   InpAutoTrade         = false;   // false = scan/draw only (NO orders). true = trade the best ready setup
input ENUM_TRIGGER_MODE InpTriggerMode = TRIGGER_TOUCH; // When to fire: TOUCH (wick into zone, intrabar) or CLOSE (candle closes inside)
input double InpRiskPercent       = 1.0;     // Risk per trade, % of account equity
input int    InpMaxSpreadPoints   = 30;      // Skip entries if spread exceeds this
input bool   InpSkipTestedSetups  = true;    // Don't enter a zone that has already been tested once
input ulong  InpMagicNumber       = 19380002; // Magic number for this EA's orders

input group "=== Context filters (ICT) ==="
input bool   InpUsePremiumDiscount = true;  // Only BUY in discount / SELL in premium of the dealing range
input int    InpPDRangeBars        = 50;    // Bars defining the dealing range (high..low) for premium/discount
input bool   InpUseKillzones       = true;  // Only trade inside the session windows below (broker/SERVER time)
input int    InpKZ1StartHour       = 8;     // Killzone 1 (London) start hour, server time 0-23
input int    InpKZ1EndHour         = 11;    // Killzone 1 (London) end hour, server time (exclusive)
input int    InpKZ2StartHour       = 13;    // Killzone 2 (New York) start hour, server time 0-23
input int    InpKZ2EndHour         = 16;    // Killzone 2 (New York) end hour, server time (exclusive)

input group "=== Chart Visuals ==="
input bool   InpShowDrawings      = true;          // Draw detected setups on the chart
input bool   InpDrawTradeLines    = true;          // Draw entry/SL/TP lines (forming + ready setups)
input int    InpZoneExtendBars    = 12;            // How many bars to extend zone/level drawings to the right
input bool   InpShowDashboard     = true;          // Show the on-chart info panel
input color  InpColorBull         = clrDodgerBlue; // Bullish zone color
input color  InpColorBear         = clrCrimson;    // Bearish zone color
input color  InpColorText         = clrBlack;      // Label TEXT color (use black on a white chart, white on a dark chart)
input color  InpColorSweep        = clrDimGray;    // Sweep level line color
input color  InpColorBOS          = clrDarkViolet; // BOS (break of structure) line color
input color  InpColorEntry        = clrGoldenrod;  // Entry line color
input color  InpColorSL           = clrRed;        // Stop loss line color
input color  InpColorTP           = clrGreen;      // Take profit line color

input group "=== History ==="
input int    InpHistoryDays            = 5;   // Scan and draw completed "ready" setups from the past N days (0 = off)
input int    InpMaxHistoricalPerSetup  = 5;   // Cap historical drawings per strategy+direction (bounds scan time & object count)
input color  InpColorHistBull          = clrDeepSkyBlue; // Historical bullish zone color (distinct from live so past setups stand out)
input color  InpColorHistBear          = clrMagenta;     // Historical bearish zone color

//--- constants --------------------------------------------------------
#define NUM_STRATEGIES    3
#define NUM_SLOTS        (NUM_STRATEGIES * 2)

#define OBJ_PREFIX  "ICTS_"
#define DASH_PREFIX "ICTS_DASH_"

//--- one detected setup ------------------------------------------------
struct IctSetup
  {
   bool     valid;
   int      stratNum;     // 0..2, index into the STRATEGIES order
   string   shortCode;    // "FVG","IFVG","BRK"
   string   fullName;     // human-readable strategy name
   bool     bullish;
   string   stage;        // "ready" (price in the zone now) / "forming" (waiting for retrace)
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
   // anatomy of the setup, for drawing the full picture (sweep -> BOS -> zone)
   double   sweepLevel;   // the liquidity extreme that was swept (the stop sits beyond it)
   datetime sweepTime;    // bar that did the sweep
   double   bosLevel;     // the structure level the BOS broke
   datetime bosTime;      // bar that confirmed the BOS
  };

//--- one sweep->BOS sequence (the shared skeleton every strategy reads) -
// The scan enumerates EVERY valid sequence in the window instead of
// latching the first, so each strategy classifies against all of them.
struct SeqSweepBOS
  {
   int      sweepIdx;     // bar that swept the pool (newest extreme of the raid)
   double   sweepExtreme; // the wick price -- the stop sits beyond THIS
   double   sweepLevel;   // the raided liquidity level (pool)
   datetime sweepTime;    // the swing bar that was raided (anchor for the Sweep line)
   int      bosIdx;       // bar that CLOSED through structure (the break)
   double   bosLevel;     // the broken swing's level
   datetime bosTime;      // the broken swing bar (anchor for the BOS line)
  };

//--- globals -----------------------------------------------------------
CTrade        g_trade;
CSymbolInfo   g_symbol;
datetime      g_lastLTFBarTime = 0;
bool          g_htfBullBias = true;
bool          g_htfBearBias = true;

IctSetup      g_slots[NUM_SLOTS];   // current detections, indexed by SlotIndex()
bool          g_slotActive[NUM_SLOTS];
string        g_slotSkip[NUM_SLOTS]; // why a detected setup was filtered out: "" / "PD" / "RR"

// Dealing range for premium/discount, recomputed once per bar in ScanAllStrategies.
double        g_pdHigh = 0.0, g_pdLow = 0.0, g_pdEquilibrium = 0.0;
bool          g_pdValid = false;

// Shared sweep->BOS gate diagnostic (recomputed once per bar), so the dashboard
// can show WHERE the chain dies instead of every strategy just going blank.
string        g_diagBull = "no swing";
string        g_diagBear = "no swing";

string ShortCode(int n)
  {
   switch(n)
     {
      case 0: return "FVG";
      case 1: return "IFVG";
      case 2: return "BRK";
     }
   return "?";
  }
string FullName(int n)
  {
   switch(n)
     {
      case 0: return "Sweep+BOS+FVG";
      case 1: return "Sweep+BOS+Inversion FVG";
      case 2: return "Sweep+BOS+Breaker Block";
     }
   return "?";
  }
bool StrategyEnabled(int n)
  {
   switch(n)
     {
      case 0: return InpEnableFVG;
      case 1: return InpEnableIFVG;
      case 2: return InpEnableBreaker;
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
      g_slotSkip[i]   = "";
     }

   if(!InpShowDashboard)
      DeleteObjectsByPrefix(DASH_PREFIX);

   if(InpHistoryDays > 0 && DrawingsAllowed())
      ScanHistory();

   // Repopulate live setups immediately on attach/input-change instead of
   // waiting for the next new bar -- OnInit just wiped g_slots above, and
   // OnTick otherwise only rescans when a new bar opens.
   g_lastLTFBarTime = iTime(_Symbol, InpLTF_Timeframe, 0);
   ScanAllStrategies();
   ChartRedraw(0);

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

   // Repaint every tick so created/deleted objects and dashboard text update
   // on their own -- MT5 otherwise defers the visual until the next chart
   // event, which is why stale drawings used to linger until a manual TF
   // change. This does NOT re-detect (that's still bar-close only) or affect
   // trading; it only flushes the visuals.
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Per-bar: compute bias, run every enabled detector for both       |
//| directions, draw the results, then (optionally) trade.           |
//+------------------------------------------------------------------+
void ScanAllStrategies()
  {
   GetHTFBias(g_htfBullBias, g_htfBearBias);
   ComputePremiumDiscount();

   int lookbackBars = HoursToBars(InpLookbackHours);
   lookbackBars = (int)MathMin(lookbackBars, 5000);   // hard ceiling so a huge InpLookbackHours on a small TF can't stall a tick

   MqlRates rates[];
   ArraySetAsSeries(rates, true);              // index 0 = newest, like ict.py's reversed series
   int total = CopyRates(_Symbol, InpLTF_Timeframe, 1, lookbackBars, rates);
   if(total < 2 * InpSwingLeftRight + 10)
      return;

   g_diagBull = DiagSweepBOS(rates, total, true);
   g_diagBear = DiagSweepBOS(rates, total, false);

   for(int n = 0; n < NUM_STRATEGIES; n++)
     {
      for(int d = 0; d < 2; d++)
        {
         bool bull = (d == 0);
         int slot = SlotIndex(n, bull);

         bool allowed = StrategyEnabled(n) && (bull ? g_htfBullBias : g_htfBearBias);

         IctSetup s;
         ZeroMemory(s);
         bool detected = allowed && RunDetector(n, bull, rates, total, s);

         // The structure was found, but two hard filters can still reject it.
         // We remember WHY (PD / RR) so the dashboard can show the outcome
         // instead of the setup just silently vanishing. A rejected setup is
         // neither drawn nor traded.
         //   PD = wrong half of the dealing range (buy in premium / sell in discount)
         //   RR = reward:risk below InpMinRR (default 1:2)
         string skip = "";
         bool found = detected;
         if(detected)
           {
            if(!PremiumDiscountOK(s))                 { found = false; skip = "PD"; }
            else if(s.hasTrade && s.rr < InpMinRR)    { found = false; skip = "RR"; }
           }
         g_slotSkip[slot] = skip;

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
//| Build strategy n's setup from ONE sweep->BOS sequence.            |
//+------------------------------------------------------------------+
bool BuildFromSeq(int n, bool bull, const MqlRates &r[], int total, const SeqSweepBOS &q, IctSetup &o)
  {
   switch(n)
     {
      case 0: return BuildSetup_FVG(r, total, bull, q, o);
      case 1: return BuildSetup_IFVG(r, total, bull, q, o);
      case 2: return BuildSetup_Breaker(r, total, bull, q, o);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| A setup clears the two hard filters (right half of the range +   |
//| min reward:risk). Mirrors the filter the scan loop applies, so   |
//| the enumeration can PREFER a fully-tradable sequence over one    |
//| that would only get rejected.                                    |
//+------------------------------------------------------------------+
bool SetupAcceptable(const IctSetup &s)
  {
   if(!PremiumDiscountOK(s))             return false;
   if(s.hasTrade && s.rr < InpMinRR)     return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Run strategy n over ALL sweep->BOS sequences and return the best |
//| match: the first (freshest) sequence that yields a setup passing |
//| both hard filters. If none passes, fall back to the first        |
//| structurally-valid setup so the dashboard can still report WHY   |
//| it was filtered (PD / RR) instead of just going blank.           |
//+------------------------------------------------------------------+
bool RunDetector(int n, bool bull, const MqlRates &r[], int total, IctSetup &o)
  {
   SeqSweepBOS seqs[];
   int ns = CollectSweepBOS(r, total, bull, seqs);
   if(ns == 0)
      return false;

   IctSetup fallback; bool haveFallback = false;
   for(int s = 0; s < ns; s++)
     {
      IctSetup cand; ZeroMemory(cand);
      if(!BuildFromSeq(n, bull, r, total, seqs[s], cand))
         continue;
      if(SetupAcceptable(cand))           // fully tradable -> take it immediately
        {
         o = cand;
         return true;
        }
      if(!haveFallback)                    // remember the first valid-but-filtered one
        {
         fallback = cand;
         haveFallback = true;
        }
     }
   if(haveFallback)
     {
      o = fallback;                        // scan loop will tag the PD/RR skip reason
      return true;
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
//| Hours -> bars for the current LTF, so lookback/freshness scale    |
//| with the chart period instead of meaning a different real-world   |
//| duration whenever InpLTF_Timeframe changes.                       |
//+------------------------------------------------------------------+
int HoursToBars(double hours)
  {
   int secs = PeriodSeconds(InpLTF_Timeframe);
   if(secs <= 0) return 1;
   return (int)MathMax(1.0, MathRound(hours * 3600.0 / secs));
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
//| Next external liquidity beyond entry = the draw-on-liquidity TP.  |
//+------------------------------------------------------------------+
bool FindLiquidityTarget(const MqlRates &r[], int total, bool bullish, double entryPrice, double &target)
  {
   int k = InpLiquiditySwingBars;   // target a PROPER liquidity pool, not a minor swing
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
//| SHARED SEQUENCE GATE: liquidity Sweep -> Break Of Structure (BOS) |
//| Every one of the three strategies is built on top of this gate;   |
//| the only difference between them is the retest zone it feeds.     |
//+------------------------------------------------------------------+
bool FindLiquiditySweep(const MqlRates &r[], int total, bool bullish, int &sweepIdx, double &sweepPrice, double &liquidityLevel, datetime &liquidityTime)
  {
   int k = InpLiquiditySwingBars;   // a swept pool must be a PROPER swing, not a minor wiggle
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

bool FindMarketStructureShift(const MqlRates &r[], int total, bool bullish, int sweepIdx, int &mssIdx, double &mssLevel, int &refIdx)
  {
   int k = InpLiquiditySwingBars;   // the broken swing (BOS) must be a PROPER pivot too
   // Scan candidate reference swings (nearest the sweep first). The OLD code
   // took only the first swing and gave up if it wasn't broken; here we keep
   // trying more-recent swings until one is actually broken -- so a valid BOS
   // deeper in the leg isn't missed.
   for(int i = sweepIdx - k; i >= k; i--)
     {
      bool isRef = bullish ? IsSwingHigh(r, i, k) : IsSwingLow(r, i, k);
      if(!isRef)
         continue;
      double refLevel = bullish ? r[i].high : r[i].low;
      // The break must come AFTER the reference swing formed (newer bar = lower
      // index), so the search starts at i-1, never between the sweep and swing.
      for(int j = i - 1; j >= 0; j--)
        {
         // mssIdx = the bar that CLOSED through the level (where structure broke);
         // refIdx = the swing bar that DEFINES the level (where the line anchors).
         if(bullish && r[j].close > refLevel)  { mssIdx = j; mssLevel = refLevel; refIdx = i; return true; }
         if(!bullish && r[j].close < refLevel) { mssIdx = j; mssLevel = refLevel; refIdx = i; return true; }
        }
      // this swing was never broken -> try the next (more recent) candidate
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

//+------------------------------------------------------------------+
//| The mandatory Sweep -> BOS gate -- ENUMERATED. Instead of latching |
//| the first sweep and giving up, this walks EVERY proper swing pool  |
//| in the window, and for each one that was both swept (recently      |
//| enough) AND followed by a Break Of Structure, records the full     |
//| sequence. The result is sorted freshest-sweep-first, so the three  |
//| strategies classify against the most actionable sequences first    |
//| but can still fall through to older ones. This is what makes the   |
//| engine read "all the conditions in the market" rather than one.    |
//+------------------------------------------------------------------+
int CollectSweepBOS(const MqlRates &r[], int total, bool bullish, SeqSweepBOS &out[])
  {
   ArrayResize(out, 0);
   int k       = InpLiquiditySwingBars;
   int maxFresh = HoursToBars(InpSweepFreshnessHours);
   int cap     = 40;              // bound on sequences per direction (cost + object sanity)

   for(int i = k + 1; i < total - k; i++)   // pools, most-recent first
     {
      bool isPool = bullish ? IsSwingLow(r, i, k) : IsSwingHigh(r, i, k);
      if(!isPool)
         continue;
      double level = bullish ? r[i].low : r[i].high;

      // First poke through this pool AFTER it formed = the sweep event itself.
      int    sIdx = -1; double sPrice = 0.0;
      for(int j = i - k - 1; j >= 0; j--)
        {
         if(bullish  && r[j].low  < level && r[j].close > level) { sIdx = j; sPrice = r[j].low;  break; }
         if(!bullish && r[j].high > level && r[j].close < level) { sIdx = j; sPrice = r[j].high; break; }
        }
      if(sIdx < 0)                 continue;   // pool never swept
      if(sIdx > maxFresh)          continue;   // sweep too stale to be a live setup -- skip, keep scanning

      int mssIdx, refIdx; double mssLevel;
      if(!FindMarketStructureShift(r, total, bullish, sIdx, mssIdx, mssLevel, refIdx))
         continue;                             // swept but no BOS followed -- not a sequence

      int sz = ArraySize(out);
      ArrayResize(out, sz + 1);
      out[sz].sweepIdx     = sIdx;
      out[sz].sweepExtreme = sPrice;
      out[sz].sweepLevel   = level;
      out[sz].sweepTime    = r[i].time;
      out[sz].bosIdx       = mssIdx;
      out[sz].bosLevel     = mssLevel;
      out[sz].bosTime      = r[refIdx].time;
      if(ArraySize(out) >= cap)
         break;
     }

   // Sort freshest sweep first (smallest sweepIdx). Small array -> simple sort.
   int n = ArraySize(out);
   for(int a = 0; a < n - 1; a++)
      for(int b = 0; b < n - 1 - a; b++)
         if(out[b].sweepIdx > out[b + 1].sweepIdx)
           {
            SeqSweepBOS tmp = out[b]; out[b] = out[b + 1]; out[b + 1] = tmp;
           }
   return n;
  }

//+------------------------------------------------------------------+
//| Diagnostic for the shared gate: how many sweep->BOS sequences     |
//| exist (or, if none, which stage failed), so the dashboard can      |
//| show WHY the strategies are blank instead of just "-".            |
//+------------------------------------------------------------------+
string DiagSweepBOS(const MqlRates &r[], int total, bool bullish)
  {
   SeqSweepBOS seqs[];
   int n = CollectSweepBOS(r, total, bullish, seqs);
   if(n > 0)
      return StringFormat("%d seq (sw@%d)", n, seqs[0].sweepIdx);

   // No full sequence -- report how far the nearest single path got, so the
   // dashboard still says WHY (no pool swept / swept-but-stale / swept-no-BOS).
   int sweepIdx; double sweepPrice, liqLevel; datetime liqTime;
   if(!FindLiquiditySweep(r, total, bullish, sweepIdx, sweepPrice, liqLevel, liqTime))
      return "no sweep";
   if(sweepIdx > HoursToBars(InpSweepFreshnessHours))
      return StringFormat("stale sw@%d", sweepIdx);
   return StringFormat("sw@%d no BOS", sweepIdx);
  }

//+------------------------------------------------------------------+
//| Shared entry/SL/TP for a retest zone. Entry at the 50% (or far    |
//| edge); stop beyond the sweep extreme that triggered the setup;    |
//| target the next external liquidity (or InpFallbackRR).            |
//+------------------------------------------------------------------+
void ComputeZoneTrade(const MqlRates &r[], int total, bool bullish,
                      double zoneHi, double zoneLo, double sweepExtreme,
                      double &entry, double &sl, double &tp)
  {
   double pt = g_symbol.Point();
   // Proximal edge = the side price reaches FIRST on the retest: the top of
   // the zone for a bullish setup (price drops into it from above), the bottom
   // for a bearish setup (price rallies into it from below).
   double proximal = bullish ? zoneHi : zoneLo;
   double distal   = bullish ? zoneLo : zoneHi;
   switch(InpEntryMode)
     {
      case ENTRY_MIDPOINT: entry = (zoneHi + zoneLo) / 2.0; break;
      case ENTRY_FAR_EDGE: entry = distal;                  break;
      default:             entry = proximal;                break;  // ENTRY_FIRST_TOUCH
     }
   sl = bullish ? sweepExtreme - InpSweepBufferPoints * pt
                : sweepExtreme + InpSweepBufferPoints * pt;
   double slDist = MathAbs(entry - sl);
   double tgt;
   if(FindLiquidityTarget(r, total, bullish, entry, tgt)) tp = tgt;
   else tp = bullish ? entry + slDist * InpFallbackRR : entry - slDist * InpFallbackRR;
  }

//+------------------------------------------------------------------+
//| Inversion FVG: an OPPOSING-direction fair value gap that the BOS  |
//| move closed completely through, flipping its polarity. Searches   |
//| the leg around the sweep and returns the flipped zone plus the    |
//| bar at which the inversion happened (so "tested" only counts a    |
//| retest AFTER the flip, not the close-through itself).             |
//+------------------------------------------------------------------+
bool FindInversionFVG(const MqlRates &r[], int total, bool bullish, int bosIdx, int sweepIdx,
                      double &zoneHi, double &zoneLo, datetime &tLeft, datetime &tRight, int &invIdx)
  {
   double minSize = InpMinFVGSizePoints * g_symbol.Point();
   int hiLimit = MathMin(sweepIdx + InpMaxBarsForFVGSearch, total - 2);

   for(int i = bosIdx + 1; i <= hiLimit; i++)
     {
      if(i - 1 < 0 || i + 1 >= total)
         continue;

      if(bullish)
        {
         // bullish setup -> the inverted zone is a BEARISH (down) FVG that
         // price later closed back ABOVE, flipping it to support.
         double gTop = r[i + 1].low;    // older low  = top of the down-gap
         double gBot = r[i - 1].high;   // newer high = bottom of the down-gap
         if(gTop - gBot < minSize)
            continue;
         int flip = -1;
         for(int j = i - 1; j >= 0; j--) if(r[j].close > gTop) { flip = j; break; }
         if(flip < 0)
            continue;
         zoneLo = gBot; zoneHi = gTop;
         tLeft = r[i + 1].time; tRight = r[i - 1].time; invIdx = flip;
         return true;
        }
      else
        {
         // bearish setup -> the inverted zone is a BULLISH (up) FVG that
         // price later closed back BELOW, flipping it to resistance.
         double gBot = r[i + 1].high;   // older high = bottom of the up-gap
         double gTop = r[i - 1].low;    // newer low  = top of the up-gap
         if(gTop - gBot < minSize)
            continue;
         int flip = -1;
         for(int j = i - 1; j >= 0; j--) if(r[j].close < gBot) { flip = j; break; }
         if(flip < 0)
            continue;
         zoneLo = gBot; zoneHi = gTop;
         tLeft = r[i + 1].time; tRight = r[i - 1].time; invIdx = flip;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Strategy 1: Sweep -> BOS -> FVG                                   |
//| Entry in the fair value gap left inside the BOS impulse leg, in   |
//| the new bias direction. (BuildSetup_FVG)                         |
//+------------------------------------------------------------------+
bool BuildSetup_FVG(const MqlRates &r[], int total, bool bullish, const SeqSweepBOS &q, IctSetup &o)
  {
   double fvgHigh, fvgLow; datetime ftl, ftr;
   if(!FindEntryFVG(r, q.sweepIdx, q.bosIdx, bullish, fvgHigh, fvgLow, ftl, ftr))
      return false;

   FillSetupCommon(o, 0, bullish);
   o.sweepLevel = q.sweepLevel; o.sweepTime = q.sweepTime;
   o.bosLevel   = q.bosLevel;   o.bosTime   = q.bosTime;
   o.isZone = true; o.zoneHigh = fvgHigh; o.zoneLow = fvgLow; o.zoneTime = ftl;
   int fvgIdx = TimeToIndex(r, total, ftr);
   if(fvgIdx < 0) fvgIdx = 0;
   o.stage  = StageFromZone(r, fvgLow, fvgHigh);
   o.tested = ZoneTested(r, fvgIdx, fvgLow, fvgHigh);

   double entry, sl, tp;
   ComputeZoneTrade(r, total, bullish, fvgHigh, fvgLow, q.sweepExtreme, entry, sl, tp);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 2: Sweep -> BOS -> Inversion FVG                         |
//| An opposing FVG the BOS move closed through (flipped); entry on   |
//| the retest of that inverted zone. (BuildSetup_IFVG)              |
//+------------------------------------------------------------------+
bool BuildSetup_IFVG(const MqlRates &r[], int total, bool bullish, const SeqSweepBOS &q, IctSetup &o)
  {
   double zHi, zLo; datetime tl, tr; int invIdx;
   if(!FindInversionFVG(r, total, bullish, q.bosIdx, q.sweepIdx, zHi, zLo, tl, tr, invIdx))
      return false;

   FillSetupCommon(o, 1, bullish);
   o.sweepLevel = q.sweepLevel; o.sweepTime = q.sweepTime;
   o.bosLevel   = q.bosLevel;   o.bosTime   = q.bosTime;
   o.isZone = true; o.zoneHigh = zHi; o.zoneLow = zLo; o.zoneTime = tl;
   o.stage  = StageFromZone(r, zLo, zHi);
   o.tested = ZoneTested(r, invIdx, zLo, zHi);   // "tested" = a retest AFTER the inversion

   double entry, sl, tp;
   ComputeZoneTrade(r, total, bullish, zHi, zLo, q.sweepExtreme, entry, sl, tp);
   SetTrade(o, entry, sl, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Strategy 3: Sweep -> BOS -> Breaker Block                        |
//| The opposing order block the BOS move violated (closed through)   |
//| and flipped; entry on the retest of that breaker.(BuildSetup_Breaker)|
//+------------------------------------------------------------------+
bool BuildSetup_Breaker(const MqlRates &r[], int total, bool bullish, const SeqSweepBOS &q, IctSetup &o)
  {
   int sweepIdx = q.sweepIdx, bosIdx = q.bosIdx;
   double sweepExtreme = q.sweepExtreme, sweepLevel = q.sweepLevel, bosLevel = q.bosLevel;
   datetime sweepTime = q.sweepTime, bosTime = q.bosTime;

   int loI = bosIdx + 1, hiI = sweepIdx;          // the leg that built the swept extreme
   if(loI > hiI) return false;

   // The breaker is the OPPOSING order block inside that leg: for a bullish
   // setup it's the lowest down-candle; for a bearish setup the highest
   // up-candle. That candle pushed price into the liquidity that got swept.
   int ob = -1;
   if(bullish)
     {
      double best = DBL_MAX;
      for(int oo = loI; oo <= hiI; oo++)
         if(r[oo].close < r[oo].open && r[oo].low < best) { best = r[oo].low; ob = oo; }
     }
   else
     {
      double best = -DBL_MAX;
      for(int oo = loI; oo <= hiI; oo++)
         if(r[oo].close > r[oo].open && r[oo].high > best) { best = r[oo].high; ob = oo; }
     }
   if(ob < 0) return false;

   // It only becomes a BREAKER once the OB has been VIOLATED -- a later candle
   // must have CLOSED through it in the BOS direction. That flip is the setup.
   int flip = -1;
   for(int j = ob - 1; j >= 0; j--)
     {
      if(bullish  && r[j].close > r[ob].high) { flip = j; break; }
      if(!bullish && r[j].close < r[ob].low ) { flip = j; break; }
     }
   if(flip < 0) return false;

   double zoneLo = r[ob].low, zoneHi = r[ob].high;
   FillSetupCommon(o, 2, bullish);
   o.sweepLevel = sweepLevel; o.sweepTime = sweepTime;
   o.bosLevel   = bosLevel;   o.bosTime   = bosTime;
   o.isZone = true; o.zoneHigh = zoneHi; o.zoneLow = zoneLo; o.zoneTime = r[ob].time;
   o.stage  = StageFromZone(r, zoneLo, zoneHi);
   o.tested = ZoneTested(r, flip, zoneLo, zoneHi); // "tested" = a retest AFTER the violation

   double entry, sl, tp;
   ComputeZoneTrade(r, total, bullish, zoneHi, zoneLo, sweepExtreme, entry, sl, tp);
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
//| Context filters (ICT): every entry must sit inside the right     |
//| half of the dealing range and inside a trading session window.   |
//+------------------------------------------------------------------+
void ComputePremiumDiscount()
  {
   g_pdValid = false;
   if(!InpUsePremiumDiscount)
      return;
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   int got = CopyRates(_Symbol, InpLTF_Timeframe, 1, InpPDRangeBars, rr);
   if(got < 5)
      return;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < got; i++)
     {
      if(rr[i].high > hi) hi = rr[i].high;
      if(rr[i].low  < lo) lo = rr[i].low;
     }
   if(hi <= lo)
      return;
   g_pdHigh = hi; g_pdLow = lo;
   g_pdEquilibrium = (hi + lo) / 2.0;
   g_pdValid = true;
  }

// Buys must be at/below equilibrium (discount); sells at/above (premium).
bool PremiumDiscountOK(const IctSetup &s)
  {
   if(!InpUsePremiumDiscount || !g_pdValid)
      return true;
   return s.bullish ? (s.entry <= g_pdEquilibrium) : (s.entry >= g_pdEquilibrium);
  }

bool HourInWindow(int h, int start, int end)
  {
   if(start == end)            return false;        // empty window
   if(start < end)             return (h >= start && h < end);
   return (h >= start || h < end);                  // window wraps past midnight
  }

bool KillzoneOK()
  {
   if(!InpUseKillzones)
      return true;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);                  // server time
   return HourInWindow(t.hour, InpKZ1StartHour, InpKZ1EndHour)
       || HourInWindow(t.hour, InpKZ2StartHour, InpKZ2EndHour);
  }

//+------------------------------------------------------------------+
//| Auto-trade: take the single best actionable setup, one at a time.|
//| touchMode=false -> the closed candle must be inside the zone     |
//|   (stage "ready"); touchMode=true -> live price (incl. a wick)   |
//|   is currently inside the zone band.                             |
//| Gated by premium/discount + killzone context filters.            |
//| Selection: triggered + actionable, prefer untested, then top RR. |
//+------------------------------------------------------------------+
void TradeBestSetup(bool touchMode)
  {
   if(PositionExistsForEA())
      return;
   if((int)g_symbol.Spread() > InpMaxSpreadPoints)
      return;
   if(!KillzoneOK())
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
      if(!PremiumDiscountOK(s)) continue;
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
      ObjectSetInteger(0, zname, OBJPROP_FILL, true);                 // solid colour fill
      ObjectSetInteger(0, zname, OBJPROP_BACK, true);
      ObjectSetInteger(0, zname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, zname, OBJPROP_WIDTH, 2);
     }
   else
     {
      string lvlname = base + "Level";
      ObjectCreate(0, lvlname, OBJ_TREND, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneHigh);
      ObjectSetInteger(0, lvlname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, lvlname, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_DASH);
      ObjectSetInteger(0, lvlname, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, lvlname, OBJPROP_RAY_RIGHT, false);
     }

   string lname = base + "Lbl";
   ObjectCreate(0, lname, OBJ_TEXT, 0, s.zoneTime, s.zoneHigh);
   ObjectSetString(0, lname, OBJPROP_TEXT, " " + tag);
   ObjectSetInteger(0, lname, OBJPROP_COLOR, InpColorText);          // black on a white chart
   ObjectSetInteger(0, lname, OBJPROP_ANCHOR, s.bullish ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);

   // Full anatomy: Sweep + BOS levels, plus Entry/SL/TP for every actionable
   // setup (forming AND ready -- so you see the planned trade before price
   // arrives, not only once it's already in the zone).
   DrawSetupLines(base, s, tRight);
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
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, InpColorText);   // text in the user's label color (black on white charts)
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 7);
  }

//+------------------------------------------------------------------+
//| Draw the full anatomy of a setup -- the Sweep level, the BOS     |
//| level, and (when actionable) the Entry/SL/TP -- so the whole     |
//| Sweep -> BOS -> retest story is visible, not just the zone box.  |
//| Shared by both the live and historical drawing paths.            |
//+------------------------------------------------------------------+
void DrawSetupLines(string base, const IctSetup &s, datetime tRight)
  {
   if(s.sweepTime > 0)
      DrawHLine(base + "Sweep", s.sweepTime, tRight, s.sweepLevel, InpColorSweep, STYLE_DASH, "Sweep");
   if(s.bosTime > 0)
      DrawHLine(base + "BOS", s.bosTime, tRight, s.bosLevel, InpColorBOS, STYLE_DASH, "BOS");
   if(InpDrawTradeLines && s.hasTrade)
     {
      DrawHLine(base + "Entry", s.zoneTime, tRight, s.entry, InpColorEntry, STYLE_DASH,  "Entry");
      DrawHLine(base + "SL",    s.zoneTime, tRight, s.sl,    InpColorSL,    STYLE_SOLID, "SL");
      DrawHLine(base + "TP",    s.zoneTime, tRight, s.tp,    InpColorTP,    STYLE_SOLID, "TP");
     }
  }

//+------------------------------------------------------------------+
//| One-shot historical scan: runs once on init (and again whenever  |
//| an input changes, since that re-fires OnInit) -- never per-tick. |
//| Single ascending CopyRates fetch is reversed into one descending |
//| array ONCE, then each "as of bar j" view fed to the live         |
//| detectors is just a cheap slice of that array, not a fresh       |
//| CopyRates. Drawings are capped per strategy+direction             |
//| (InpMaxHistoricalPerSetup) to keep object count and scan time     |
//| bounded; each find draws the full anatomy (zone + Sweep/BOS +     |
//| Entry/SL/TP), so lower the cap if the chart gets busy.            |
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

   int windowLen = HoursToBars(InpLookbackHours);   // matches the live scan's lookback depth
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
            if(s.hasTrade && s.rr < InpMinRR)
               continue;                    // same 1:2 quality bar as the live scan

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
   color  col  = s.bullish ? InpColorHistBull : InpColorHistBear;
   datetime tRight = s.zoneTime + PeriodSeconds(InpLTF_Timeframe) * InpZoneExtendBars;
   string tag = "H " + s.shortCode + (s.tested ? " (tested)" : "");

   if(s.isZone)
     {
      string zname = base + "Zone";
      ObjectCreate(0, zname, OBJ_RECTANGLE, 0, s.zoneTime, s.zoneHigh, tRight, s.zoneLow);
      ObjectSetInteger(0, zname, OBJPROP_COLOR, col);
      ObjectSetInteger(0, zname, OBJPROP_FILL, true);    // filled, same as live zones
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
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, InpColorText);   // black on a white chart
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);

   // Full anatomy for historical setups too -- Sweep / BOS / Entry / SL / TP --
   // so a past setup shows the whole trade, not just the box.
   DrawSetupLines(base, s, tRight);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void EnsureDashboardObjects()
  {
   if(ObjectFind(0, DASH_PREFIX + "BG") >= 0)
      return;

   int x = 10, y = 20, w = 360, rowH = 16;
   // Title, Mode, TF, Bias, Ctx, 3 strategy rows, Acct, Pos, Spread, Hist
   string rows[] = {"Title","Mode","TF","Bias","Ctx","Diag",
                    "S0","S1","S2",
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
      else if(g_slotSkip[slot] != "")
         parts[d] = side + "skip-" + g_slotSkip[slot];   // detected but filtered out (PD / RR)
      else
         parts[d] = side + "-";
     }
   return StringFormat("%-6s %-12s %-12s", code, parts[0], parts[1]);
  }

// Row color so the state reads at a glance: green = an actionable READY setup,
// white = forming (valid, waiting for the retrace), gray = detected but
// filtered out (PD/RR), dim = nothing / disabled.
color StrategyRowColor(int stratNum)
  {
   if(!StrategyEnabled(stratNum))
      return clrDimGray;
   bool anyReady = false, anyForming = false, anySkip = false;
   for(int d = 0; d < 2; d++)
     {
      int slot = SlotIndex(stratNum, d == 0);
      if(g_slotActive[slot])
        {
         if(g_slots[slot].stage == "ready") anyReady = true; else anyForming = true;
        }
      else if(g_slotSkip[slot] != "")
         anySkip = true;
     }
   if(anyReady)   return clrLimeGreen;
   if(anyForming) return clrWhite;
   if(anySkip)    return clrGray;
   return clrDimGray;
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

   SetDashLine("Title", "=== MMBM ICT Suite (3 strategies) ===", clrYellow);
   SetDashLine("Mode",  "Mode: " + (InpAutoTrade ? ("AUTO-TRADE (" + (InpTriggerMode == TRIGGER_TOUCH ? "touch" : "close") + ")") : "SCAN ONLY"),
               InpAutoTrade ? clrLimeGreen : clrOrange);
   SetDashLine("TF",    "Chart: " + EnumToString((ENUM_TIMEFRAMES)_Period) + (tfMatch ? "  [OK]" : "  [MISMATCH-drawings hidden]"),
               tfMatch ? clrWhite : clrRed);
   SetDashLine("Bias",  "HTF bias: Buy " + (g_htfBullBias ? "OK" : "blk") + " | Sell " + (g_htfBearBias ? "OK" : "blk"), clrWhite);

   // Context filters: killzone (server time) + where price sits in the range.
   MqlDateTime tnow; TimeToStruct(TimeCurrent(), tnow);
   bool kzOn = KillzoneOK();
   string kzTxt = !InpUseKillzones ? "KZ off"
                  : ((kzOn ? "KZ IN" : "KZ OUT") + StringFormat(" %02d:%02d", tnow.hour, tnow.min));
   string pdTxt;
   if(!InpUsePremiumDiscount)        pdTxt = "P/D off";
   else if(!g_pdValid)               pdTxt = "P/D n/a";
   else
     {
      double px = g_symbol.Bid();
      pdTxt = (px > g_pdEquilibrium) ? "Premium" : "Discount";
     }
   color ctxCol = (InpUseKillzones && !kzOn) ? clrOrange : clrAqua;
   SetDashLine("Ctx", "Ctx: " + kzTxt + " | " + pdTxt, ctxCol);
   SetDashLine("Diag", "Gate B:" + g_diagBull + " S:" + g_diagBear, clrYellow);

   for(int n = 0; n < NUM_STRATEGIES; n++)
      SetDashLine("S" + IntegerToString(n), StrategyRowText(n), StrategyRowColor(n));

   SetDashLine("Acct",  "Equity " + DoubleToString(equity, 2) + " | Bal " + DoubleToString(balance, 2), clrWhite);
   SetDashLine("Pos",   "Open: " + IntegerToString(posCount) + " (" + DoubleToString(posLots, 2) + " lots)  P/L " + DoubleToString(posPnL, 2),
               posPnL >= 0 ? clrLimeGreen : clrRed);
   SetDashLine("Spread","Spread: " + IntegerToString((int)g_symbol.Spread()) + " pts (max " + IntegerToString(InpMaxSpreadPoints) + ")", clrWhite);
   SetDashLine("Hist",  InpHistoryDays > 0 ? ("History: last " + IntegerToString(InpHistoryDays) + "d drawn") : "History: off", clrSilver);
  }
//+------------------------------------------------------------------+
