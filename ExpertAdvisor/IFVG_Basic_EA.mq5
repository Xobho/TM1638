//+------------------------------------------------------------------+
//|                                              IFVG_Basic_EA.mq5    |
//|     Basic Inversion-FVG scanner (visual only -- no orders).      |
//|                                                                  |
//|  Implements the 6-step Inversion FVG method:                     |
//|   1. HTF bias        - trade only with the higher-timeframe trend |
//|   2. Original FVG    - a 3-candle imbalance (1st & 3rd don't      |
//|                        overlap) on the execution timeframe        |
//|   3. Decisive break  - a candle CLOSES its body fully on the      |
//|                        opposite side of the FVG (wick poke != it).|
//|                        The FVG is now INVERTED.                    |
//|   4. Entry           - consequent encroachment = 50% of the gap   |
//|   5. Stop loss        - just beyond the inverted gap's extreme     |
//|   6. Target           - next draw on liquidity (swing H/L), >=1:2  |
//|                                                                  |
//|  Confluences (each a toggle): liquidity sweep, market-structure   |
//|  shift, HTF bias. SMT divergence is intentionally left out of v1. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Basic Inversion FVG scanner (visual only)"

//=== Inputs ==========================================================
input group "=== Timeframe ==="
input ENUM_TIMEFRAMES InpHTF             = PERIOD_H1;   // Higher timeframe for bias (step 1)

input group "=== Detection ==="
input double InpLookbackHours            = 120.0;       // How far back to scan (hours)
input int    InpSwingBars                = 5;           // Bars each side to confirm a swing pivot (sweeps / MSS / TP)
input int    InpATRPeriod                = 14;          // ATR period (sizes the min gap & SL buffer)
input double InpMinGapATR                = 0.20;        // Minimum FVG size, as a multiple of ATR
input int    InpMaxSetups                = 6;           // Max IFVG setups to draw (most recent first)

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

//=== Globals =========================================================
#define PFX  "IFVGB_"
#define DPFX "IFVGB_DASH_"

int      g_atr        = INVALID_HANDLE;
datetime g_lastBar    = 0;
bool     g_htfUp      = true;
bool     g_htfDown    = true;
int      g_lastBull   = 0;     // counts for the dashboard
int      g_lastBear   = 0;

//--- one detected inversion-FVG setup --------------------------------
struct IFVGSetup
  {
   bool     valid;
   bool     bullish;       // true = inverted to support (long), false = inverted to resistance (short)
   double   gapLow;        // the FVG / IFVG zone
   double   gapHigh;
   datetime gapTime;       // left anchor (the older of the 3 gap candles)
   datetime breakTime;     // candle that CLOSED through (the inversion)
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

   g_lastBar = 0;
   Scan();                 // draw immediately on attach, don't wait for a tick
   ChartRedraw(0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
   ObjectsDeleteAll(0, PFX);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
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
//| Step 1: HTF bias from the higher timeframe's last two swings.     |
//+------------------------------------------------------------------+
void ComputeHTFBias()
  {
   g_htfUp = true; g_htfDown = true;
   if(!InpUseHTFBias)
      return;

   MqlRates h[];
   ArraySetAsSeries(h, true);
   int n = CopyRates(_Symbol, InpHTF, 1, 6 * InpSwingBars + 50, h);
   if(n < 4 * InpSwingBars + 4)
      return;

   double hi[]; double lo[];
   ArrayResize(hi, 0); ArrayResize(lo, 0);
   for(int i = InpSwingBars; i < n - InpSwingBars; i++)
     {
      if(IsSwingHigh(h, i, InpSwingBars) && ArraySize(hi) < 2)
        { int s = ArraySize(hi); ArrayResize(hi, s + 1); hi[s] = h[i].high; }
      if(IsSwingLow(h, i, InpSwingBars) && ArraySize(lo) < 2)
        { int s = ArraySize(lo); ArrayResize(lo, s + 1); lo[s] = h[i].low; }
      if(ArraySize(hi) >= 2 && ArraySize(lo) >= 2) break;
     }
   if(ArraySize(hi) < 2 || ArraySize(lo) < 2)
      return;

   bool hh = hi[0] > hi[1], hl = lo[0] > lo[1];
   bool lh = hi[0] < hi[1], ll = lo[0] < lo[1];
   if(hh && hl)      { g_htfUp = true;  g_htfDown = false; }
   else if(lh && ll) { g_htfUp = false; g_htfDown = true;  }
   // mixed -> both stay true (neutral)
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
int FindIFVGs(const MqlRates &r[], int total, IFVGSetup &out[])
  {
   ArrayResize(out, 0);
   double atr = GetATR();
   if(atr <= 0.0)
      return 0;
   double minGap = InpMinGapATR  * atr;
   double buf    = InpSLBufferATR * atr;

   for(int m = 1; m < total - 1; m++)
     {
      if(ArraySize(out) >= InpMaxSetups) break;

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

         // Step 1: HTF bias filter.
         if(InpUseHTFBias)
           {
            if(bearish  && !g_htfDown) continue;
            if(!bearish && !g_htfUp)   continue;
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
         s.breakTime = r[brk].time; s.breakLevel = bearish ? gapLow : gapHigh;
         s.hadSweep = hadSweep; s.sweepTime = swTime; s.sweepLevel = swLevel; s.sweepExtreme = swExtreme;
         s.hadMSS = hadMSS; s.mssTime = mssTime; s.mssLevel = mssLevel;

         s.tested = false;
         for(int j = brk - 1; j >= 0; j--)
            if(r[j].low <= gapHigh && r[j].high >= gapLow) { s.tested = true; break; }

         double price = r[0].close;
         s.stage = (price >= gapLow && price <= gapHigh) ? "ready" : "forming";

         // Steps 4/5/6: entry at 50%, SL beyond the extreme, TP at next liquidity.
         s.entry = (gapHigh + gapLow) / 2.0;
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
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void Dashboard()
  {
   if(!InpShowDashboard) { ObjectsDeleteAll(0, DPFX); return; }

   string rows[] = {"Title", "Bias", "Conf", "Setups", "Note"};
   int x = 12, y = 18, rowH = 16;
   if(ObjectFind(0, DPFX + "BG") < 0)
     {
      ObjectCreate(0, DPFX + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_XDISTANCE, x - 6);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_YDISTANCE, y - 6);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_XSIZE, 300);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_YSIZE, ArraySize(rows) * rowH + 12);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_BGCOLOR, C'20,20,20');
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, DPFX + "BG", OBJPROP_HIDDEN, true);
      for(int i = 0; i < ArraySize(rows); i++)
        {
         string nm = DPFX + rows[i];
         ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y + i * rowH);
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
         ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
        }
     }

   string bias = !InpUseHTFBias ? "off"
                 : (g_htfUp && !g_htfDown ? "BULL" : (g_htfDown && !g_htfUp ? "BEAR" : "neutral"));
   string conf = "Sweep " + (InpUseLiquiditySweep ? "ON" : "off") +
                 " | MSS " + (InpUseMSS ? "ON" : "off") +
                 " | HTF " + (InpUseHTFBias ? "ON" : "off");

   ObjectSetString(0, DPFX + "Title",  OBJPROP_TEXT, "=== Inversion FVG (visual) ===");
   ObjectSetInteger(0, DPFX + "Title", OBJPROP_COLOR, clrGold);
   ObjectSetString(0, DPFX + "Bias",   OBJPROP_TEXT, "HTF " + EnumToString(InpHTF) + " bias: " + bias);
   ObjectSetString(0, DPFX + "Conf",   OBJPROP_TEXT, conf);
   ObjectSetString(0, DPFX + "Setups", OBJPROP_TEXT, "Drawn: " + IntegerToString(g_lastBull) + " bull, " + IntegerToString(g_lastBear) + " bear");
   ObjectSetString(0, DPFX + "Note",   OBJPROP_TEXT, "Chart " + EnumToString((ENUM_TIMEFRAMES)_Period) + "  (scan only, no orders)");
  }

//+------------------------------------------------------------------+
//| One full scan + redraw.                                           |
//+------------------------------------------------------------------+
void Scan()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);                  // index 0 = newest
   int want = HoursToBars(InpLookbackHours);
   int total = CopyRates(_Symbol, _Period, 1, want, r);   // from 1 = closed bars only
   if(total < 2 * InpSwingBars + 10)
      return;

   ComputeHTFBias();

   // wipe last pass (setups + structure), keep the dashboard
   ObjectsDeleteAll(0, PFX + "S");
   ObjectsDeleteAll(0, PFX + "MS_");

   DrawStructure(r, total);

   IFVGSetup setups[];
   int n = FindIFVGs(r, total, setups);
   g_lastBull = 0; g_lastBear = 0;
   for(int i = 0; i < n; i++)
     {
      DrawSetup(setups[i], i);
      if(setups[i].bullish) g_lastBull++; else g_lastBear++;
     }

   Dashboard();
  }
//+------------------------------------------------------------------+
