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
#property version   "1.73"
#property description "Inversion FVG scalper; run-and-reclaim sweeps (multi-candle takes)"

#include <Trade\Trade.mqh>
CTrade g_trade;

//=== Inputs ==========================================================
input group "=== Scalp mode ==="
input bool   InpScalpMode                 = true;        // ON: pure M15 in-and-out -- ignores HTF bias, fixed tight target, fast break-even, no TP chasing. Overrides the settings below at startup.
input double InpScalpRR                    = 1.5;         // Scalp target reward:risk (used when Scalp mode is ON)
input double InpScalpBETriggerR           = 1.0;         // Scalp break-even trigger, in R (1.0 = move SL to entry once trade is +1:1; used when Scalp mode is ON)

input group "=== Timeframe ==="
input ENUM_TIMEFRAMES InpHTF             = PERIOD_H1;   // Higher timeframe for bias (step 1)
input int    InpHTFTrendBars             = 6;           // Swing strength for the HTF bias trend (bigger = steadier bias; independent of the M15 structure)

input group "=== Detection ==="
input double InpLookbackHours            = 120.0;       // How far back to scan (hours)
input int    InpSwingBars                = 5;           // Bars each side to confirm a swing pivot (sweeps / MSS / TP)
input int    InpATRPeriod                = 14;          // ATR period (sizes the min gap & SL buffer)
input double InpMinGapATR                = 0.20;        // Minimum FVG size, as a multiple of ATR
input int    InpMaxGapAgeBars            = 30;          // FRESHNESS: the gap must be closed-through (inverted) within this many bars of forming -- a leftover gap from an old leg is not today's setup (0 = off)
input int    InpMaxSetups                = 25;          // Max IFVG zones to draw (most recent first)

input group "=== Confluences (filters) ==="
input bool   InpUseHTFBias               = true;        // Require setup to align with HTF trend
input bool   InpUseLiquiditySweep        = true;        // KEY confluence: require a liquidity sweep right before the inversion (the sweep IS the reversal signal)
input bool   InpUseMSS                   = false;       // Require the break candle to ALSO shift structure (redundant when a sweep is required; off by default)
// NOTE: the sweep = a MAJOR level taken out. Tune it with InpMajorMoveATR /
// InpMajorPivotBars (Visuals group) -- the drawn Major lines ARE the pools.
input double InpSweepMaxDistATR          = 3.0;         // Swept Major level must sit within this x ATR of the zone (a pool far away is not THIS setup's liquidity; 0 = no cap)
input int    InpSweepMaxBarsBack         = 24;          // The grab must happen within this many bars BEFORE the inversion candle (the sweep must be what CAUSED this reversal; 0 = no cap)
input int    InpSweepReclaimBars         = 3;           // The take may span up to this many candles: price may CLOSE through the level but must close back within N candles (run-and-reclaim = swept; stays broken = CHoCH). 1 = same-candle only

input group "=== Trade levels ==="
input double InpMinRR                    = 2.0;         // Min reward:risk used for the fallback target
input double InpMinRRFilter              = 1.0;         // QUALITY GATE: skip setups whose target is closer than this R:R (0 = take everything)
input double InpSLBufferATR              = 0.10;        // SL buffer beyond the gap extreme (x ATR)
input double InpMinSLATR                 = 0.50;        // SL FLOOR: widen SL to at least this x ATR from entry (thin-zone SLs get wicked out by noise; risk-% sizing keeps the $ risk unchanged)
input double InpMaxSLATR                 = 2.50;        // SL CAP: skip setups whose SL would be wider than this x ATR (0 = off)
input bool   InpSpreadAdjust             = true;        // Shift SELL SL/TP up by the live spread so they align to the chart (sells exit on Ask); avoids being stopped a spread early
input bool   InpBuyEntrySpreadAdj        = true;        // Lift BUY entry by the live spread so the buy fills when the Bid chart touches the zone top (buys fill at Ask); avoids missing thin retests

input group "=== Visuals ==="
input bool   InpShowDrawings              = true;        // Master: draw zones/structure/liquidity on the chart (turn OFF for fast backtests)
input bool   InpShowRejected             = false;       // Show REJECTED IFVG candidates as faded 'ghost' zones (diagnostic; off = cleaner chart)
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
input int    InpStructSwingBars          = 4;           // Swing strength for the M15 structure + MSS confluence (smaller = more swings, matches a finer hand-marked structure)
input bool   InpShowSwingLabels          = false;       // Show the small HH/HL/LH/LL pivot text labels (off = cleaner chart; BOS/CHoCH + major levels still drawn)
input int    InpMaxStructBreaks          = 6;           // Draw only the most recent N BOS/CHoCH breaks (keeps low timeframes clean; 0 = all)
input color  InpBOSColor                 = clrGray;     // Break of Structure (continuation)
input color  InpCHoCHColor               = clrOrange;   // Change of Character (reversal)
input bool   InpShowMajorStruct          = true;        // Mark MAJOR structure: big swing highs/lows as horizontal level lines
input double InpMajorMoveATR             = 2.5;         // MAJOR level = a swing after price reversed >= this x ATR (significance; auto-scales per TF; bigger = fewer, only the biggest). 0 = use bar-count strength
input int    InpMajorPivotBars           = 4;           // A major pivot must also be a real fractal swing (this many lower/higher bars each side); bigger = only clean swings
input int    InpMajorSwingBars           = 15;          // Fallback swing strength for MAJOR structure when InpMajorMoveATR = 0
input double InpMajorDays                 = 10.0;        // Draw major levels going back at least this many days
input int    InpMaxMajorLines            = 4;           // (legacy) max major lines per side -- ignored; the days window governs
input color  InpMajorStructColor         = clrBlue;     // Major-structure level color
input bool   InpMTFStructure             = false;       // ALSO draw structure from 2 higher timeframes (labels tagged by TF)
input ENUM_TIMEFRAMES InpStructTF2       = PERIOD_H1;   // Extra structure timeframe #1
input ENUM_TIMEFRAMES InpStructTF3       = PERIOD_H4;   // Extra structure timeframe #2
input color  InpStructTF2Color           = clrGoldenrod;
input color  InpStructTF3Color           = clrMediumPurple;
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

enum ENUM_IFVG_ENTRY
  {
   ENTRY_LIMIT_RETEST,    // Pending limit at the entry edge (waits for the wick/retest)
   ENTRY_MARKET_NOW       // Market order immediately when the setup forms (enter now)
  };

input group "=== Auto-trade (LIVE -- off by default) ==="
input bool   InpAutoTrade                = false;       // Master switch: let the EA place trades on detected setups
input ENUM_IFVG_ENTRY InpEntryMode       = ENTRY_LIMIT_RETEST; // How to enter at the retest: resting limit, or market order on touch
input double InpLotSize                  = 0.01;        // Fixed lot size
input int    InpMagic                    = 880011;      // Magic number (this EA's orders)
input int    InpMaxPositions             = 3;           // Max concurrent orders+positions (this magic)
input double InpMaxEntryDistATR          = 4.0;         // Don't rest a limit (and cancel ones) farther than this x ATR from price (0 = no cap) -- keeps far setups from hogging slots
input double InpMaxSpreadATR             = 0.10;        // ADAPTIVE spread cap: skip entries when spread > this fraction of ATR (auto-scales Gold/US30/USTEC; 0 = off)
input int    InpMaxSpreadPoints          = 0;           // Optional FIXED spread cap in points (0 = off; use only to hard-limit a specific symbol)
input double InpPendingExpiryHrs         = 12.0;        // Cancel an unfilled LIMIT after N hours (0 = GTC; limit mode only)
input bool   InpTradeBuys                = true;        // Allow buy setups
input bool   InpTradeSells               = true;        // Allow sell setups
input bool   InpAdaptTP                   = true;        // Re-target TP to the next liquidity as new swings form (pending + open positions; SL stays fixed)
input bool   InpCancelCounterBias         = true;        // Cancel pending orders that oppose the current HTF bias (keeps the book trend-aligned, frees slots)

input group "=== Session filter (server time) ==="
input bool   InpUseSessionFilter         = true;        // Only OPEN new trades inside the session window (open-trade management runs 24/5)
input int    InpSessionStartHour         = 9;           // Session start hour, BROKER/server time (EET broker: 9 ~ pre-London)
input int    InpSessionEndHour           = 23;          // Session end hour, server time (23 ~ through the NY session; start>end = overnight window)
input bool   InpSessionCancelPend        = true;        // Pull unfilled pending limits when the session closes (don't fill overnight)

input group "=== Risk & management ==="
input double InpRiskPercent              = 0.5;         // Risk % of balance per trade (lot auto-sized from SL distance; 0 = use fixed lot)
input bool   InpBreakEven                = true;        // Move SL to break-even once the trade is in profit
input double InpBETriggerR               = 1.0;         // Break-even trigger, in R (profit / initial risk)
input int    InpBEBufferPoints           = 5;           // Break-even offset beyond entry, in points (covers spread)
input int    InpMaxTradesPerDay          = 8;           // Stop opening new trades after this many today (scalping takes more; 0 = no cap)
input double InpDailyLossLimitPct        = 3.0;         // Stop opening new trades after today's realized loss reaches this % of balance (0 = off)
input double InpDailyLossLimitUSD        = 5.0;         // Stop new trades after today's realized loss reaches this in account currency (overrides the % when > 0; 0 = off)

//=== Globals =========================================================
#define PFX  "IFVGB_"
#define DPFX "IFVGB_DASH_"

// Effective settings (= inputs, but Scalp mode overrides some at startup).
// Inputs are read-only consts in MQL5, so the EA reads these instead.
bool     g_useHTFBias       = true;
bool     g_useMSS           = false;
bool     g_useSweep         = true;
double   g_minRR            = 2.0;
bool     g_adaptTP          = true;
double   g_beTriggerR       = 1.0;
bool     g_cancelCounterBias= true;

int      g_atr        = INVALID_HANDLE;
datetime g_lastBar    = 0;
bool     g_htfUp      = true;
bool     g_htfDown    = true;
int      g_lastBull   = 0;     // counts for the dashboard
int      g_lastBear   = 0;

// monitored setup, for the dashboard "Live" line + the on-chart WATCHING level
bool     g_liveValid   = false;
bool     g_liveBull    = false;
double   g_liveEntry   = 0.0;
bool     g_liveTested  = false;
bool     g_liveWaiting = false;   // monitored one is still waiting to trigger
datetime g_liveTime    = 0;       // its break-bar anchor (for the watch line)
double   g_liveSL      = 0.0;     // monitored setup's SL/TP (for market-on-retest entry)
double   g_liveTP      = 0.0;
double   g_liveEst     = 0.0;     // monitored setup's estimated win % / break-even need %
double   g_liveNeed    = 0.0;

// backtest tally (filled by RunBacktest, shown on the dashboard)
int      g_btWins     = 0;
int      g_btLosses   = 0;
int      g_btOpen     = 0;
int      g_btNoFill   = 0;
double   g_btTotalR   = 0.0;
double   g_btGrossWin = 0.0;   // sum of +R on winners (for profit factor)
datetime g_btLastRun  = 0;     // throttle: the backtest pass is heavy, rerun sparingly

MqlRates g_htf[];              // cached higher-timeframe bars (for as-of-time bias)
bool     g_tradingHalted = false;  // on-chart STOP button: blocks NEW trades
datetime g_lastMktBreakTime = 0;   // dedup for market-entry mode (enter each setup once)
double   g_dayPL     = 0.0;        // today's realized P/L (cached, for the daily loss limit)
int      g_dayTrades = 0;          // trades opened today (cached, for the daily trade cap)

// why the freshest IFVG candidate (gap + confirmed inversion) was/ wasn't taken
string   g_rejBuy  = "";
string   g_rejSell = "";

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
   datetime sweepTime;        // the swept pool's swing bar
   double   sweepLevel;       // the pool price that got taken
   double   sweepExtreme;     // the wick that took it
   datetime sweepBreakTime;   // the candle that did the sweeping
   bool     hadMSS;
   datetime mssTime;
   double   mssLevel;
   string   stage;         // "ready" (price in zone) / "forming"
   bool     tested;        // price already retested the zone after the break
   double   entry;
   double   sl;
   double   tp;
   double   rr;
   bool     tpIsLiquidity; // TP sits at a real untapped pool (a genuine draw) vs an RR fallback
   string   rejReason;     // "" if it passed; otherwise why it was filtered (for ghost zones)
   // reliability features (feed the evidence-based odds + factor stats)
   double   sweepDistATR;  // swept Major level's distance from the zone, in ATR (closer = cleaner)
   double   gapATR;        // gap size in ATR (bigger displacement = stronger imbalance)
   double   brkDispATR;    // inversion candle body in ATR (decisive vs marginal close-through)
   bool     withTrend;     // aligned with the HTF structure trend at the break (measured, not filtered)
  };

IFVGSetup g_ghosts[];      // rejected IFVG candidates (drawn faded, labelled with the reason)

// Major structure pivots for the current scan (the drawn Major HH/HL/LH/LL).
// The sweep looks for one of THESE being taken out -- the lines you see ARE
// the liquidity. Filled once per scan, indexed into the scan's rates array.
int    g_majIdx[];
double g_majPx[];
bool   g_majHi[];

// Factor statistics: per reliability feature, historical wins/samples with the
// feature true [1] vs false [0], filled by the backtest pass. This is what
// tells us WHICH IFVGs are more reliable on this symbol+TF, from evidence.
#define NFEAT 5
int    g_ftWin[NFEAT][2];
int    g_ftTot[NFEAT][2];
string g_ftName[NFEAT] = {"swp","gap","brk","tp","trd"};

//+------------------------------------------------------------------+
int OnInit()
  {
   g_atr = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr == INVALID_HANDLE)
      return INIT_FAILED;

   // Resolve effective settings: Scalp mode overrides a few inputs for a
   // pure M15 in-and-out style (no HTF bias, tight fixed target, fast BE).
   g_useHTFBias        = InpUseHTFBias;
   g_useMSS            = InpUseMSS;
   g_useSweep          = InpUseLiquiditySweep;
   g_minRR             = InpMinRR;
   g_adaptTP           = InpAdaptTP;
   g_beTriggerR        = InpBETriggerR;
   g_cancelCounterBias = InpCancelCounterBias;
   if(InpScalpMode)
     {
      g_useHTFBias        = false;          // trade both ways off M15 structure alone
      g_useMSS            = false;          // sweep is the reversal signal -- MSS is redundant
      g_useSweep          = true;           // the sweep is THE confluence -- always required here
      g_minRR             = InpScalpRR;     // tight, fixed target
      g_adaptTP           = false;          // take the quick target, don't chase swings
      g_beTriggerR        = MathMax(InpScalpBETriggerR, 1.0); // BE no earlier than +1R (a stale saved input can't lower it; raising above 1 is allowed)
      g_cancelCounterBias = false;          // no HTF bias to align the book to
     }

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
   RefreshDailyStats();       // keep the daily P/L & trade-count cache current
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
   // Market-on-retest is checked EVERY tick so it fires the instant price
   // touches the entry edge (not only on bar close).
   TryMarketEntry();
   ApplyBreakEven();          // manage open trades every tick (move SL to BE at +R)

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

// ATR from a series-indexed rates array (so it works for ANY timeframe we
// have already copied, without a per-TF indicator handle).
double AtrFromRates(const MqlRates &r[], int total, int period)
  {
   if(total < 3) return 0.0;
   int n = MathMin(period, total - 1);
   if(n < 1) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++)
     {
      double tr = MathMax(r[i].high - r[i].low,
                  MathMax(MathAbs(r[i].high - r[i + 1].close),
                          MathAbs(r[i].low  - r[i + 1].close)));
      sum += tr;
     }
   return sum / n;
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
//| HTF trend AS OF time t, from the SAME BOS/CHoCH engine as the      |
//| drawn structure: the trend flips on a structure break and stays    |
//| there until the opposite break -- so a downtrend reads BEAR right  |
//| through pullbacks, instead of going neutral on every higher high.  |
//| Returns 1 (up) / -1 (down) / 0 (undecided).                        |
//+------------------------------------------------------------------+
int HTFTrendAt(datetime t)
  {
   int n = ArraySize(g_htf);
   int k = InpHTFTrendBars;        // independent of the M15 structure strength
   if(n < 2 * k + 5) return 0;

   int start = -1;                                  // first HTF bar at/older than t
   for(int i = 0; i < n; i++)
      if(g_htf[i].time <= t) { start = i; break; }
   if(start < 0) return 0;

   double refHigh = 0, refLow = 0; bool haveH = false, haveL = false;
   int trend = 0;
   for(int i = n - k - 1; i >= start; i--)          // oldest -> up to t
     {
      double c = g_htf[i].close;
      if(haveH && c > refHigh)      { trend = 1;  haveH = false; }   // break up
      else if(haveL && c < refLow)  { trend = -1; haveL = false; }   // break down
      int j = i + k;                                 // swing confirmed once k newer bars exist
      if(j <= n - 1 - k)
        {
         if(IsSwingHigh(g_htf, j, k)) { refHigh = g_htf[j].high; haveH = true; }
         if(IsSwingLow (g_htf, j, k)) { refLow  = g_htf[j].low;  haveL = true; }
        }
     }
   return trend;
  }

// Step 1: HTF bias AS OF t -- now driven by the structure trend, so it tracks
// the actual BOS/CHoCH structure (no neutral flicker on pullbacks).
void HTFBiasAt(datetime t, bool &up, bool &down)
  {
   int tr = HTFTrendAt(t);
   if(tr == 1)       { up = true;  down = false; }
   else if(tr == -1) { up = false; down = true;  }
   else              { up = true;  down = true;  }   // undecided -> neutral
  }

void ComputeHTFBias()                               // current bias, for the dashboard display
  {
   HTFBiasAt(TimeCurrent(), g_htfUp, g_htfDown);
  }

//+------------------------------------------------------------------+
//| Confluence: a liquidity sweep before the inversion -- defined as a  |
//| MAJOR structure level (a drawn Major HH/HL/LH/LL, from g_maj*)     |
//| being TAKEN OUT: price trades through the level the FIRST time and  |
//| CLOSES back the other side (grab + rejection), reaching the zone.   |
//| If price closes through it, the level is broken, not swept.        |
//| Returns the most significant swept level (highest high / lowest    |
//| low). So: the lines you see ARE the liquidity, and taking one is    |
//| the sweep that arms the IFVG.                                       |
//+------------------------------------------------------------------+
bool CheckSweep(const MqlRates &r[], int total, bool bearish, int m, int brk,
                double gapLow, double gapHigh, double atr,
                datetime &swTime, double &swLevel, double &swExtreme, datetime &swBreak)
  {
   int    np      = ArraySize(g_majPx);
   double maxDist = (InpSweepMaxDistATR > 0 && atr > 0) ? InpSweepMaxDistATR * atr : DBL_MAX;
   int    oldestJ = (InpSweepMaxBarsBack > 0) ? brk + InpSweepMaxBarsBack : total; // grab must be shortly BEFORE the inversion (it caused this reversal)
   int    reclaim = (InpSweepReclaimBars > 1) ? InpSweepReclaimBars : 1;           // candles allowed for the run-and-reclaim
   bool   found = false;
   for(int p = 0; p < np; p++)
     {
      int idx = g_majIdx[p];
      if(idx <= brk + 1) continue;                 // the major must sit before the inversion
      if(bearish && g_majHi[p])                    // a Major HIGH taken out = sell-side sweep
        {
         double level = g_majPx[p];
         if(level < gapLow) continue;              // real overhead liquidity (at/above the zone)
         if(level - gapHigh > maxDist) continue;   // pool too FAR above the zone = not this setup's liquidity
         if(found && level <= swLevel) continue;   // keep the HIGHEST swept high
         for(int j = idx - 1; j >= brk; j--)       // first time price returns to the level
           {
            if(r[j].high <= level) continue;       // not reached yet -> still resting
            // Grab must be recent: sweep -> reversal -> inversion, one play.
            if(j > oldestJ) break;                 // grabbed long before the inversion -> stale, not its sweep

            // Run-and-reclaim: the take may span a few candles. Price may even
            // CLOSE above the level, but must close back BELOW it within the
            // reclaim window -- otherwise the level BROKE (CHoCH), not swept.
            int lastC = j - (reclaim - 1); if(lastC < brk) lastC = brk;
            double runHigh = 0.0; int extIdx = j; int rec = -1;
            for(int c = j; c >= lastC; c--)
              {
               if(r[c].high > runHigh) { runHigh = r[c].high; extIdx = c; }
               if(r[c].close < level)  { rec = c; break; }
              }
            if(rec >= 0 && runHigh >= gapHigh)     // reclaimed + the run reached the zone
              {
               // If price later runs ABOVE the grab's extreme before the
               // inversion, the level actually broke after all -- no grab.
               bool ranThrough = false;
               for(int x = rec - 1; x >= brk; x--)
                  if(r[x].high > runHigh) { ranThrough = true; break; }
               if(!ranThrough)
                 { swTime = r[idx].time; swLevel = level; swExtreme = runHigh; swBreak = r[extIdx].time; found = true; }
              }
            break;                                 // first-touch event handled either way
           }
        }
      else if(!bearish && !g_majHi[p])             // a Major LOW taken out = buy-side sweep
        {
         double level = g_majPx[p];
         if(level > gapHigh) continue;             // real liquidity below (at/below the zone)
         if(gapLow - level > maxDist) continue;    // pool too FAR below the zone
         if(found && level >= swLevel) continue;   // keep the LOWEST swept low
         for(int j = idx - 1; j >= brk; j--)
           {
            if(r[j].low >= level) continue;
            if(j > oldestJ) break;                 // grabbed long before the inversion -> stale

            int lastC = j - (reclaim - 1); if(lastC < brk) lastC = brk;
            double runLow = DBL_MAX; int extIdx = j; int rec = -1;
            for(int c = j; c >= lastC; c--)
              {
               if(r[c].low < runLow)  { runLow = r[c].low; extIdx = c; }
               if(r[c].close > level) { rec = c; break; }
              }
            if(rec >= 0 && runLow <= gapLow)
              {
               bool ranThrough = false;            // grab extreme later violated = level broke, not swept
               for(int x = rec - 1; x >= brk; x--)
                  if(r[x].low < runLow) { ranThrough = true; break; }
               if(!ranThrough)
                 { swTime = r[idx].time; swLevel = level; swExtreme = runLow; swBreak = r[extIdx].time; found = true; }
              }
            break;
           }
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Confluence: market-structure shift -- the break candle closes     |
//| beyond the most recent swing pivot in the trade direction.        |
//+------------------------------------------------------------------+
bool CheckMSS(const MqlRates &r[], int total, bool bearish, int brk, int m,
              datetime &mssTime, double &mssLevel)
  {
   int k    = InpSwingBars;
   int last = MathMin(total - k - 1, m + 96);      // pivots up to ~96 bars before the gap
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

// The binary reliability features of a setup, in g_ftName order:
// swp = sweep close to the zone, gap = sizeable imbalance, brk = decisive
// inversion candle, tp = target at real liquidity, trd = with the HTF trend.
void SetupFeatures(const IFVGSetup &s, bool &f[])
  {
   f[0] = (s.sweepDistATR <= 1.5);
   f[1] = (s.gapATR >= 0.5);
   f[2] = (s.brkDispATR >= 0.7);
   f[3] = s.tpIsLiquidity;
   f[4] = s.withTrend;
  }

//+------------------------------------------------------------------+
//| Win-probability for a setup. Two honest numbers:                  |
//|  needPct = the break-even win rate this R:R demands (pure math,   |
//|            = 100/(1+RR)) -- you must win MORE than this to profit. |
//|  estPct  = evidence-based: the strategy's historical win rate,     |
//|            adjusted by how setups sharing THIS setup's features    |
//|            actually performed (damped marginals from the factor    |
//|            stats). Falls back to a crude nudge until enough        |
//|            history has accumulated.                                |
//+------------------------------------------------------------------+
void SetupOdds(const IFVGSetup &s, double &estPct, double &needPct)
  {
   needPct = (s.rr > 0) ? 100.0 / (1.0 + s.rr) : 100.0;
   int    tot  = g_btWins + g_btLosses;
   double base = (tot >= 10) ? (100.0 * g_btWins / tot) : 50.0;
   double est  = base;
   if(tot >= 10)
     {
      bool f[NFEAT]; SetupFeatures(s, f);
      for(int q = 0; q < NFEAT; q++)
        {
         int b = f[q] ? 1 : 0;
         if(g_ftTot[q][b] >= 8)                 // enough closed samples in this cell
            est += 0.5 * (100.0 * g_ftWin[q][b] / g_ftTot[q][b] - base);   // damped marginal edge
        }
     }
   else
      est = base * (s.tpIsLiquidity ? 1.10 : 0.85);   // crude fallback until history builds
   estPct = MathMax(5.0, MathMin(95.0, est));
  }

string OddsGrade(double estPct, double needPct)
  {
   double edge = estPct - needPct;                  // estimated win% over the break-even it needs
   if(edge >= 15) return "A";
   if(edge >= 5)  return "B";
   if(edge >= 0)  return "C";
   return "avoid";
  }

//+------------------------------------------------------------------+
//| Step 6: next draw on liquidity beyond entry. We target the nearest |
//| swing that is STILL UNTAPPED -- a level price has not already      |
//| traded through is real resting liquidity to draw to; a swing that  |
//| was since swept is spent and makes a poor target. Falls back (via  |
//| the caller's RR target) when no untapped pool exists ahead.        |
//+------------------------------------------------------------------+
bool FindLiquidityTarget(const MqlRates &r[], int total, bool forLong, double entry, double &tp)
  {
   int k = InpSwingBars;
   for(int i = k; i < total - k; i++)
     {
      if(forLong  && IsSwingHigh(r, i, k) && r[i].high > entry && UntappedHigh(r, i, r[i].high))
        { tp = r[i].high; return true; }
      if(!forLong && IsSwingLow(r, i, k)  && r[i].low  < entry && UntappedLow(r, i, r[i].low))
        { tp = r[i].low;  return true; }
     }
   return false;
  }

// Record the reason the freshest IFVG candidate per direction was rejected
// (only the newest one per side, for the diagnostic).
void RecReject(bool diag, bool bearish, string reason)
  {
   if(!diag) return;
   if(bearish) { if(g_rejSell == "") g_rejSell = reason; }
   else        { if(g_rejBuy  == "") g_rejBuy  = reason; }
  }

// Record a rejected IFVG candidate so it can be drawn as a faded "ghost"
// zone with its reason -- this is what answers "why wasn't this marked?".
void PushGhost(bool diag, bool bearish, double gapLow, double gapHigh,
               datetime gapTime, datetime breakTime, string reason)
  {
   if(!diag) return;
   if(ArraySize(g_ghosts) >= 20) return;            // cap (most-recent first), to keep the chart readable
   IFVGSetup g; ZeroMemory(g);
   g.bullish = !bearish; g.gapLow = gapLow; g.gapHigh = gapHigh;
   g.gapTime = gapTime;  g.breakTime = breakTime;   g.rejReason = reason;
   int sz = ArraySize(g_ghosts); ArrayResize(g_ghosts, sz + 1); g_ghosts[sz] = g;
  }

//+------------------------------------------------------------------+
//| Core: scan the window for inverted FVGs (most recent first).      |
//| diag=true records WHY the freshest candidate was/wasn't taken.    |
//+------------------------------------------------------------------+
int FindIFVGs(const MqlRates &r[], int total, IFVGSetup &out[], int maxSetups, bool diag=false)
  {
   ArrayResize(out, 0);
   if(diag) { g_rejBuy = ""; g_rejSell = ""; ArrayResize(g_ghosts, 0); }
   double atr = GetATR();
   if(atr <= 0.0)
      return 0;
   double minGap = InpMinGapATR  * atr;
   double buf    = InpSLBufferATR * atr;

   // Spread used for the entry/SL/TP adjustments, capped at the effective
   // spread limit so an abnormal weekend/news spread can't skew the levels.
   double liveSpread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   int    sprCapPts  = EffMaxSpreadPts();
   if(sprCapPts > 0) liveSpread = MathMin(liveSpread, sprCapPts * _Point);

   // Major structure pivots for this window = the liquidity the sweep hunts for
   // (same detector as the drawn Major lines, so they match).
   ComputeMajorPivots(r, total, AtrFromRates(r, total, InpATRPeriod), g_majIdx, g_majPx, g_majHi);

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

         // Freshness: the inversion must follow the gap within the cap. In the
         // method the sweep, reversal and close-through are ONE play -- a gap
         // that only gets closed-through a day later is a stale leftover.
         if(InpMaxGapAgeBars > 0 && (m - brk) > InpMaxGapAgeBars) continue;

         // Invalidation: price later closed back through the far side.
         bool failed = false;
         for(int j = brk - 1; j >= 0; j--)
           {
            if(bearish  && r[j].close > gapHigh) { failed = true; break; }
            if(!bearish && r[j].close < gapLow)  { failed = true; break; }
           }
         if(failed) continue;

         // --- this is now a real IFVG candidate (valid gap + confirmed inversion) ---

         // Step 1: HTF bias filter -- judged AS OF this setup's break, so an
         // older setup is filtered by its own day's trend, not today's.
         if(g_useHTFBias)
           {
            bool bUp, bDown; HTFBiasAt(r[brk].time, bUp, bDown);
            if((bearish && !bDown) || (!bearish && !bUp))
              { RecReject(diag, bearish, "HTF bias"); PushGhost(diag, bearish, gapLow, gapHigh, r[m+1].time, r[brk].time, "HTF bias"); continue; }
           }

         // Confluences -- the liquidity sweep is the PRIMARY reversal signal,
         // so it is checked first; MSS is an optional extra (off by default).
         datetime swTime = 0, swBreak = 0; double swLevel = 0, swExtreme = 0;
         bool hadSweep = CheckSweep(r, total, bearish, m, brk, gapLow, gapHigh, atr, swTime, swLevel, swExtreme, swBreak);
         if(g_useSweep && !hadSweep)
           { RecReject(diag, bearish, "no sweep"); PushGhost(diag, bearish, gapLow, gapHigh, r[m+1].time, r[brk].time, "no sweep"); continue; }

         datetime mssTime = 0; double mssLevel = 0;
         bool hadMSS = CheckMSS(r, total, bearish, brk, m, mssTime, mssLevel);
         if(g_useMSS && !hadMSS)
           { RecReject(diag, bearish, "no MSS"); PushGhost(diag, bearish, gapLow, gapHigh, r[m+1].time, r[brk].time, "no MSS"); continue; }

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
         s.hadSweep = hadSweep; s.sweepTime = swTime; s.sweepLevel = swLevel; s.sweepExtreme = swExtreme; s.sweepBreakTime = swBreak;
         s.hadMSS = hadMSS; s.mssTime = mssTime; s.mssLevel = mssLevel;

         s.tested = false;
         int touchIdx = -1;
         for(int j = brk - 1; j >= 0; j--)
            if(r[j].low <= gapHigh && r[j].high >= gapLow) { s.tested = true; touchIdx = j; break; }

         // A grab whose wick extreme gets RUN THROUGH after the inversion but
         // BEFORE the retest is not a grab anymore -- the level broke (CHoCH /
         // continuation), so the reversal premise is gone and the setup is void.
         // (After the retest a live trade's SL owns the risk instead.)
         if(hadSweep)
           {
            int stopAt = (touchIdx >= 0) ? touchIdx + 1 : 0;
            bool grabFailed = false;
            for(int x = brk - 1; x >= stopAt; x--)
               if(bearish ? (r[x].high > swExtreme) : (r[x].low < swExtreme)) { grabFailed = true; break; }
            if(grabFailed)
              { RecReject(diag, bearish, "sweep failed"); PushGhost(diag, bearish, gapLow, gapHigh, r[m+1].time, r[brk].time, "sweep failed"); continue; }
           }

         double price = r[0].close;
         s.stage = (price >= gapLow && price <= gapHigh) ? "ready" : "forming";

         // Entry at the PROXIMAL edge -- the side price reaches FIRST on the
         // retest: the BOTTOM of the zone for a sell (price rallies up into
         // resistance), the TOP for a buy (price drops into support).
         // SL beyond the far extreme; TP at the next liquidity.
         double spread = liveSpread;
         s.entry = bearish ? gapLow : gapHigh;
         // A BUY fills at Ask, so lift its entry by the spread to fill the instant
         // the Bid chart touches the zone top (a sell fills at Bid -> no change).
         if(InpBuyEntrySpreadAdj && !bearish)
            s.entry += spread;
         s.sl    = bearish ? gapHigh + buf : gapLow - buf;

         // SL floor: a thin zone gives a stop so tight that spread/noise kills
         // it (e.g. 0.6$ on gold). Widen to the ATR floor -- the risk-% lot
         // shrinks to match, so $ risk is unchanged while survival improves.
         if(InpMinSLATR > 0)
           {
            double minSL = InpMinSLATR * atr;
            if(MathAbs(s.entry - s.sl) < minSL)
               s.sl = bearish ? s.entry + minSL : s.entry - minSL;
           }
         // SL cap: a stop wider than this is a different trade class -- skip.
         if(InpMaxSLATR > 0 && MathAbs(s.entry - s.sl) > InpMaxSLATR * atr)
           { RecReject(diag, bearish, "SL too wide"); PushGhost(diag, bearish, gapLow, gapHigh, r[m+1].time, r[brk].time, "SL too wide"); continue; }

         double tp;
         if(FindLiquidityTarget(r, total, !bearish, s.entry, tp))
           { s.tp = tp; s.tpIsLiquidity = true; }
         else
           {
            s.tp = bearish ? s.entry - (s.sl - s.entry) * g_minRR
                           : s.entry + (s.entry - s.sl) * g_minRR;
            s.tpIsLiquidity = false;
           }

         // Spread accounting: a SELL enters on Bid but its SL/TP are evaluated
         // on Ask (= Bid + spread), so both would trigger a spread early. Shift
         // them up by the spread to keep them on the chart (Bid) levels. A BUY
         // exits on Bid already, so its SL/TP need no adjustment.
         if(InpSpreadAdjust && bearish)
           {
            s.sl += spread;
            s.tp += spread;
           }
         double risk = MathAbs(s.entry - s.sl);
         s.rr = (risk > 0) ? MathAbs(s.tp - s.entry) / risk : 0.0;

         // Quality gate: reject setups whose target is too close to be worth it.
         if(InpMinRRFilter > 0 && s.rr < InpMinRRFilter)
           { RecReject(diag, bearish, "low R:R"); PushGhost(diag, bearish, s.gapLow, s.gapHigh, s.gapTime, s.breakTime, "low R:R"); continue; }

         // Reliability features, for the evidence-based odds + factor stats.
         s.gapATR       = (gapHigh - gapLow) / atr;
         s.brkDispATR   = MathAbs(r[brk].close - r[brk].open) / atr;
         s.sweepDistATR = 0.0;
         if(hadSweep)
           {
            double d = bearish ? (swLevel - gapHigh) : (gapLow - swLevel);
            s.sweepDistATR = MathMax(0.0, d) / atr;
           }
         bool tUp, tDown; HTFBiasAt(r[brk].time, tUp, tDown);
         s.withTrend = bearish ? tDown : tUp;

         RecReject(diag, bearish, "ok");        // passed all filters

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

   double est, need; SetupOdds(s, est, need);
   string tag = (s.bullish ? "IFVG BUY  " : "IFVG SELL ") + "R:R " + DoubleToString(s.rr, 1) +
                "  win~" + DoubleToString(est, 0) + "% (" + OddsGrade(est, need) + ")" +
                (s.hadSweep ? "  swept " + DoubleToString(s.sweepLevel, _Digits) : "") +
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

   // The liquidity sweep that fed it: a line at the POOL level (the liquidity
   // that got taken) from the pool to the sweep candle, an arrow on the wick
   // that took it, and a label naming the side.
   if(s.hadSweep)
     {
      datetime swEnd = (s.sweepBreakTime > s.sweepTime) ? s.sweepBreakTime : s.breakTime;
      HLine(base + "SwpL", s.sweepTime, swEnd, s.sweepLevel, InpSweepColor, STYLE_DASH, 1);
      ArrowAt(base + "Swp", s.sweepBreakTime, s.sweepExtreme, 159, InpSweepColor,
              s.bullish ? ANCHOR_TOP : ANCHOR_BOTTOM);
      TextAt(base + "SwpT", s.sweepTime, s.sweepLevel, s.bullish ? "swept SSL " : "swept BSL ",
             InpSweepColor, s.bullish ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER);
     }
  }

//+------------------------------------------------------------------+
//| Draw rejected IFVG candidates as faded, hollow "ghost" zones with |
//| the reason -- so you can SEE the gaps that had a valid inversion  |
//| but failed a filter (no MSS / no sweep / HTF bias / low R:R), and |
//| why they weren't marked as tradable setups.                       |
//+------------------------------------------------------------------+
void DrawGhosts()
  {
   if(!InpShowRejected) return;
   int n = ArraySize(g_ghosts);
   for(int i = 0; i < n; i++)
     {
      IFVGSetup g = g_ghosts[i];
      string base = PFX + "G" + IntegerToString(i) + "_";
      datetime tR = g.breakTime + (datetime)(PeriodSeconds(_Period) * InpZoneExtendBars);
      if(tR <= g.breakTime) tR = g.breakTime + PeriodSeconds(_Period);

      string z = base + "Zone";
      if(ObjectFind(0, z) >= 0) ObjectDelete(0, z);
      if(ObjectCreate(0, z, OBJ_RECTANGLE, 0, g.gapTime, g.gapHigh, tR, g.gapLow))
        {
         ObjectSetInteger(0, z, OBJPROP_COLOR, C'90,95,105');   // muted grey, hollow
         ObjectSetInteger(0, z, OBJPROP_FILL, false);
         ObjectSetInteger(0, z, OBJPROP_BACK, true);
         ObjectSetInteger(0, z, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, z, OBJPROP_SELECTABLE, false);
        }
      string tag = (g.bullish ? "buy? " : "sell? ") + g.rejReason;
      TextAt(base + "Lbl", g.gapTime, g.bullish ? g.gapLow : g.gapHigh, tag, C'120,125,135',
             g.bullish ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
     }
  }

// Draw one structure break: a line at the broken level + a BOS/CHoCH label.
void DrawStructBreak(string tag, datetime t1, datetime t2, double price, string label, color c)
  {
   string nm = PFX + "MS_" + tag + "BRK_" + IntegerToString((int)t2);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   TextAt(nm + "L", t2, price, " " + label, c, ANCHOR_LEFT);
  }

//+------------------------------------------------------------------+
//| Proper market-structure engine for ONE timeframe.                 |
//|  - confirms swing highs/lows (fractal, strength InpStructSwingBars)|
//|  - labels them HH/HL/LH/LL relative to the prior same-type swing   |
//|  - tracks trend and marks the EVENTS where price CLOSES through    |
//|    the reference swing:  BOS = continuation, CHoCH = reversal.     |
//| A swing is only breakable AFTER it is confirmed (no look-ahead),   |
//| and each reference level fires once. tag namespaces the TF.        |
//+------------------------------------------------------------------+
void DrawStructureTF(ENUM_TIMEFRAMES tf, color hiCol, color loCol, string tag, int barsWanted)
  {
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   int total = CopyRates(_Symbol, tf, 1, barsWanted, rr);
   int k = InpStructSwingBars;
   if(total < 2 * k + 5) return;

   double   refHigh = 0, refLow = 0;     datetime refHighT = 0, refLowT = 0;
   bool     haveRefHigh = false, haveRefLow = false;
   int      trend = 0;                    // 1 up, -1 down, 0 none
   double   prevSH = 0, prevSL = 0;       bool havePrevSH = false, havePrevSL = false;

   // collect break events, then draw only the most recent N (declutters low TFs)
   datetime brT1[]; datetime brT2[]; double brPx[]; bool brBOS[];
   ArrayResize(brT1,0); ArrayResize(brT2,0); ArrayResize(brPx,0); ArrayResize(brBOS,0);

   for(int i = total - k - 1; i >= 0; i--)        // oldest -> newest
     {
      double c = rr[i].close;

      // (A) structure break on this close, against the last confirmed swings
      if(haveRefHigh && c > refHigh)
        {
         bool isBOS = (trend != -1);              // up-break: BOS unless we were bearish
         int s=ArraySize(brT1); ArrayResize(brT1,s+1);ArrayResize(brT2,s+1);ArrayResize(brPx,s+1);ArrayResize(brBOS,s+1);
         brT1[s]=refHighT; brT2[s]=rr[i].time; brPx[s]=refHigh; brBOS[s]=isBOS;
         trend = 1; haveRefHigh = false;
        }
      else if(haveRefLow && c < refLow)
        {
         bool isBOS = (trend != 1);               // down-break: BOS unless we were bullish
         int s=ArraySize(brT1); ArrayResize(brT1,s+1);ArrayResize(brT2,s+1);ArrayResize(brPx,s+1);ArrayResize(brBOS,s+1);
         brT1[s]=refLowT; brT2[s]=rr[i].time; brPx[s]=refLow; brBOS[s]=isBOS;
         trend = -1; haveRefLow = false;
        }

      // (B) confirm the swing at j = i+k (it now has k newer bars), set it as the
      //     new reference, and label it HH/HL/LH/LL vs the prior same-type swing.
      int j = i + k;
      if(j <= total - 1 - k)
        {
         if(IsSwingHigh(rr, j, k))
           {
            refHigh = rr[j].high; refHighT = rr[j].time; haveRefHigh = true;
            if(InpShowSwingLabels)
              {
               string lbl = !havePrevSH ? "H" : (rr[j].high > prevSH ? "HH" : "LH");
               TextAt(PFX + "MS_" + tag + "H_" + IntegerToString((int)rr[j].time), rr[j].time, rr[j].high, tag + lbl, hiCol, ANCHOR_LOWER);
              }
            prevSH = rr[j].high; havePrevSH = true;
           }
         if(IsSwingLow(rr, j, k))
           {
            refLow = rr[j].low; refLowT = rr[j].time; haveRefLow = true;
            if(InpShowSwingLabels)
              {
               string lbl = !havePrevSL ? "L" : (rr[j].low < prevSL ? "LL" : "HL");
               TextAt(PFX + "MS_" + tag + "L_" + IntegerToString((int)rr[j].time), rr[j].time, rr[j].low, tag + lbl, loCol, ANCHOR_UPPER);
              }
            prevSL = rr[j].low; havePrevSL = true;
           }
        }
     }

   // draw only the most recent N breaks (0 = all)
   int nb = ArraySize(brT1);
   int from = (InpMaxStructBreaks > 0) ? MathMax(0, nb - InpMaxStructBreaks) : 0;
   for(int b = from; b < nb; b++)
      DrawStructBreak(tag, brT1[b], brT2[b], brPx[b], tag + (brBOS[b] ? "BOS" : "CHoCH"),
                      brBOS[b] ? InpBOSColor : InpCHoCHColor);
  }
int MTFBars(ENUM_TIMEFRAMES tf, int fromBars)
  {
   double span = (double)fromBars * PeriodSeconds(_Period);
   int b = (int)(span / PeriodSeconds(tf)) + 4 * InpSwingBars + 12;
   return (int)MathMax(30.0, MathMin(5000.0, (double)b));
  }

//+------------------------------------------------------------------+
//| MAJOR structure by SIGNIFICANCE, not a fixed bar count. An ATR-    |
//| scaled zigzag: a swing is only confirmed once price reverses by    |
//| >= InpMajorMoveATR * ATR from the extreme, so a level that led to  |
//| a big move (lots of internal liquidity worked through it) becomes  |
//| a major high/low. Because it keys off ATR it auto-adapts to the    |
//| timeframe -- M5 gets its own majors, M15 its own. Labelled         |
//| HH/HL/LH/LL and drawn as level lines ending at first contact.      |
//| Falls back to bar-count strength when InpMajorMoveATR = 0.         |
//+------------------------------------------------------------------+
// Shared major-pivot detector (used by both the drawing and the sweep, so the
// swept levels are exactly the Major lines you see). ATR-scaled zigzag: a swing
// confirms once price reverses >= InpMajorMoveATR*ATR. Pivots are chronological.
void ComputeMajorPivots(const MqlRates &rr[], int total, double atr,
                        int &pIdx[], double &pPx[], bool &pHi[])
  {
   ArrayResize(pIdx, 0); ArrayResize(pPx, 0); ArrayResize(pHi, 0);
   if(total < 10) return;
   if(InpMajorMoveATR > 0.0 && atr > 0.0)
     {
      double thresh = InpMajorMoveATR * atr;
      double curHi = rr[total - 1].high; int curHiIdx = total - 1;
      double curLo = rr[total - 1].low;  int curLoIdx = total - 1;
      int    dir   = 0;
      for(int i = total - 2; i >= 0; i--)                // oldest -> newest
        {
         if(rr[i].high > curHi) { curHi = rr[i].high; curHiIdx = i; }
         if(rr[i].low  < curLo) { curLo = rr[i].low;  curLoIdx = i; }
         if(dir != -1 && rr[i].low <= curHi - thresh)
           {
            // record only if the leg's peak is a real fractal swing high
            if(IsSwingHigh(rr, curHiIdx, InpMajorPivotBars))
              { int s = ArraySize(pIdx); ArrayResize(pIdx,s+1); ArrayResize(pPx,s+1); ArrayResize(pHi,s+1);
                pIdx[s]=curHiIdx; pPx[s]=curHi; pHi[s]=true; }
            dir = -1; curLo = rr[i].low; curLoIdx = i;
           }
         else if(dir != 1 && rr[i].high >= curLo + thresh)
           {
            if(IsSwingLow(rr, curLoIdx, InpMajorPivotBars))
              { int s = ArraySize(pIdx); ArrayResize(pIdx,s+1); ArrayResize(pPx,s+1); ArrayResize(pHi,s+1);
                pIdx[s]=curLoIdx; pPx[s]=curLo; pHi[s]=false; }
            dir = 1; curHi = rr[i].high; curHiIdx = i;
           }
        }
     }
   else                                                  // fallback: fractal strength
     {
      int k = InpMajorSwingBars;
      if(total < 2 * k + 5) return;
      for(int i = total - k - 1; i >= k; i--)
        {
         if(IsSwingHigh(rr, i, k))
           { int s=ArraySize(pIdx); ArrayResize(pIdx,s+1); ArrayResize(pPx,s+1); ArrayResize(pHi,s+1);
             pIdx[s]=i; pPx[s]=rr[i].high; pHi[s]=true; }
         if(IsSwingLow(rr, i, k))
           { int s=ArraySize(pIdx); ArrayResize(pIdx,s+1); ArrayResize(pPx,s+1); ArrayResize(pHi,s+1);
             pIdx[s]=i; pPx[s]=rr[i].low; pHi[s]=false; }
        }
     }
  }

void DrawMajorStructure(ENUM_TIMEFRAMES tf, int barsWanted)
  {
   if(!InpShowMajorStruct) return;
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   int total = CopyRates(_Symbol, tf, 1, barsWanted, rr);
   if(total < 10) return;
   datetime tNow = iTime(_Symbol, _Period, 0);          // extend lines to the current chart bar

   int    pIdx[];  double pPx[];  bool pHi[];
   ComputeMajorPivots(rr, total, AtrFromRates(rr, total, InpATRPeriod), pIdx, pPx, pHi);

   int np = ArraySize(pIdx);
   if(np == 0) return;

   // ---- label HH/HL/LH/LL vs the prior same-type major (chronological) ----
   string pLbl[]; ArrayResize(pLbl, np);
   double ph=0, pl=0; bool haveH=false, haveL=false;
   for(int p = 0; p < np; p++)
     {
      if(pHi[p]) { pLbl[p] = !haveH ? "H" : (pPx[p] > ph ? "HH" : "LH"); ph = pPx[p]; haveH = true; }
      else       { pLbl[p] = !haveL ? "L" : (pPx[p] < pl ? "LL" : "HL"); pl = pPx[p]; haveL = true; }
     }

   // ---- draw every major within the requested history window (newest first) ----
   datetime cutoff = tNow - (datetime)(InpMajorDays * 86400.0);   // at least this far back
   for(int p = np - 1; p >= 0; p--)
     {
      int i = pIdx[p]; double lvl = pPx[p];
      if(rr[i].time < cutoff) break;                    // older than the window -> stop
      datetime end = tNow;
      if(pHi[p])
        {
         for(int j = i - 1; j >= 0; j--) if(rr[j].high >= lvl) { end = rr[j].time; break; }
         string nm = PFX + "MS_MAJH_" + IntegerToString((int)rr[i].time);
         HLine(nm, rr[i].time, end, lvl, InpMajorStructColor, STYLE_SOLID, 2);
         TextAt(nm + "t", rr[i].time, lvl, "Major " + pLbl[p] + " ", InpMajorStructColor, ANCHOR_RIGHT_LOWER);
        }
      else
        {
         for(int j = i - 1; j >= 0; j--) if(rr[j].low <= lvl) { end = rr[j].time; break; }
         string nm = PFX + "MS_MAJL_" + IntegerToString((int)rr[i].time);
         HLine(nm, rr[i].time, end, lvl, InpMajorStructColor, STYLE_SOLID, 2);
         TextAt(nm + "t", rr[i].time, lvl, "Major " + pLbl[p] + " ", InpMajorStructColor, ANCHOR_RIGHT_UPPER);
        }
     }
  }

void DrawStructure(int total)
  {
   if(!InpShowStructure) return;
   DrawStructureTF(_Period, InpStructHighColor, InpStructLowColor, "", total);
   // Major structure is read from the CHART timeframe, so structure and
   // liquidity adapt to whatever TF you view. Fetch enough bars to cover the
   // requested history window (InpMajorDays) even if the scan window is shorter.
   int majBars = total;
   if(PeriodSeconds(_Period) > 0)
     {
      int wantDays = (int)MathRound(InpMajorDays * 24.0 * 3600.0 / PeriodSeconds(_Period)) + 4 * InpATRPeriod + 20;
      majBars = (int)MathMin(6000.0, MathMax((double)total, (double)wantDays));
     }
   DrawMajorStructure((ENUM_TIMEFRAMES)_Period, majBars);
   if(InpMTFStructure)
     {
      DrawStructureTF(InpStructTF2, InpStructTF2Color, InpStructTF2Color, ShortTF(InpStructTF2) + " ", MTFBars(InpStructTF2, total));
      DrawStructureTF(InpStructTF3, InpStructTF3Color, InpStructTF3Color, ShortTF(InpStructTF3) + " ", MTFBars(InpStructTF3, total));
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

   int x = 8, yTop = 16, panelW = 344, headerH = 22, rowH = 16;
   int keyX = x + 8, valX = x + 124, contentY = yTop + headerH + 5;

   string sfx[]   = {"Sym","Mode","Bias","Mkt","Filt","Set","Diag",
                     "SecBT","WL","WR","Net","OpenT","Fx",
                     "SecAcc","Eq","Pos","PL",
                     "SecDay","Day","DayTr","Risk",
                     "Auto","Live","Odds"};
   string left[]  = {"Symbol","Mode","HTF bias","Spread/ATR","Filters","Setups","Last IFVG",
                     "--- BACKTEST ---","Win / Loss","Win rate","Net / PF","Open / no-fill","Factor edge",
                     "--- ACCOUNT ---","Equity / Bal","Pos / Pend","Float P/L",
                     "--- DAILY / RISK ---","Today P/L","Trades today","Risk / lot",
                     "Auto-trade","Live setup","Win odds"};
   bool   isSec[] = {false,false,false,false,false,false,false,
                     true,false,false,false,false,false,
                     true,false,false,false,
                     true,false,false,false,
                     false,false,false};
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
   string biasTxt = !g_useHTFBias ? "off" : (g_htfUp && !g_htfDown ? "BULL" : (g_htfDown && !g_htfUp ? "BEAR" : "neutral"));
   color  biasCol = (biasTxt == "BULL") ? clrLime : (biasTxt == "BEAR") ? clrTomato : clrSilver;
   double atr = GetATR();
   long   spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   SetVal("Sym",  _Symbol + "  " + ShortTF((ENUM_TIMEFRAMES)_Period), clrWhite);
   SetVal("Mode", (InpScalpMode ? "SCALP (M15 in/out)" : "Positional (HTF)")
                  + StringFormat("  RR>=%.1f  BE %.1fR", g_minRR, (InpBreakEven ? g_beTriggerR : 0.0)),
                  InpScalpMode ? clrGold : clrAqua);
   SetVal("Bias", biasTxt + (InpScalpMode ? " (SCALP M15)" : " (" + ShortTF(InpHTF) + ")"), biasCol);
   int    sprCap = EffMaxSpreadPts();
   string sprTxt = "spread " + IntegerToString((int)spr) + (sprCap > 0 ? "/" + IntegerToString(sprCap) : "/-")
                   + " pts   ATR " + DoubleToString(atr, _Digits);
   SetVal("Mkt",  sprTxt, (sprCap > 0 && spr > sprCap) ? clrTomato : clrSilver);
   string fl = (g_useSweep ? "Sweep " : "") + (g_useMSS ? "MSS " : "") + (g_useHTFBias ? "HTF" : "");
   if(fl == "") fl = "none";
   SetVal("Filt", fl, clrAqua);
   SetVal("Set",  IntegerToString(g_lastBull) + " buy / " + IntegerToString(g_lastBear) + " sell", clrWhite);
   string rb = (g_rejBuy  == "" ? "none" : (g_rejBuy  == "ok" ? "ok" : "rej(" + g_rejBuy  + ")"));
   string rs = (g_rejSell == "" ? "none" : (g_rejSell == "ok" ? "ok" : "rej(" + g_rejSell + ")"));
   color  dc = (g_rejBuy == "ok" || g_rejSell == "ok") ? clrLime : clrSilver;
   SetVal("Diag", "buy " + rb + "  sell " + rs, dc);

   if(InpShowBacktest)
     {
      int    tot = g_btWins + g_btLosses;
      double wr  = (tot > 0) ? 100.0 * g_btWins / tot : 0.0;
      double pf  = (g_btLosses > 0) ? g_btGrossWin / (double)g_btLosses : (g_btGrossWin > 0 ? 999.0 : 0.0);
      SetVal("WL",    IntegerToString(g_btWins) + "W / " + IntegerToString(g_btLosses) + "L", clrWhite);
      SetVal("WR",    DoubleToString(wr, 0) + "%   (" + IntegerToString(tot) + " trades)", wr >= 50 ? clrLime : clrGold);
      SetVal("Net",   StringFormat("%+.1fR   PF %s", g_btTotalR, (pf >= 999 ? "inf" : DoubleToString(pf, 2))), g_btTotalR >= 0 ? clrLime : clrTomato);
      SetVal("OpenT", IntegerToString(g_btOpen) + " open / " + IntegerToString(g_btNoFill) + " no-fill", clrSilver);

      // Per-factor historical edge: win% WITH the feature minus win% WITHOUT.
      // Positive = that trait made setups more reliable here. Needs samples
      // on both sides before a factor shows.
      string fx = "";
      for(int q = 0; q < NFEAT; q++)
         if(g_ftTot[q][0] >= 8 && g_ftTot[q][1] >= 8)
           {
            double d = 100.0 * g_ftWin[q][1] / g_ftTot[q][1]
                     - 100.0 * g_ftWin[q][0] / g_ftTot[q][0];
            fx += g_ftName[q] + StringFormat("%+.0f  ", d);
           }
      if(fx == "") fx = "building history...";
      SetVal("Fx", fx, clrAqua);
     }
   else
     {
      SetVal("WL", "off", clrSilver); SetVal("WR", "-", clrSilver);
      SetVal("Net", "-", clrSilver);  SetVal("OpenT", "-", clrSilver);
      SetVal("Fx", "-", clrSilver);
     }

   int pos, pend; double fpl; MyAccountStats(pos, pend, fpl);
   SetVal("Eq",  DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " / " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), clrWhite);
   SetVal("Pos", IntegerToString(pos) + " pos / " + IntegerToString(pend) + " pend", clrWhite);
   SetVal("PL",  DoubleToString(fpl, 2), fpl >= 0 ? clrLime : clrTomato);

   // ---- daily circuit-breakers + per-trade risk (the live safety rails) ----
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   bool   dayOK = DailyLimitsOK();
   string dayTxt = DoubleToString(g_dayPL, 2) + " " + ccy;
   double dlim = DailyLossLimit();
   if(dlim > 0) dayTxt += StringFormat("  (limit -%.2f)", dlim);
   SetVal("Day", dayTxt + (dayOK ? "" : "  HALTED"), g_dayPL > 0 ? clrLime : (g_dayPL < 0 ? clrTomato : clrSilver));

   string trTxt = IntegerToString(g_dayTrades) + (InpMaxTradesPerDay > 0 ? " / " + IntegerToString(InpMaxTradesPerDay) : "");
   bool   trCap = (InpMaxTradesPerDay > 0 && g_dayTrades >= InpMaxTradesPerDay);
   SetVal("DayTr", trTxt + (trCap ? "  (cap hit)" : ""), trCap ? clrTomato : clrWhite);

   string riskTxt;
   if(InpRiskPercent > 0)
     {
      double rm = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double nlot = (g_liveValid && g_liveSL > 0) ? LotForTrade(g_liveEntry, g_liveSL) : 0.0;
      riskTxt = StringFormat("%.2f%% = %.2f %s", InpRiskPercent, rm, ccy)
                + (nlot > 0 ? StringFormat("  ~%.2f lot", nlot) : "");
     }
   else
      riskTxt = StringFormat("fixed %.2f lot", InpLotSize);
   SetVal("Risk", riskTxt, clrWhite);

   // newest setup + how close it is to triggering
   if(!g_liveValid)
      SetVal("Live", "none", clrSilver);
   else
     {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      int    dpts  = (int)MathRound(MathAbs(g_liveEntry - price) / _Point);
      string dir   = g_liveBull ? "BUY" : "SELL";
      string st; color stc;
      if(pos > 0)                       { st = "FILLED";  stc = clrLime;   }
      else if(g_liveTested)             { st = "tested";  stc = clrOrange; }
      else if(HasOrderNear(g_liveEntry)){ st = "pending"; stc = clrAqua;   }  // an order on THIS level
      else                              { st = "waiting"; stc = clrSilver; }
      SetVal("Live", dir + " " + DoubleToString(g_liveEntry, _Digits) + "  " + IntegerToString(dpts) + "pts  " + st, stc);
     }

   // win-probability for the monitored setup: estimate vs the break-even it needs
   if(!g_liveValid)
      SetVal("Odds", "-", clrSilver);
   else
     {
      string grade = OddsGrade(g_liveEst, g_liveNeed);
      color  oc = (grade == "A") ? clrLime : (grade == "B") ? clrYellowGreen
                 : (grade == "C") ? clrGold : clrTomato;
      SetVal("Odds", StringFormat("win~%.0f%%  need %.0f%%  [%s]", g_liveEst, g_liveNeed, grade), oc);
     }

   string autoTxt; color autoCol;
   if(!InpAutoTrade)        { autoTxt = "OFF (scan only)";       autoCol = clrSilver; }
   else if(g_tradingHalted) { autoTxt = "STOPPED (Stop button)"; autoCol = clrOrange; }
   else
     {
      string br = TradeBlockReason();
      if(br == "")
        {
         // show the lot the NEXT trade would actually use (risk-% sized when on)
         double showLot = (InpRiskPercent > 0 && g_liveValid && g_liveSL > 0)
                          ? LotForTrade(g_liveEntry, g_liveSL) : InpLotSize;
         autoTxt = "ON " + (InpEntryMode == ENTRY_MARKET_NOW ? "market" : "limit")
                   + " lot " + DoubleToString(showLot, 2)
                   + (SpreadOK() ? "" : "  (spread>max)");
         autoCol = SpreadOK() ? clrLime : clrOrange;
        }
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
   if(!InpShowBacktest)
     {
      g_btWins = 0; g_btLosses = 0; g_btOpen = 0; g_btNoFill = 0; g_btTotalR = 0.0; g_btGrossWin = 0.0;
      return;
     }
   // This pass re-runs detection over the whole backtest window (30 days) --
   // too heavy for every M5 bar close. Refresh at most every 30 minutes; the
   // stats it feeds (dashboard + win-odds) don't need per-bar precision.
   if(g_btLastRun != 0 && TimeCurrent() - g_btLastRun < 1800)
      return;
   g_btLastRun = TimeCurrent();
   g_btWins = 0; g_btLosses = 0; g_btOpen = 0; g_btNoFill = 0; g_btTotalR = 0.0; g_btGrossWin = 0.0;
   ZeroMemory(g_ftWin); ZeroMemory(g_ftTot);

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

      // factor stats: which features the winners/losers actually had
      if(oc != 0)
        {
         bool f[NFEAT]; SetupFeatures(sx[i], f);
         for(int q = 0; q < NFEAT; q++)
           {
            int b = f[q] ? 1 : 0;
            g_ftTot[q][b]++;
            if(oc == 1) g_ftWin[q][b]++;
           }
        }
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
// Session window in broker/server time. start > end wraps overnight.
// Gates NEW entries only -- break-even and open-trade management run 24/5.
bool InSession()
  {
   if(!InpUseSessionFilter) return true;
   if(InpSessionStartHour == InpSessionEndHour) return true;    // degenerate = always on
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpSessionStartHour < InpSessionEndHour)
      return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   return (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
  }

// "" = clear to trade; otherwise the exact reason MT5 is blocking us.
string TradeBlockReason()
  {
   if(g_tradingHalted)                                          return "stopped (Stop button)";
   if(!InSession())                                             return "outside session hours";
   bool inTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!inTester && !TerminalInfoInteger(TERMINAL_CONNECTED))      return "no connection";
   if(!inTester && !(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "Algo button OFF (toolbar)";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))                        return "EA 'Allow Algo Trading' off";
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))          return "account trading off";
   ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED)                          return "symbol disabled";
   if(tm == SYMBOL_TRADE_MODE_CLOSEONLY)                         return "symbol close-only (mkt closed?)";
   if(!DailyLimitsOK())                                          return "daily limit hit";
   return "";
  }

bool TradingAllowed()
  {
   return InpAutoTrade && TradeBlockReason() == "";
  }

// Spread guard: skip entries when the spread is abnormally wide.
// Effective max spread in POINTS for THIS symbol. The ATR fraction adapts to
// the instrument (Gold/US30/USTEC); an optional fixed cap tightens it further.
// 0 = no cap in force.
int EffMaxSpreadPts()
  {
   int cap = 0;                                          // 0 = unlimited
   if(InpMaxSpreadATR > 0.0)
     {
      double atr = GetATR();
      if(atr > 0.0 && _Point > 0.0)
         cap = (int)MathRound(InpMaxSpreadATR * atr / _Point);
     }
   if(InpMaxSpreadPoints > 0)
      cap = (cap > 0) ? MathMin(cap, InpMaxSpreadPoints) : InpMaxSpreadPoints;
   return cap;
  }

bool SpreadOK()
  {
   int cap = EffMaxSpreadPts();
   if(cap <= 0) return true;
   return (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= cap;
  }

// Broker minimum distance for SL/TP/pending price (the bigger of stops & freeze level).
double BrokerStopDist()
  {
   double s = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)  * _Point;
   double f = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   return MathMax(s, f);
  }

// Are SL/TP far enough from a buy/sell at price `px` to be accepted?
bool StopsOK(bool isBuy, double px, double sl, double tp)
  {
   double d = BrokerStopDist();
   if(d <= 0) return true;
   if(isBuy)  return (px - sl >= d) && (tp - px >= d);
   return            (sl - px >= d) && (px - tp >= d);
  }

//----------------------------------------------------------------------
// Risk & management helpers
//----------------------------------------------------------------------
// Lot sized to risk InpRiskPercent of balance over the SL distance.
double LotForTrade(double entry, double sl)
  {
   if(InpRiskPercent <= 0) return InpLotSize;
   double slDist = MathAbs(entry - sl);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(slDist <= 0 || tickVal <= 0 || tickSz <= 0) return InpLotSize;

   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lossPerLot = (slDist / tickSz) * tickVal;          // loss for 1.0 lot if SL hit
   if(lossPerLot <= 0) return InpLotSize;
   double lot = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lot = MathFloor(lot / step) * step;
   lot = MathMax(minL, MathMin(maxL, lot));
   return lot;
  }

datetime DayStart()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

// Refresh today's realized P/L and trade count (cached for cheap gating).
void RefreshDailyStats()
  {
   g_dayPL = 0.0; g_dayTrades = 0;
   if(!HistorySelect(DayStart(), TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN) g_dayTrades++;
      if(entry == DEAL_ENTRY_OUT)
         g_dayPL += HistoryDealGetDouble(tk, DEAL_PROFIT)
                  + HistoryDealGetDouble(tk, DEAL_SWAP)
                  + HistoryDealGetDouble(tk, DEAL_COMMISSION);
     }
  }

// Effective daily loss limit in account currency (USD input overrides the %).
// 0 = no loss limit in force.
double DailyLossLimit()
  {
   if(InpDailyLossLimitUSD > 0) return InpDailyLossLimitUSD;
   if(InpDailyLossLimitPct > 0) return AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLossLimitPct / 100.0;
   return 0.0;
  }

// Are we still under the daily caps? The loss limit counts realized P/L plus
// any FLOATING LOSS on this EA's open trades (floating profit is ignored, so
// an open winner can't unlock extra risk before it's banked).
bool DailyLimitsOK()
  {
   if(InpMaxTradesPerDay > 0 && g_dayTrades >= InpMaxTradesPerDay) return false;
   double lim = DailyLossLimit();
   if(lim > 0)
     {
      double floating = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetTicket(i) == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      if(g_dayPL + MathMin(floating, 0.0) <= -lim) return false;
     }
   return true;
  }

// Break-even: move SL to entry (+buffer) once a position reaches the trigger R.
void ApplyBreakEven()
  {
   if(!InpBreakEven) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf = InpBEBufferPoints * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      bool atBE = isBuy ? (sl >= entry - _Point) : (sl <= entry + _Point);
      if(atBE) continue;                                  // already moved to BE/better
      double R = MathAbs(entry - sl);
      if(R <= 0) continue;
      double prof = isBuy ? (bid - entry) : (entry - ask);
      if(prof < R * g_beTriggerR) continue;              // not far enough in profit yet

      double newSL = isBuy ? entry + buf : entry - buf;
      g_trade.PositionModify(tk, NormalizeDouble(newSL, _Digits), tp);
     }
  }

// Cancel pending orders whose direction opposes the CURRENT HTF bias, so the
// resting book stays trend-aligned and stale counter-trend orders free up slots.
void CancelCounterBias()
  {
   if(!g_cancelCounterBias || !g_useHTFBias) return;
   if(g_htfUp == g_htfDown) return;                       // neutral -> leave orders alone
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuy = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP);
      if(g_htfDown && isBuy)  g_trade.OrderDelete(tk);     // bear bias -> drop resting buys
      if(g_htfUp   && !isBuy) g_trade.OrderDelete(tk);     // bull bias -> drop resting sells
     }
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

// Market-on-RETEST: every tick, if the monitored setup's entry edge is being
// touched right now, fire a MARKET order. Same trigger as the limit (the
// retest of the zone) -- just executed at market instead of a resting limit.
void TryMarketEntry()
  {
   if(InpEntryMode != ENTRY_MARKET_NOW) return;
   if(!TradingAllowed())                 return;
   if(!g_liveWaiting)                     return;                 // no setup waiting to be retested
   if(g_liveTime <= g_lastMktBreakTime)   return;                 // already entered this one
   if(g_liveBull  && !InpTradeBuys)       return;
   if(!g_liveBull && !InpTradeSells)      return;
   if(CountMyOrders() >= InpMaxPositions) return;
   if(!SpreadOK())                        return;     // spread too wide -> don't market in

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(g_liveSL, _Digits);
   double tp  = NormalizeDouble(g_liveTP, _Digits);

   bool touched = g_liveBull ? (ask <= g_liveEntry)   // price dropped into support edge
                             : (bid >= g_liveEntry);   // price rallied into resistance edge
   if(!touched) return;

   double fill = g_liveBull ? ask : bid;
   if(!StopsOK(g_liveBull, fill, sl, tp)) return;     // SL/TP too close for the broker -> skip

   double lot = g_liveBull ? LotForTrade(ask, sl) : LotForTrade(bid, sl);
   bool ok = g_liveBull ? g_trade.Buy (lot, _Symbol, ask, sl, tp, "IFVG buy mkt")
                        : g_trade.Sell(lot, _Symbol, bid, sl, tp, "IFVG sell mkt");
   if(ok) g_lastMktBreakTime = g_liveTime;            // enter each setup once
  }

void ManageTrades(const IFVGSetup &setups[], int n)
  {
   if(!TradingAllowed()) return;
   if(InpEntryMode != ENTRY_LIMIT_RETEST) return;     // market mode is handled per-tick in TryMarketEntry

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = 0.5 * (ask + bid);
   double atr = GetATR();
   double maxDist = (InpMaxEntryDistATR > 0 && atr > 0) ? InpMaxEntryDistATR * atr : DBL_MAX;

   // Cancel our pending limits that have drifted TOO FAR from price -- they only
   // hog the InpMaxPositions slots and block nearer, actionable setups.
   for(int oi = OrdersTotal() - 1; oi >= 0; oi--)
     {
      ulong tk = OrderGetTicket(oi);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - mid) > maxDist)
         g_trade.OrderDelete(tk);
     }

   // ---------- LIMIT mode: rest a pending limit at the entry edge ----------
   for(int i = 0; i < n; i++)
     {
      if(CountMyOrders() >= InpMaxPositions) break;
      if(setups[i].tested) continue;                       // already retested -> opportunity gone, never re-trade a tested zone
      if(setups[i].bullish  && !InpTradeBuys)  continue;
      if(!setups[i].bullish && !InpTradeSells) continue;

      double entry = NormalizeDouble(setups[i].entry, _Digits);
      double sl    = NormalizeDouble(setups[i].sl,    _Digits);
      double tp    = NormalizeDouble(setups[i].tp,    _Digits);

      if(MathAbs(entry - mid) > maxDist) continue;          // too far away -> don't rest a limit yet
      if(!SpreadOK()) break;                                // spread too wide right now -> skip this pass
      // A limit only makes sense on the correct side of current price.
      if(setups[i].bullish) { if(entry >= ask) continue; }  // BUY LIMIT must sit below the ask
      else                  { if(entry <= bid) continue; }  // SELL LIMIT must sit above the bid
      // Broker min-distance: pending must sit far enough from market, SL/TP far enough from entry.
      double sLvl = BrokerStopDist();
      if(setups[i].bullish) { if(ask - entry < sLvl) continue; }
      else                  { if(entry - bid < sLvl) continue; }
      if(!StopsOK(setups[i].bullish, entry, sl, tp)) continue;
      if(HasOrderNear(entry)) continue;                     // already have one on this zone

      ENUM_ORDER_TYPE_TIME tt = (InpPendingExpiryHrs > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      datetime exp = (InpPendingExpiryHrs > 0) ? TimeCurrent() + (datetime)(InpPendingExpiryHrs * 3600.0) : 0;

      double lot = LotForTrade(entry, sl);
      if(setups[i].bullish)
         g_trade.BuyLimit(lot, entry, _Symbol, sl, tp, tt, exp, "IFVG buy");
      else
         g_trade.SellLimit(lot, entry, _Symbol, sl, tp, tt, exp, "IFVG sell");
     }
  }

//+------------------------------------------------------------------+
//| Adaptive TP: re-point the take-profit at the CURRENT next draw on |
//| liquidity as new swings form -- for our pending limits AND open   |
//| positions. SL is left untouched. Only modifies when the target    |
//| actually moved and stays on the correct side of the entry.        |
//+------------------------------------------------------------------+
void AdaptTPs(const MqlRates &r[], int total)
  {
   if(!g_adaptTP) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;     // can't modify if trading isn't permitted

   // pending limit orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool   isBuy = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP);
      double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl    = OrderGetDouble(ORDER_SL);
      double curTP = OrderGetDouble(ORDER_TP);
      double tp;
      if(!FindLiquidityTarget(r, total, isBuy, entry, tp)) continue;
      tp = NormalizeDouble(tp, _Digits);
      if(MathAbs(tp - curTP) <= _Point) continue;     // unchanged
      if((isBuy && tp <= entry) || (!isBuy && tp >= entry)) continue;  // wrong side -> skip
      g_trade.OrderModify(tk, entry, sl, tp,
                          (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                          (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
     }

   // open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double tp;
      if(!FindLiquidityTarget(r, total, isBuy, entry, tp)) continue;
      tp = NormalizeDouble(tp, _Digits);
      if(MathAbs(tp - curTP) <= _Point) continue;
      if((isBuy && tp <= entry) || (!isBuy && tp >= entry)) continue;
      g_trade.PositionModify(tk, sl, tp);
     }
  }

//+------------------------------------------------------------------+
//| One full scan + redraw.                                           |
//+------------------------------------------------------------------+
void Scan()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);                  // index 0 = newest
   // Live scan window only (InpLookbackHours). The on-chart backtest covers its
   // own longer window inside RunBacktest -- keeping them decoupled means this
   // per-bar pass stays fast on low timeframes (M5).
   int want  = HoursToBars(InpLookbackHours);
   int total = CopyRates(_Symbol, _Period, 1, want, r);   // from 1 = closed bars only
   if(total < 2 * InpSwingBars + 10)
      return;

   EnsureHTFData();      // refresh HTF cache before any bias lookups
   ComputeHTFBias();
   RefreshDailyStats();  // daily P/L & trade-count for the circuit-breakers

   // Drawing is purely cosmetic -- skip it all when InpShowDrawings is off
   // (fast backtests). Detection and trading still run below.
   if(InpShowDrawings)
     {
      ObjectsDeleteAll(0, PFX + "S");      // wipe last pass (setups + structure + liquidity)
      ObjectsDeleteAll(0, PFX + "MS_");
      ObjectsDeleteAll(0, PFX + "LQ_");
      ObjectsDeleteAll(0, PFX + "G");      // ghost (rejected) zones
      DrawLiquidity(r, total);
      DrawStructure(total);
     }

   IFVGSetup setups[];
   int n = FindIFVGs(r, total, setups, InpMaxSetups, true);   // diag=true -> record reject reasons + ghosts
   g_lastBull = 0; g_lastBear = 0;
   for(int i = 0; i < n; i++)
     {
      if(InpShowDrawings) DrawSetup(setups[i], i);
      if(setups[i].bullish) g_lastBull++; else g_lastBear++;
     }
   // Ghost (rejected) zones are disabled -- they cluttered the chart. The wipe
   // above still clears any left over from a previous version.

   // The MONITORED setup = the freshest one still WAITING to trigger (untested
   // and with its entry still ahead on the correct side). It adapts: when a
   // newer waiting setup forms, it becomes the one we watch. Falls back to the
   // freshest setup so the line isn't blank.
   g_liveValid = false; g_liveWaiting = false;
   double bidP = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double askP = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < n; i++)
     {
      if(setups[i].tested) continue;                       // a tested zone is spent -> not monitored for entry
      bool ahead = setups[i].bullish ? (setups[i].entry < askP) : (setups[i].entry > bidP);
      if(!ahead) continue;
      g_liveValid = true; g_liveWaiting = true;
      g_liveBull = setups[i].bullish; g_liveEntry = setups[i].entry;
      g_liveTested = false; g_liveTime = setups[i].breakTime;
      g_liveSL = setups[i].sl; g_liveTP = setups[i].tp;
      SetupOdds(setups[i], g_liveEst, g_liveNeed);
      break;
     }
   if(!g_liveValid && n > 0)
     {
      g_liveValid = true; g_liveBull = setups[0].bullish; g_liveEntry = setups[0].entry;
      g_liveTested = setups[0].tested; g_liveTime = setups[0].breakTime;
      g_liveSL = setups[0].sl; g_liveTP = setups[0].tp;
      SetupOdds(setups[0], g_liveEst, g_liveNeed);
     }

   // Draw the WATCHING level so the monitored point is visible across the chart.
   ObjectDelete(0, PFX + "S_watch");
   ObjectDelete(0, PFX + "S_watchT");
   if(g_liveWaiting && InpShowDrawings)
     {
      ObjectCreate(0, PFX + "S_watch", OBJ_TREND, 0, g_liveTime, g_liveEntry, r[0].time, g_liveEntry);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_STYLE, STYLE_DASHDOT);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_BACK, false);
      ObjectSetInteger(0, PFX + "S_watch", OBJPROP_SELECTABLE, false);
      TextAt(PFX + "S_watchT", r[0].time, g_liveEntry,
             (g_liveBull ? "WATCHING BUY " : "WATCHING SELL ") + DoubleToString(g_liveEntry, _Digits) + " ",
             clrYellow, ANCHOR_RIGHT_LOWER);
     }

   // Session close: pull unfilled limits so nothing fills overnight.
   if(InpAutoTrade && InpUseSessionFilter && InpSessionCancelPend && !InSession())
      CancelMyPendings();

   CancelCounterBias();
   ManageTrades(setups, n);
   AdaptTPs(r, total);
   RunBacktest();
   Dashboard();
  }
//+------------------------------------------------------------------+
