//+------------------------------------------------------------------+
//|                                              IFVG_Basic_EA.mq5    |
//|     Inversion-FVG scanner with optional pending-limit auto-trade.|
//|                                                                  |
//|  Implements the 6-step Inversion FVG method:                     |
//|   1. HTF bias        - trade only with the higher-timeframe trend |
//|   2. Original FVG    - a 3-candle imbalance (1st & 3rd don't      |
//|                        overlap) on the execution timeframe        |
//|   3. Decisive break  - a candle CLOSES its body fully on the      |
//|                        opposite side of the FVG (wick poke != it).|
//|                        The FVG is now INVERTED.                    |
//|   4. Entry           - proximal edge of the zone (top for buys,   |
//|                        bottom for sells)                          |
//|   5. Stop loss        - just beyond the inverted gap's extreme     |
//|   6. Target           - next draw on liquidity (swing H/L), >=1:2  |
//|                                                                  |
//|  Confluences (each a toggle): liquidity sweep, market-structure   |
//|  shift, HTF bias. SMT divergence is intentionally left out of v1. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "Inversion FVG scanner + optional pending-limit auto-trade"

#include <Trade\Trade.mqh>
CTrade g_trade;

//=== Inputs ==========================================================
input group "=== Timeframe ==="
input ENUM_TIMEFRAMES InpHTF             = PERIOD_H1;   // Higher timeframe for bias (step 1)

input group "=== Detection ==="
input double InpLookbackHours            = 120.0;       // How far back to scan (hours)
input int    InpSwingBars                = 5;           // Bars each side to confirm a swing pivot (sweeps / MSS / TP)
input int    InpATRPeriod                = 14;          // ATR period (sizes the min gap & SL buffer)
input double InpMinGapATR                = 0.20;        // Minimum FVG size, as a multiple of ATR
input int    InpMaxSetups                = 25;          // Max IFVG zones to draw (most recent first)

input group "=== Confluences (filters) ==="
input bool   InpUseHTFBias               = true;        // Require setup to align with HTF trend
input bool   InpUseLiquiditySweep        = true;        // Require a liquidity sweep right before the inversion
input bool   InpUseMSS                   = true;        // Require the break candle to shift structure
input int    InpSweepLookback            = 24;          // Bars before the gap to look for the swept pool

input group "=== Trade levels ==="
input double InpMinRR                    = 2.0;         // Min reward:risk used for the fallback target
input double InpSLBufferATR              = 0.10;        // SL buffer beyond the gap extreme (x ATR)

input group "=== Visuals ==="
input bool   InpShowStructure            = true;        // Draw swing-pivot market structure (HH/HL/LH/LL)
input bool   InpShowDashboard            = true;        // Show the on-chart info panel
input int    InpZoneExtendBars           = 14;          // Bars to extend zone / level lines to the right
input color  InpBullColor                = clrDodgerBlue;
input color  InpBearColor                = clrCrimson;
input color  InpEntryColor               = clrGoldenrod;
input color  InpSLColor                  = clrRed;
input color  InpTPColor                  = clrGreen;
input color  InpSweepColor               = clrMagenta;
input color  InpStructHighColor          = clrTomato;
input color  InpStructLowColor           = clrDodgerBlue;
input color  InpTextColor                = clrBlack;    // Label text (black on light charts, white on dark)

input group "=== Liquidity lines ==="
input bool   InpShowLiquidity            = true;        // Draw untapped liquidity pools
input bool   InpShowExternal             = true;        // External liquidity = MAJOR swing pools (BSL/SSL)
input bool   InpShowInternal             = true;        // Internal liquidity = MINOR swing pools inside the range
input bool   InpShowEqualHL              = true;        // Equal highs / lows (clustered stops)
input int    InpExtSwingBars             = 10;          // Swing strength for EXTERNAL (major) pools
input int    InpIntSwingBars             = 3;           // Swing strength for INTERNAL (minor) pools
input double InpEqualTolATR              = 0.10;        // Equal-HL tolerance as a multiple of ATR
input int    InpMaxLiqLines              = 8;           // Max lines per type/side (anti-clutter)
input color  InpExtLiqColor              = clrOrangeRed;
input color  InpIntLiqColor              = clrSlateGray;
input color  InpEqualLiqColor            = clrMediumOrchid;

input group "=== Backtest (on-chart win/loss) ==="
input bool   InpShowBacktest             = true;        // Tally TP-vs-SL outcomes across the window
input int    InpBacktestDays             = 30;          // How many days back to evaluate (e.g. 30 = a month)

input group "=== Auto-trade (LIVE -- off by default) ==="
input bool   InpAutoTrade                = false;       // Place pending-limit orders on detected setups
input double InpLotSize                  = 0.01;        // Fixed lot size
input int    InpMagic                    = 880011;      // Magic number (this EA's orders)
input int    InpMaxPositions             = 3;           // Max concurrent orders+positions (this magic)
input double InpPendingExpiryHrs         = 12.0;        // Cancel an unfilled limit after N hours (0 = GTC)
input bool   InpTradeBuys                = true;        // Allow buy setups
input bool   InpTradeSells               = true;        // Allow sell setups

//=== Globals =========================================================
#define PFX  "IFVGB_"
#define DPFX "IFVGB_DASH_"

int      g_atr        = INVALID_HANDLE;
datetime g_lastBar    = 0;
bool     g_htfUp      = true;
bool     g_htfDown    = true;
int      g_lastBull   = 0;     // counts for the dashboard
int      g_lastBear   = 0;

// backtest tally (filled by RunBacktest, shown on the dashboard)
int      g_btWins     = 0;
int      g_btLosses   = 0;
int      g_btOpen     = 0;
int      g_btNoFill   = 0;
double   g_btTotalR   = 0.0;
double   g_btGrossWin = 0.0;   // sum of +R on winners (for profit factor)

MqlRates g_htf[];              // cached higher-timeframe bars (for as-of-time bias)
bool     g_tradingHalted = false;  // on-chart STOP button: blocks NEW trades

//--- one detected inversion-FVG setup --------------------------------
struct IFVGSetup
  {
   bool     valid;
   bool     bullish;       // true = inverted to support (long), false = inverted to resistance (short)
   double   gapLow;        // the FVG / IFVG zone
   double   gapHigh;
   datetime gapTime;       // left anchor (the older of the 3 gap candles)
   datetime breakTime;     // candle that CLOSED through (the inversion)
   int      breakIdx;      // its bar index (for the outcome walk-forward)
   double   breakLevel;    // the gap edge that was closed through
   bool     hadSweep;
   datetime sweepTime;
   double   sweepLevel;
   double   sweepExtreme;
   bool     hadMSS;
   datetime mssTime;
   double   mssLevel;
   string   stage;         // "ready" (price in zone) / "forming"
   bool     tested;        // price already retested the zone after the break
   double   entry;
   double   sl;
   double   tp;
   double   rr;
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   g_atr = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBar = 0;
   Scan();                 // draw immediately on attach, don't wait for a tick
   EventSetTimer(1);       // keep the dashboard live even when no ticks arrive
   ChartRedraw(0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
   ObjectsDeleteAll(0, PFX);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Refresh the dashboard's LIVE fields (auto-trade status, account,  |
//| spread) once a second, so toggling the Algo button or the market  |
//| opening/closing shows up even with no incoming ticks.             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpShowDashboard)
     {
      Dashboard();
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == DPFX + "BtnStop")
     {
      g_tradingHalted = !g_tradingHalted;
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);   // keep it a flat toggle
      if(g_tradingHalted)
         CancelMyPendings();                               // stop -> pull unfilled limits
      Dashboard();
      ChartRedraw(0);
      return;
     }
   if(id == CHARTEVENT_CHART_CHANGE)
      ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBar)
      return;             // setups are detected on closed bars only
   g_lastBar = t;
   Scan();
   ChartRedraw(0);
  }

//=== ATR / swings / helpers =========================================
double GetATR()
  {
   double b[];
   if(CopyBuffer(g_atr, 0, 0, 1, b) > 0 && b[0] > 0.0)
      return b[0];
   return 0.0;
  }

bool IsSwingHigh(const MqlRates &r[], int i, int k)
  {
   int total = ArraySize(r);
   for(int j = 1; j <= k; j++)
     {
      if(i - j < 0 || i + j >= total) return false;
      if(r[i - j].high >= r[i].high || r[i + j].high >= r[i].high) return false;
     }
   return true;
  }

bool IsSwingLow(const MqlRates &r[], int i, int k)
  {
   int total = ArraySize(r);
   for(int j = 1; j <= k; j++)
     {
      if(i - j < 0 || i + j >= total) return false;
      if(r[i - j].low <= r[i].low || r[i + j].low <= r[i].low) return false;
     }
   return true;
  }

int HoursToBars(double hours)
  {
   int secs = PeriodSeconds(_Period);
   if(secs <= 0) return 1;
   return (int)MathMax(1.0, MathRound(hours * 3600.0 / secs));
  }

//+------------------------------------------------------------------+
//| Load enough HTF bars to judge bias anywhere in the scan/backtest  |
//| window (cached in g_htf, refreshed once per scan).                 |
//+------------------------------------------------------------------+
void EnsureHTFData()
  {
   ArraySetAsSeries(g_htf, true);
   double days = MathMax((double)InpBacktestDays, InpLookbackHours / 24.0) + 2.0;
   int bars = (int)MathRound(days * 24.0 * 3600.0 / PeriodSeconds(InpHTF)) + 6 * InpSwingBars + 20;
   bars = (int)MathMax(60.0, MathMin(5000.0, (double)bars));
   CopyRates(_Symbol, InpHTF, 0, bars, g_htf);
  }

//+------------------------------------------------------------------+
//| Step 1: HTF bias AS OF time t -- using only the HTF swings that   |
//| had formed by then, so a historical setup is judged by its own    |
//| day's trend, not today's. Neutral (both true) until 2 swings each. |
//+------------------------------------------------------------------+
void HTFBiasAt(datetime t, bool &up, bool &down)
  {
   up = true; down = true;
   int n = ArraySize(g_htf);
   if(n < 4 * InpSwingBars + 4)
      return;

   int start = -1;                                  // first HTF bar at/older than t
   for(int i = 0; i < n; i++)
      if(g_htf[i].time <= t) { start = i; break; }
   if(start < 0)
      return;

   double hi[2], lo[2]; int hc = 0, lc = 0;
   for(int i = start + InpSwingBars; i < n - InpSwingBars; i++)   // confirmed-by-t swings, newest first
     {
      if(hc >= 2 && lc >= 2) break;
      if(hc < 2 && IsSwingHigh(g_htf, i, InpSwingBars)) hi[hc++] = g_htf[i].high;
      if(lc < 2 && IsSwingLow (g_htf, i, InpSwingBars)) lo[lc++] = g_htf[i].low;
     }
   if(hc < 2 || lc < 2)
      return;

   bool hh = hi[0] > hi[1], hl = lo[0] > lo[1];
   bool lh = hi[0] < hi[1], ll = lo[0] < lo[1];
   if(hh && hl)      { up = true;  down = false; }
   else if(lh && ll) { up = false; down = true;  }
   // mixed -> neutral (both stay true)
  }

void ComputeHTFBias()                               // current bias, for the dashboard display
  {
   HTFBiasAt(TimeCurrent(), g_htfUp, g_htfDown);
  }

//+------------------------------------------------------------------+
//| Confluence: a liquidity sweep right before the inversion. For a   |
//| short (bearish) we need a prior swing HIGH that price wicked above |
//| then closed back below, between that high and the break candle.   |
//+------------------------------------------------------------------+
bool CheckSweep(const MqlRates &r[], int total, bool bearish, int m, int brk,
                datetime &swTime, double &swLevel, double &swExtreme)
  {
   int k    = InpSwingBars;
   int last = MathMin(total - k - 1, m + InpSweepLookback);
   for(int i = m; i <= last; i++)                  // pools just before the gap, nearest first
     {
      if(bearish && IsSwingHigh(r, i, k))
        {
         double level = r[i].high;
         for(int j = i - 1; j >= brk; j--)         // newer candles up to the break
            if(r[j].high > level && r[j].close < level)
              { swTime = r[i].time; swLevel = level; swExtreme = r[j].high; return true; }
        }
      if(!bearish && IsSwingLow(r, i, k))
        {
         double level = r[i].low;
         for(int j = i - 1; j >= brk; j--)
            if(r[j].low < level && r[j].close > level)
              { swTime = r[i].time; swLevel = level; swExtreme = r[j].low; return true; }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Confluence: market-structure shift -- the break candle closes     |
//| beyond the most recent swing pivot in the trade direction.        |
//+------------------------------------------------------------------+
bool CheckMSS(const MqlRates &r[], int total, bool bearish, int brk, int m,
              datetime &mssTime, double &mssLevel)
  {
   int k    = InpSwingBars;
   int last = MathMin(total - k - 1, m + InpSweepLookback);
   for(int i = brk + 1; i <= last; i++)            // first structural pivot older than the break
     {
      if(bearish && IsSwingLow(r, i, k))
        {
         if(r[brk].close < r[i].low) { mssTime = r[i].time; mssLevel = r[i].low; return true; }
         return false;                              // nearest swing low not broken -> no MSS
        }
      if(!bearish && IsSwingHigh(r, i, k))
        {
         if(r[brk].close > r[i].high) { mssTime = r[i].time; mssLevel = r[i].high; return true; }
         return false;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Step 6: next draw on liquidity beyond entry (nearest swing).      |
//+------------------------------------------------------------------+
bool FindLiquidityTarget(const MqlRates &r[], int total, bool forLong, double entry, double &tp)
  {
   int k = InpSwingBars;
   for(int i = k; i < total - k; i++)
     {
      if(forLong  && IsSwingHigh(r, i, k) && r[i].high > entry) { tp = r[i].high; return true; }
      if(!forLong && IsSwingLow(r, i, k)  && r[i].low  < entry) { tp = r[i].low;  return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Core: scan the window for inverted FVGs (most recent first).      |
//+------------------------------------------------------------------+
int FindIFVGs(const MqlRates &r[], int total, IFVGSetup &out[], int maxSetups)
  {
   ArrayResize(out, 0);
   double atr = GetATR();
   if(atr <= 0.0)
      return 0;
   double minGap = InpMinGapATR  * atr;
   double buf    = InpSLBufferATR * atr;

   for(int m = 1; m < total - 1; m++)
     {
      if(ArraySize(out) >= maxSetups) break;

      for(int dir = 0; dir < 2; dir++)
        {
         bool bearish = (dir == 0);            // short from a bullish FVG inverted down

         // Step 2: the original 3-candle FVG (1st & 3rd don't overlap).
         double gapLow, gapHigh;
         if(bearish)
           {
            if(!(r[m - 1].low > r[m + 1].high)) continue;   // bullish (up) gap
            gapLow = r[m + 1].high; gapHigh = r[m - 1].low;
           }
         else
           {
            if(!(r[m - 1].high < r[m + 1].low)) continue;   // bearish (down) gap
            gapLow = r[m - 1].high; gapHigh = r[m + 1].low;
           }
         if(gapHigh - gapLow < minGap) continue;

         // Step 3: decisive break -- first candle whose CLOSE is fully beyond
         // the far edge of the gap (a wick poke does not qualify).
         int brk = -1;
         for(int j = m - 2; j >= 0; j--)
           {
            if(bearish  && r[j].close < gapLow)  { brk = j; break; }
            if(!bearish && r[j].close > gapHigh) { brk = j; break; }
           }
         if(brk < 0) continue;

         // Invalidation: price later closed back through the far side.
         bool failed = false;
         for(int j = brk - 1; j >= 0; j--)
           {
            if(bearish  && r[j].close > gapHigh) { failed = true; break; }
            if(!bearish && r[j].close < gapLow)  { failed = true; break; }
           }
         if(failed) continue;

         // Step 1: HTF bias filter -- judged AS OF this setup's break, so an
         // older setup is filtered by its own day's trend, not today's.
         if(InpUseHTFBias)
           {
            bool bUp, bDown; HTFBiasAt(r[brk].time, bUp, bDown);
            if(bearish  && !bDown) continue;
            if(!bearish && !bUp)   continue;
           }

         // Confluences.
         datetime mssTime = 0; double mssLevel = 0;
         bool hadMSS = CheckMSS(r, total, bearish, brk, m, mssTime, mssLevel);
         if(InpUseMSS && !hadMSS) continue;

         datetime swTime = 0; double swLevel = 0, swExtreme = 0;
         bool hadSweep = CheckSweep(r, total, bearish, m, brk, swTime, swLevel, swExtreme);
         if(InpUseLiquiditySweep && !hadSweep) continue;

         // De-duplicate overlapping same-direction zones.
         bool dup = false;
         for(int q = 0; q < ArraySize(out); q++)
            if(out[q].bullish == (!bearish) && out[q].gapLow < gapHigh && out[q].gapHigh > gapLow)
              { dup = true; break; }
         if(dup) continue;

         // Build the setup.
         IFVGSetup s; ZeroMemory(s);
         s.valid = true; s.bullish = !bearish;
         s.gapLow = gapLow; s.gapHigh = gapHigh; s.gapTime = r[m + 1].time;
         s.breakTime = r[brk].time; s.breakIdx = brk; s.breakLevel = bearish ? gapLow : gapHigh;
         s.hadSweep = hadSweep; s.sweepTime = swTime; s.sweepLevel = swLevel; s.sweepExtreme = swExtreme;
         s.hadMSS = hadMSS; s.mssTime = mssTime; s.mssLevel = mssLevel;

         s.tested = false;
         for(int j = brk - 1; j >= 0; j--)
            if(r[j].low <= gapHigh && r[j].high >= gapLow) { s.tested = true; break; }

         double price = r[0].close;
         s.stage = (price >= gapLow && price <= gapHigh) ? "ready" : "forming";

         // Entry at the PROXIMAL edge -- the side price reaches FIRST on the
         // retest: the BOTTOM of the zone for a sell (price rallies up into
         // resistance), the TOP for a buy (price drops into support).
         // SL beyond the far extreme; TP at the next liquidity.
         s.entry = bearish ? gapLow : gapHigh;
         s.sl    = bearish ? gapHigh + buf : gapLow - buf;
         double tp;
         if(FindLiquidityTarget(r, total, !bearish, s.entry, tp))
            s.tp = tp;
         else
            s.tp = bearish ? s.entry - (s.sl - s.entry) * InpMinRR
                           : s.entry + (s.entry - s.sl) * InpMinRR;
         double risk = MathAbs(s.entry - s.sl);
         s.rr = (risk > 0) ? MathAbs(s.tp - s.entry) / risk : 0.0;

         int sz = ArraySize(out); ArrayResize(out, sz + 1); out[sz] = s;
        }
     }
   return ArraySize(out);
  }

//=== Drawing =========================================================
void HLine(string name, datetime t1, datetime t2, double price, color c, int style, int width)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void TextAt(string name, datetime t, double price, string txt, color c, int anchor)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price)) return;
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void ArrowAt(string name, datetime t, double price, int code, color c, int anchor)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, price)) return;
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void DrawSetup(const IFVGSetup &s, int idx)
  {
   string base = PFX + "S" + IntegerToString(idx) + "_";
   color  c    = s.bullish ? InpBullColor : InpBearColor;
   datetime tR = s.breakTime + (datetime)(PeriodSeconds(_Period) * InpZoneExtendBars);
   if(tR <= s.breakTime) tR = s.breakTime + PeriodSeconds(_Period);

   // The inverted gap zone.
   string z = base + "Zone";
   if(ObjectFind(0, z) >= 0) ObjectDelete(0, z);
   if(ObjectCreate(0, z, OBJ_RECTANGLE, 0, s.gapTime, s.gapHigh, tR, s.gapLow))
     {
      ObjectSetInteger(0, z, OBJPROP_COLOR, c);
      ObjectSetInteger(0, z, OBJPROP_FILL, true);
      ObjectSetInteger(0, z, OBJPROP_BACK, true);
      ObjectSetInteger(0, z, OBJPROP_STYLE, s.tested ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, z, OBJPROP_SELECTABLE, false);
     }

   string tag = (s.bullish ? "IFVG BUY  " : "IFVG SELL ") + "R:R " + DoubleToString(s.rr, 1) +
                (s.stage == "ready" ? "  [READY]" : "") + (s.tested ? "  (tested)" : "");
   TextAt(base + "Lbl", s.gapTime, s.bullish ? s.gapLow : s.gapHigh, tag, c,
          s.bullish ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

   // Trade levels.
   HLine(base + "Entry", s.breakTime, tR, s.entry, InpEntryColor, STYLE_DASH,  1);
   HLine(base + "SL",    s.breakTime, tR, s.sl,    InpSLColor,    STYLE_SOLID, 1);
   HLine(base + "TP",    s.breakTime, tR, s.tp,    InpTPColor,    STYLE_SOLID, 1);
   TextAt(base + "EntryT", tR, s.entry, " Entry " + DoubleToString(s.entry, _Digits), InpEntryColor, ANCHOR_LEFT);
   TextAt(base + "SLT",    tR, s.sl,    " SL "    + DoubleToString(s.sl,    _Digits), InpSLColor,    ANCHOR_LEFT);
   TextAt(base + "TPT",    tR, s.tp,    " TP "    + DoubleToString(s.tp,    _Digits), InpTPColor,    ANCHOR_LEFT);

   // The decisive break (the inversion).
   ArrowAt(base + "Brk", s.breakTime, s.breakLevel, s.bullish ? 233 : 234, c,
           s.bullish ? ANCHOR_TOP : ANCHOR_BOTTOM);
   if(s.hadMSS)
      TextAt(base + "MSS", s.mssTime, s.mssLevel, "MSS ", clrGray, s.bullish ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

   // The liquidity sweep that fed it.
   if(s.hadSweep)
     {
      ArrowAt(base + "Swp", s.sweepTime, s.sweepExtreme, 159, InpSweepColor,
              s.bullish ? ANCHOR_TOP : ANCHOR_BOTTOM);
      TextAt(base + "SwpT", s.sweepTime, s.sweepExtreme, s.bullish ? "Swept low " : "Swept high ",
             InpSweepColor, s.bullish ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
     }
  }

//+------------------------------------------------------------------+
//| Market structure: label swing pivots HH/HL/LH/LL across window.   |
//+------------------------------------------------------------------+
void DrawStructure(const MqlRates &r[], int total)
  {
   if(!InpShowStructure) return;
   int k = InpSwingBars;
   if(total < 2 * k + 5) return;

   double lastH = 0, lastL = 0; bool haveH = false, haveL = false;
   for(int i = total - k - 1; i >= k; i--)            // oldest -> newest
     {
      if(IsSwingHigh(r, i, k))
        {
         string lbl = !haveH ? "H" : (r[i].high > lastH ? "HH" : "LH");
         TextAt(PFX + "MS_H_" + IntegerToString((int)r[i].time), r[i].time, r[i].high, lbl, InpStructHighColor, ANCHOR_LOWER);
         lastH = r[i].high; haveH = true;
        }
      if(IsSwingLow(r, i, k))
        {
         string lbl = !haveL ? "L" : (r[i].low < lastL ? "LL" : "HL");
         TextAt(PFX + "MS_L_" + IntegerToString((int)r[i].time), r[i].time, r[i].low, lbl, InpStructLowColor, ANCHOR_UPPER);
         lastL = r[i].low; haveL = true;
        }
     }
  }

//+------------------------------------------------------------------+
//| Liquidity: a pool is "untapped" until a later candle trades       |
//| through it. We only draw untapped pools -- those are the live      |
//| draws on liquidity; tapped ones are spent.                        |
//+------------------------------------------------------------------+
bool UntappedHigh(const MqlRates &r[], int i, double level)
  {
   for(int j = i - 1; j >= 0; j--)
      if(r[j].high > level) return false;
   return true;
  }
bool UntappedLow(const MqlRates &r[], int i, double level)
  {
   for(int j = i - 1; j >= 0; j--)
      if(r[j].low < level) return false;
   return true;
  }

void LiqLine(string name, datetime t1, datetime t2, double price, color c, int style, int width)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);   // extend to the right = a live target
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Draw untapped swing pools at strength k. excludeK>0 skips pivots  |
//| that are ALSO pivots at the larger strength (so internal lines    |
//| don't double-draw on top of the external ones).                   |
//+------------------------------------------------------------------+
void DrawPools(const MqlRates &r[], int total, int k, int excludeK, color c,
               string tagHi, string tagLo, int width, int style)
  {
   datetime tNow = r[0].time;
   int drawnH = 0, drawnL = 0;
   for(int i = k; i < total - k; i++)                  // newest -> oldest
     {
      if(drawnH < InpMaxLiqLines && IsSwingHigh(r, i, k) &&
         (excludeK <= 0 || !IsSwingHigh(r, i, excludeK)))
        {
         double lvl = r[i].high;
         if(UntappedHigh(r, i, lvl))
           {
            string nm = PFX + "LQ_H" + IntegerToString(width) + "_" + IntegerToString((int)r[i].time);
            LiqLine(nm, r[i].time, tNow, lvl, c, style, width);
            if(tagHi != "") TextAt(nm + "t", r[i].time, lvl, tagHi + " ", c, ANCHOR_RIGHT_LOWER);
            drawnH++;
           }
        }
      if(drawnL < InpMaxLiqLines && IsSwingLow(r, i, k) &&
         (excludeK <= 0 || !IsSwingLow(r, i, excludeK)))
        {
         double lvl = r[i].low;
         if(UntappedLow(r, i, lvl))
           {
            string nm = PFX + "LQ_L" + IntegerToString(width) + "_" + IntegerToString((int)r[i].time);
            LiqLine(nm, r[i].time, tNow, lvl, c, style, width);
            if(tagLo != "") TextAt(nm + "t", r[i].time, lvl, tagLo + " ", c, ANCHOR_RIGHT_UPPER);
            drawnL++;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Equal highs / lows: two adjacent same-type swings within an ATR   |
//| tolerance = a clean stop cluster. Drawn only while still untapped. |
//+------------------------------------------------------------------+
void DrawEqualHL(const MqlRates &r[], int total, double atr)
  {
   double tol = InpEqualTolATR * atr;
   if(tol <= 0.0) return;
   int k = InpIntSwingBars;
   datetime tNow = r[0].time;

   int drawn = 0;
   for(int i = k; i < total - k && drawn < InpMaxLiqLines; i++)   // equal HIGHS
     {
      if(!IsSwingHigh(r, i, k)) continue;
      for(int j = i + k; j < total - k; j++)
        {
         if(!IsSwingHigh(r, j, k)) continue;                       // nearest older swing high
         if(MathAbs(r[j].high - r[i].high) <= tol)
           {
            double y = MathMax(r[i].high, r[j].high);
            if(UntappedHigh(r, i, y))
              {
               string nm = PFX + "LQ_EQH_" + IntegerToString((int)r[i].time);
               LiqLine(nm, r[j].time, tNow, y, InpEqualLiqColor, STYLE_SOLID, 1);
               TextAt(nm + "t", r[i].time, y, "EQH ", InpEqualLiqColor, ANCHOR_LEFT_LOWER);
               drawn++;
              }
           }
         break;
        }
     }

   drawn = 0;
   for(int i = k; i < total - k && drawn < InpMaxLiqLines; i++)   // equal LOWS
     {
      if(!IsSwingLow(r, i, k)) continue;
      for(int j = i + k; j < total - k; j++)
        {
         if(!IsSwingLow(r, j, k)) continue;
         if(MathAbs(r[j].low - r[i].low) <= tol)
           {
            double y = MathMin(r[i].low, r[j].low);
            if(UntappedLow(r, i, y))
              {
               string nm = PFX + "LQ_EQL_" + IntegerToString((int)r[i].time);
               LiqLine(nm, r[j].time, tNow, y, InpEqualLiqColor, STYLE_SOLID, 1);
               TextAt(nm + "t", r[i].time, y, "EQL ", InpEqualLiqColor, ANCHOR_LEFT_UPPER);
               drawn++;
              }
           }
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Liquidity overlay: external (major) + internal (minor) + equal.   |
//+------------------------------------------------------------------+
void DrawLiquidity(const MqlRates &r[], int total)
  {
   if(!InpShowLiquidity) return;
   if(InpShowExternal)
      DrawPools(r, total, InpExtSwingBars, 0, InpExtLiqColor, "BSL", "SSL", 2, STYLE_SOLID);
   if(InpShowInternal)
      DrawPools(r, total, InpIntSwingBars, InpExtSwingBars, InpIntLiqColor, "", "", 1, STYLE_DOT);
   if(InpShowEqualHL)
      DrawEqualHL(r, total, GetATR());
  }

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void MkLbl(string suffix, int x, int y, color c, int fs)
  {
   string nm = DPFX + suffix;
   if(ObjectFind(0, nm) >= 0) return;
   ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, fs);
   ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }
void MkRect(string suffix, int x, int y, int w, int h, color bg, color border)
  {
   string nm = DPFX + suffix;
   if(ObjectFind(0, nm) >= 0) return;
   ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, border);
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }
void SetVal(string suffix, string txt, color c)
  {
   string nm = DPFX + suffix + "_v";
   ObjectSetString (0, nm, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
  }
void MyAccountStats(int &pos, int &pend, double &fpl)
  {
   pos = 0; pend = 0; fpl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { pos++; fpl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP); }
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && (long)OrderGetInteger(ORDER_MAGIC) == InpMagic) pend++;
     }
  }
string ShortTF(ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf), 7); }

void Dashboard()
  {
   if(!InpShowDashboard) { ObjectsDeleteAll(0, DPFX); return; }

   int x = 8, yTop = 16, panelW = 312, headerH = 22, rowH = 16;
   int keyX = x + 8, valX = x + 124, contentY = yTop + headerH + 5;

   string sfx[]   = {"Sym","Bias","Mkt","Filt","Set","SecBT","WL","WR","Net","OpenT","SecAcc","Eq","Pos","PL","Auto"};
   string left[]  = {"Symbol","HTF bias","Spread/ATR","Filters","Setups","--- BACKTEST ---",
                     "Win / Loss","Win rate","Net / PF","Open / no-fill","--- ACCOUNT ---",
                     "Equity / Bal","Pos / Pend","Float P/L","Auto-trade"};
   bool   isSec[] = {false,false,false,false,false,true,false,false,false,false,true,false,false,false,false};
   int    nrows   = ArraySize(sfx);

   int btnH = 22, btnY = contentY + nrows * rowH + 4;
   if(ObjectFind(0, DPFX + "BG") < 0)
     {
      MkRect("BG", x, yTop, panelW, (btnY - yTop) + btnH + 8, C'24,26,32', C'70,80,95');
      MkRect("HB", x, yTop, panelW, headerH,                  C'33,82,120', C'33,82,120');
      MkLbl ("Hdr", keyX, yTop + 4, clrWhite, 10);
      ObjectSetString(0, DPFX + "Hdr", OBJPROP_TEXT, "INVERSION FVG");

      // click-to-stop button along the bottom of the panel
      string bn = DPFX + "BtnStop";
      ObjectCreate(0, bn, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, bn, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bn, OBJPROP_XDISTANCE, keyX);
      ObjectSetInteger(0, bn, OBJPROP_YDISTANCE, btnY);
      ObjectSetInteger(0, bn, OBJPROP_XSIZE, panelW - 16);
      ObjectSetInteger(0, bn, OBJPROP_YSIZE, btnH);
      ObjectSetString (0, bn, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, bn, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, bn, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, bn, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, bn, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bn, OBJPROP_ZORDER, 10);

      for(int i = 0; i < nrows; i++)
        {
         int ry = contentY + i * rowH;
         if(isSec[i])
           {
            MkLbl(sfx[i], keyX, ry, C'120,140,165', 8);
            ObjectSetString(0, DPFX + sfx[i], OBJPROP_TEXT, left[i]);
           }
         else
           {
            MkLbl(sfx[i] + "_k", keyX, ry, C'150,162,178', 9);
            ObjectSetString(0, DPFX + sfx[i] + "_k", OBJPROP_TEXT, left[i]);
            MkLbl(sfx[i] + "_v", valX, ry, clrWhite, 9);
           }
        }
     }

   // ---- live values ----
   string biasTxt = !InpUseHTFBias ? "off" : (g_htfUp && !g_htfDown ? "BULL" : (g_htfDown && !g_htfUp ? "BEAR" : "neutral"));
   color  biasCol = (biasTxt == "BULL") ? clrLime : (biasTxt == "BEAR") ? clrTomato : clrSilver;
   double atr = GetATR();
   long   spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   SetVal("Sym",  _Symbol + "  " + ShortTF((ENUM_TIMEFRAMES)_Period), clrWhite);
   SetVal("Bias", biasTxt + " (" + ShortTF(InpHTF) + ")", biasCol);
   SetVal("Mkt",  IntegerToString((int)spr) + " pts   ATR " + DoubleToString(atr, _Digits), clrSilver);
   string fl = (InpUseLiquiditySweep ? "Sweep " : "") + (InpUseMSS ? "MSS " : "") + (InpUseHTFBias ? "HTF" : "");
   if(fl == "") fl = "none";
   SetVal("Filt", fl, clrAqua);
   SetVal("Set",  IntegerToString(g_lastBull) + " buy / " + IntegerToString(g_lastBear) + " sell", clrWhite);

   if(InpShowBacktest)
     {
      int    tot = g_btWins + g_btLosses;
      double wr  = (tot > 0) ? 100.0 * g_btWins / tot : 0.0;
      double pf  = (g_btLosses > 0) ? g_btGrossWin / (double)g_btLosses : (g_btGrossWin > 0 ? 999.0 : 0.0);
      SetVal("WL",    IntegerToString(g_btWins) + "W / " + IntegerToString(g_btLosses) + "L", clrWhite);
      SetVal("WR",    DoubleToString(wr, 0) + "%   (" + IntegerToString(tot) + " trades)", wr >= 50 ? clrLime : clrGold);
      SetVal("Net",   StringFormat("%+.1fR   PF %s", g_btTotalR, (pf >= 999 ? "inf" : DoubleToString(pf, 2))), g_btTotalR >= 0 ? clrLime : clrTomato);
      SetVal("OpenT", IntegerToString(g_btOpen) + " open / " + IntegerToString(g_btNoFill) + " no-fill", clrSilver);
     }
   else
     {
      SetVal("WL", "off", clrSilver); SetVal("WR", "-", clrSilver);
      SetVal("Net", "-", clrSilver);  SetVal("OpenT", "-", clrSilver);
     }

   int pos, pend; double fpl; MyAccountStats(pos, pend, fpl);
   SetVal("Eq",  DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " / " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), clrWhite);
   SetVal("Pos", IntegerToString(pos) + " pos / " + IntegerToString(pend) + " pend", clrWhite);
   SetVal("PL",  DoubleToString(fpl, 2), fpl >= 0 ? clrLime : clrTomato);

   string autoTxt; color autoCol;
   if(!InpAutoTrade)        { autoTxt = "OFF (scan only)";       autoCol = clrSilver; }
   else if(g_tradingHalted) { autoTxt = "STOPPED (Stop button)"; autoCol = clrOrange; }
   else
     {
      string br = TradeBlockReason();
      if(br == "") { autoTxt = "ON  lot " + DoubleToString(InpLotSize, 2); autoCol = clrLime; }
      else         { autoTxt = "BLOCKED: " + br;                          autoCol = clrTomato; }
     }
   SetVal("Auto", autoTxt, autoCol);

   // STOP / RESUME button reflects the halt state.
   string bn = DPFX + "BtnStop";
   if(g_tradingHalted)
     {
      ObjectSetString (0, bn, OBJPROP_TEXT, "RESUME trading");
      ObjectSetInteger(0, bn, OBJPROP_BGCOLOR, clrForestGreen);
     }
   else
     {
      ObjectSetString (0, bn, OBJPROP_TEXT, "STOP new trades");
      ObjectSetInteger(0, bn, OBJPROP_BGCOLOR, clrFireBrick);
     }
  }

//+------------------------------------------------------------------+
//| On-chart backtest: for EVERY setup in the window, find where its  |
//| entry was first touched, then walk forward to see whether SL or   |
//| TP was hit first. Tally W/L/open + total R. No orders, no tester. |
//| Simplifications: SL-first on an ambiguous bar (both inside one     |
//| candle), spread/slippage ignored, overlapping setups counted      |
//| independently. It's an edge read, not a broker-accurate report.   |
//+------------------------------------------------------------------+
void RunBacktest()
  {
   g_btWins = 0; g_btLosses = 0; g_btOpen = 0; g_btNoFill = 0; g_btTotalR = 0.0; g_btGrossWin = 0.0;
   if(!InpShowBacktest)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int want  = (int)MathMax(1.0, MathRound(InpBacktestDays * 24.0 * 3600.0 / PeriodSeconds(_Period)));
   int total = CopyRates(_Symbol, _Period, 1, want, r);
   if(total < 2 * InpSwingBars + 10)
      return;

   IFVGSetup sx[];
   int n = FindIFVGs(r, total, sx, 100000);     // ALL setups, not just the drawn few
   for(int i = 0; i < n; i++)
     {
      bool buy = sx[i].bullish;
      int  brk = sx[i].breakIdx;

      // Entry fill: first bar after the break that reaches the entry edge.
      int tj = -1;
      for(int j = brk - 1; j >= 0; j--)
        {
         if(buy  && r[j].low  <= sx[i].entry) { tj = j; break; }
         if(!buy && r[j].high >= sx[i].entry) { tj = j; break; }
        }
      if(tj < 0) { g_btNoFill++; continue; }     // never filled -> not a trade

      // Outcome: from the fill bar forward, SL or TP first?
      int oc = 0;                                // 0 open, +1 win, -1 loss
      for(int k = tj; k >= 0; k--)
        {
         bool hitSL = buy ? (r[k].low  <= sx[i].sl) : (r[k].high >= sx[i].sl);
         bool hitTP = buy ? (r[k].high >= sx[i].tp) : (r[k].low  <= sx[i].tp);
         if(hitSL) { oc = -1; break; }            // SL checked first = conservative tie-break
         if(hitTP) { oc =  1; break; }
        }

      if(oc == 1)      { g_btWins++;   g_btTotalR += sx[i].rr; g_btGrossWin += sx[i].rr; }
      else if(oc == -1){ g_btLosses++; g_btTotalR -= 1.0; }
      else               g_btOpen++;
     }
  }

//+------------------------------------------------------------------+
//| Auto-trade: place a pending LIMIT at each setup's entry edge so    |
//| the trade triggers the instant price WICKS to the level. Buy setup |
//| -> BUY LIMIT at the zone top; sell setup -> SELL LIMIT at the zone |
//| bottom. SL/TP come straight from the setup. Off unless InpAutoTrade|
//| and the terminal/account/symbol all allow trading (so it only acts |
//| when the market is actually open and Algo Trading is enabled).     |
//+------------------------------------------------------------------+
// "" = clear to trade; otherwise the exact reason MT5 is blocking us.
string TradeBlockReason()
  {
   if(g_tradingHalted)                                          return "stopped (Stop button)";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))                  return "no connection";
   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))        return "Algo button OFF (toolbar)";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))                        return "EA 'Allow Algo Trading' off";
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))          return "account trading off";
   ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED)                          return "symbol disabled";
   if(tm == SYMBOL_TRADE_MODE_CLOSEONLY)                         return "symbol close-only (mkt closed?)";
   return "";
  }

bool TradingAllowed()
  {
   return InpAutoTrade && TradeBlockReason() == "";
  }

// Cancel this EA's UNFILLED pending limits (open positions are left alone).
void CancelMyPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && (long)OrderGetInteger(ORDER_MAGIC) == InpMagic)
         g_trade.OrderDelete(tk);
     }
  }

int CountMyOrders()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == InpMagic) c++;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && (long)OrderGetInteger(ORDER_MAGIC) == InpMagic) c++;
     }
   return c;
  }

bool HasOrderNear(double price)
  {
   double atr = GetATR();
   double tol = (atr > 0) ? 0.15 * atr : 10 * _Point;     // don't stack orders on the same zone
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= tol) return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tol) return true;
     }
   return false;
  }

void ManageTrades(const IFVGSetup &setups[], int n)
  {
   if(!TradingAllowed()) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < n; i++)
     {
      if(CountMyOrders() >= InpMaxPositions) break;
      if(setups[i].tested) continue;                       // zone already retested -> chance gone
      if(setups[i].bullish  && !InpTradeBuys)  continue;
      if(!setups[i].bullish && !InpTradeSells) continue;

      double entry = NormalizeDouble(setups[i].entry, _Digits);
      double sl    = NormalizeDouble(setups[i].sl,    _Digits);
      double tp    = NormalizeDouble(setups[i].tp,    _Digits);

      // A limit only makes sense on the correct side of current price.
      if(setups[i].bullish) { if(entry >= ask) continue; }  // BUY LIMIT must sit below the ask
      else                  { if(entry <= bid) continue; }  // SELL LIMIT must sit above the bid
      if(HasOrderNear(entry)) continue;                     // already have one on this zone

      ENUM_ORDER_TYPE_TIME tt = (InpPendingExpiryHrs > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      datetime exp = (InpPendingExpiryHrs > 0) ? TimeCurrent() + (datetime)(InpPendingExpiryHrs * 3600.0) : 0;

      if(setups[i].bullish)
         g_trade.BuyLimit(InpLotSize, entry, _Symbol, sl, tp, tt, exp, "IFVG buy");
      else
         g_trade.SellLimit(InpLotSize, entry, _Symbol, sl, tp, tt, exp, "IFVG sell");
     }
  }

//+------------------------------------------------------------------+
//| One full scan + redraw.                                           |
//+------------------------------------------------------------------+
void Scan()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);                  // index 0 = newest
   // Scan as far back as the backtest window so PAST IFVG zones are drawn too,
   // not just the last few days -- the drawn zones then match what's evaluated.
   int want = MathMax(HoursToBars(InpLookbackHours),
                      (int)MathRound(InpBacktestDays * 24.0 * 3600.0 / PeriodSeconds(_Period)));
   int total = CopyRates(_Symbol, _Period, 1, want, r);   // from 1 = closed bars only
   if(total < 2 * InpSwingBars + 10)
      return;

   EnsureHTFData();      // refresh HTF cache before any bias lookups
   ComputeHTFBias();

   // wipe last pass (setups + structure + liquidity), keep the dashboard
   ObjectsDeleteAll(0, PFX + "S");
   ObjectsDeleteAll(0, PFX + "MS_");
   ObjectsDeleteAll(0, PFX + "LQ_");

   DrawLiquidity(r, total);
   DrawStructure(r, total);

   IFVGSetup setups[];
   int n = FindIFVGs(r, total, setups, InpMaxSetups);
   g_lastBull = 0; g_lastBear = 0;
   for(int i = 0; i < n; i++)
     {
      DrawSetup(setups[i], i);
      if(setups[i].bullish) g_lastBull++; else g_lastBear++;
     }

   ManageTrades(setups, n);
   RunBacktest();
   Dashboard();
  }
//+------------------------------------------------------------------+
