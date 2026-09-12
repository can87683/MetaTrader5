//+------------------------------------------------------------------+
//|   ai_game_trade_adaptive.mq5
//|   AI Game Theory Trading System
//|   Auto Broker Discovery
//+------------------------------------------------------------------+
#property copyright "AI Game Theory Trading System"
#property link      ""
#property version   "3.00"
#property description "Nash Equilibrium + MFG signals + Auto Broker Detection"
#property description "Works on ANY broker - No configuration needed"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Groups (ALL ORIGINAL + NEW)                                |
//+------------------------------------------------------------------+

input group "=== Core Settings ==="
input string  ExpertName          = "AI Game Theory Trader";
input int     MagicNumber         = 2024;
input int     Slippage            = 10;

input group "=== Game Theory Signal ==="
input int     NashPeriod              = 100;   // Lookback bars for Nash equilibrium
input double  NashDeviationMultiplier = 0.02;  // Nash band width (stddev multiplier)
input double  MinConfidenceEntry      = 0.65;  // Minimum confidence score to enter [0–1]
input bool    ValidateNashZone        = true;  // Block trades inside Nash equilibrium zone
input int     MinBarsBetweenTrades    = 3;     // Bars to wait after last trade
input bool    CloseOppositeOnSignal   = true;  // Close opposing positions on direction flip

input group "=== Risk Management ==="
input bool    UseAutoLot          = true;      // Auto lot sizing from risk %
input double  RiskPercent         = 1.0;       // % of balance risked per trade
input double  FixedLotSize        = 1;       // Used when UseAutoLot = false
input int     MaxOpenTrades       = 5;         // Maximum simultaneous open positions

input group "=== Stop Loss ==="
input bool    UsePercentSL        = true;     // true = % of price, false = ATR-based
input double  StopLossPercent     = 1.5;       // SL as % of entry price
input double  ATRMultiplierSL     = 1.5;       // SL = ATR × this multiplier
input double  StopLossPoints      = 200;       // SL in points (fallback if ATR = 0)

input group "=== Take Profit ==="
input bool    UsePercentTP        = false;     // true = % of price, false = ATR-based
input double  TakeProfitPercent   = 0;        // TP as % of entry price
input double  ATRMultiplierTP     = 3.0;       // TP = ATR × this (1:2 RR default)
input double  TakeProfitPoints    = 400;      // TP in points (fallback if ATR = 0)

input group "=== Trailing Stop ==="
input bool    UseTrailingStop     = true;      // Enable trailing stop
input bool    TrailByATR          = true;      // true = ATR-based trail, false = fixed pts
input double  ATRMultiplierTrail  = 1.0;       // Trail distance = ATR × this
input double  TrailingStopPoints  = 1000;      // Fixed trailing distance in points
input double  TrailActivatePct    = 5.0;       // Activate trail after X% profit

input group "=== Trade Limits ==="
input int     MaxTradesPerDay     = 5;         // 0 = unlimited
input int     MaxTradesPerWeek    = 20;        // 0 = unlimited
input bool    NoTradeOnFriday     = true;      // Block all trades on Friday
input bool    EndOfDayClose       = true;      // Close profitable trades at EOD
input int     EndOfDayHour        = 23;        // Hour to trigger EOD close

input group "=== Debug ==="
input bool    VerboseLog          = true;      // Detailed per-bar logging
input int     LogEveryNTicks      = 100;       // Status report interval

input group "=== Broker Adaptation (NEW - Auto Discovery) ==="
input bool    EnableAutoDiscovery = true;      // Auto-detect broker capabilities
input bool    ShowDiscoveryDetails = true;     // Show discovery process

//+------------------------------------------------------------------+
//| Broker Profile Structure (NEW)                                   |
//+------------------------------------------------------------------+
struct SBrokerProfile
{
   int            exec_mode;              // Detected execution mode
   int            filling_mode;           // Detected working filling mode
   bool           supports_market;        // Market execution available
   bool           supports_instant;       // Instant execution available
   bool           requires_price;         // Price required for orders
   double         min_stop_distance_pts;  // Minimum stop loss in points
   double         min_tp_distance_pts;    // Minimum take profit in points
   double         min_lot;
   double         max_lot;
   double         lot_step;
   int            max_retries;
   int            retry_delay_ms;
   int            working_filling_modes[5];
   bool           discovered;
   datetime       discovery_time;
};

//+------------------------------------------------------------------+
//| Globals (ORIGINAL + PROFILE)                                     |
//+------------------------------------------------------------------+
CTrade          trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime        g_lastBarTime   = 0;
int             g_lastTradeBar  = -100;
int             g_tickCounter   = 0;
int             g_totalTrades   = 0;

int             g_todayTrades   = 0;
int             g_weekTrades    = 0;
datetime        g_lastResetDay  = 0;
datetime        g_lastResetWeek = 0;

int             g_hRSI  = INVALID_HANDLE;
int             g_hATR  = INVALID_HANDLE;

// NEW: Broker profile
SBrokerProfile  g_brokerProfile;
bool            g_discoveryComplete = false;

//+------------------------------------------------------------------+
//| Helper constants (NEW)                                           |
//+------------------------------------------------------------------+
#define SYMBOL_FILLING_RETURN_INT   2

//+------------------------------------------------------------------+
//| BROKER DISCOVERY ENGINE (NEW)                                    |
//+------------------------------------------------------------------+
class CBrokerDiscovery
{
private:
   string m_symbol;
   bool   m_verbose;
   
   bool TestOrderParameters(int fill_mode, double price, double volume, double sl, double tp, uint &retcode)
   {
      CTrade testTrade;
      testTrade.SetExpertMagicNumber(MagicNumber);
      testTrade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)fill_mode);
      testTrade.SetDeviationInPoints(100);
      
      bool result = testTrade.Buy(volume, m_symbol, price, sl, tp, "DISCOVERY_TEST");
      retcode = testTrade.ResultRetcode();
      
      return (retcode == TRADE_RETCODE_DONE || 
              retcode == TRADE_RETCODE_REQUOTE);
   }
   
public:
   void CBrokerDiscovery(string symbol, bool verbose = true)
   {
      m_symbol = symbol;
      m_verbose = verbose;
   }
   
   bool Discover(SBrokerProfile &profile)
   {
      if(!EnableAutoDiscovery)
      {
         SetStandardProfile(profile);
         return true;
      }
      
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║ 🔧 AUTO-DISCOVERY: Learning broker capabilities                ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      
      ZeroMemory(profile);
      
      // Get basic symbol info
      profile.min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      profile.max_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      profile.lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(profile.min_lot <= 0) profile.min_lot = 0.01;
      if(profile.max_lot <= 0) profile.max_lot = 100;
      if(profile.lot_step <= 0) profile.lot_step = 0.01;
      
      // Detect execution mode
      long raw_exec = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_EXEMODE);
      profile.exec_mode = (int)raw_exec;
      profile.supports_market = (raw_exec == SYMBOL_TRADE_EXECUTION_MARKET);
      profile.supports_instant = (raw_exec == SYMBOL_TRADE_EXECUTION_INSTANT);
      
      // Test filling modes
      int test_fill_modes[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, SYMBOL_FILLING_RETURN_INT};
      double test_price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double test_volume = 0.001;
      int mode_count = 0;
      
      for(int i = 0; i < ArraySize(test_fill_modes); i++)
      {
         uint retcode;
         if(TestOrderParameters(test_fill_modes[i], test_price, test_volume, 0, 0, retcode))
         {
            profile.working_filling_modes[mode_count++] = test_fill_modes[i];
            if(m_verbose && ShowDiscoveryDetails)
               PrintFormat("[DISCOVERY] ✓ Filling mode %d works", test_fill_modes[i]);
         }
      }
      
      // Select best filling mode (FOK > IOC > RETURN)
      profile.filling_mode = ORDER_FILLING_IOC;
      for(int i = 0; i < mode_count; i++)
      {
         if(profile.working_filling_modes[i] == ORDER_FILLING_FOK)
         {
            profile.filling_mode = ORDER_FILLING_FOK;
            break;
         }
      }
      
      // Discover minimum stop distance (binary search)
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double current_price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double min_pts = 1;
      double max_pts = 5000;
      double found_pts = 100;
      
      for(int attempt = 0; attempt < 15; attempt++)
      {
         double test_pts = (min_pts + max_pts) / 2;
         double sl_price = current_price - (test_pts * point);
         double tp_price = current_price + (test_pts * point);
         
         sl_price = NormalizeDouble(sl_price, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
         tp_price = NormalizeDouble(tp_price, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
         
         uint retcode;
         if(TestOrderParameters(profile.filling_mode, current_price, 0.001, sl_price, tp_price, retcode))
         {
            max_pts = test_pts;
            found_pts = test_pts;
         }
         else
         {
            min_pts = test_pts;
         }
         
         if(max_pts - min_pts < 5) break;
      }
      
      profile.min_stop_distance_pts = MathMax(10, found_pts + 10);
      profile.min_tp_distance_pts = profile.min_stop_distance_pts;
      
      // Set other parameters
      profile.requires_price = !profile.supports_market;
      profile.max_retries = (profile.filling_mode == ORDER_FILLING_FOK) ? 5 : 3;
      profile.retry_delay_ms = (profile.filling_mode == ORDER_FILLING_FOK) ? 500 : 1000;
      
      profile.discovered = true;
      profile.discovery_time = TimeCurrent();
      
      PrintDiscoverySummary(profile);
      return true;
   }
   
private:
   void SetStandardProfile(SBrokerProfile &profile)
   {
      profile.discovered = true;
      profile.filling_mode = ORDER_FILLING_IOC;
      profile.supports_market = true;
      profile.min_stop_distance_pts = 100;
      profile.min_tp_distance_pts = 100;
      profile.max_retries = 3;
      profile.retry_delay_ms = 1000;
      profile.requires_price = false;
      profile.min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      if(profile.min_lot <= 0) profile.min_lot = 0.01;
      profile.max_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(profile.max_lot <= 0) profile.max_lot = 100;
      profile.lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(profile.lot_step <= 0) profile.lot_step = 0.01;
   }
   
   void PrintDiscoverySummary(SBrokerProfile &profile)
   {
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║ ✅ BROKER DISCOVERY COMPLETE                                    ║");
      Print("╠════════════════════════════════════════════════════════════════╣");
      PrintFormat("║ Execution:      %s", 
                  profile.supports_market ? "MARKET" : 
                  profile.supports_instant ? "INSTANT" : "REQUEST");
      PrintFormat("║ Filling Mode:   %s", 
                  profile.filling_mode == ORDER_FILLING_FOK ? "FOK" :
                  profile.filling_mode == ORDER_FILLING_IOC ? "IOC" : "RETURN");
      PrintFormat("║ Min Stop Dist:  %.0f points", profile.min_stop_distance_pts);
      PrintFormat("║ Requires Price: %s", profile.requires_price ? "YES" : "NO");
      PrintFormat("║ Retry Config:   %d attempts, %dms", profile.max_retries, profile.retry_delay_ms);
      Print("╚════════════════════════════════════════════════════════════════╝");
   }
};

//+------------------------------------------------------------------+
//| Get best filling mode (UPGRADED)                                 |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetBestFillingMode()
{
   if(g_discoveryComplete && g_brokerProfile.filling_mode > 0)
      return (ENUM_ORDER_TYPE_FILLING)g_brokerProfile.filling_mode;
   
   long fillFlags = SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   
   return ORDER_FILLING_IOC;
}

//+------------------------------------------------------------------+
//| Validate SL/TP against broker limits (NEW)                       |
//+------------------------------------------------------------------+
void ValidateStopLevels(int direction, double entry_price, double &sl, double &tp)
{
   if(!g_discoveryComplete) return;
   
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double minStopDist = g_brokerProfile.min_stop_distance_pts * point;
   
   if(sl != 0)
   {
      double slDistance = (direction == ORDER_TYPE_BUY) ? entry_price - sl : sl - entry_price;
      if(slDistance < minStopDist && slDistance > 0)
      {
         if(VerboseLog)
            PrintFormat("[ADAPTIVE] SL too close (%.1f pts < min %.1f pts), adjusting", 
                        slDistance/point, minStopDist/point);
         if(direction == ORDER_TYPE_BUY)
            sl = entry_price - minStopDist;
         else
            sl = entry_price + minStopDist;
      }
   }
   
   if(tp != 0)
   {
      double tpDistance = (direction == ORDER_TYPE_BUY) ? tp - entry_price : entry_price - tp;
      double minTPDist = g_brokerProfile.min_tp_distance_pts * point;
      if(tpDistance < minTPDist && tpDistance > 0)
      {
         if(VerboseLog)
            PrintFormat("[ADAPTIVE] TP too close (%.1f pts < min %.1f pts), adjusting", 
                        tpDistance/point, minTPDist/point);
         if(direction == ORDER_TYPE_BUY)
            tp = entry_price + minTPDist;
         else
            tp = entry_price - minTPDist;
      }
   }
}

//+------------------------------------------------------------------+
//| Open position with adaptive retry (UPGRADED)                     |
//+------------------------------------------------------------------+
bool OpenPosition(int direction, double lots, double sl, double tp, double confidence)
{
   double price = (direction == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   
   // Apply broker validation
   ValidateStopLevels(direction, price, sl, tp);
   
   string comment = StringFormat("GameTrade_%.2f", confidence);
   
   // Use discovered filling mode
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   trade.SetTypeFilling(fillMode);
   
   int maxRetries = g_discoveryComplete ? g_brokerProfile.max_retries : 3;
   int retryDelay = g_discoveryComplete ? g_brokerProfile.retry_delay_ms : 1000;
   
   for(int attempt = 1; attempt <= maxRetries; attempt++)
   {
      if(attempt > 1)
      {
         PrintFormat("[RETRY] Attempt %d/%d", attempt, maxRetries);
         Sleep(retryDelay);
         price = (direction == ORDER_TYPE_BUY)
                 ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                 : SymbolInfoDouble(g_symbol, SYMBOL_BID);
      }
      
      bool ok = false;
      
      if(direction == ORDER_TYPE_BUY)
      {
         if(g_brokerProfile.requires_price)
            ok = trade.Buy(lots, g_symbol, price, sl, tp, comment);
         else
            ok = trade.Buy(lots, g_symbol, 0, sl, tp, comment);
      }
      else
      {
         if(g_brokerProfile.requires_price)
            ok = trade.Sell(lots, g_symbol, price, sl, tp, comment);
         else
            ok = trade.Sell(lots, g_symbol, 0, sl, tp, comment);
      }
      
      if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         PrintFormat("[OPEN] %s lots=%.2f entry=%.5f SL=%.5f TP=%.5f ticket=%I64u",
                     direction == ORDER_TYPE_BUY ? "BUY" : "SELL",
                     lots, price, sl, tp, trade.ResultOrder());
         return true;
      }
      
      uint retcode = trade.ResultRetcode();
      if(VerboseLog && attempt == maxRetries)
         PrintFormat("[OPEN] FAILED %s error=%d (%s)", 
                     direction == ORDER_TYPE_BUY ? "BUY" : "SELL", 
                     retcode, trade.ResultRetcodeDescription());
      
      // Learn from failure
      if(retcode == TRADE_RETCODE_INVALID_STOPS && g_discoveryComplete)
      {
         Print("[ADAPTIVE] Stop distance rejected, increasing minimum");
         g_brokerProfile.min_stop_distance_pts *= 1.5;
         ValidateStopLevels(direction, price, sl, tp);
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Helpers (ORIGINAL)                                               |
//+------------------------------------------------------------------+
string DayName(int d)
{
   string n[] = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"};
   return (d >= 0 && d <= 6) ? n[d] : "Unknown";
}

int DayOfWeek()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_week;
}

//+------------------------------------------------------------------+
//| Daily / weekly counter reset (ORIGINAL)                          |
//+------------------------------------------------------------------+
void ResetDailyCounter()
{
   datetime now = TimeCurrent();
   MqlDateTime d; TimeToStruct(now, d);
   d.hour = 0; d.min = 0; d.sec = 0;
   datetime midnight = StructToTime(d);

   if(g_lastResetDay == 0) { g_lastResetDay = midnight; return; }
   if(midnight != g_lastResetDay)
   {
      if(VerboseLog)
         PrintFormat("[LIMIT] New day — daily trades reset (%d → 0)", g_todayTrades);
      g_todayTrades  = 0;
      g_lastResetDay = midnight;
   }
}

void ResetWeeklyCounter()
{
   datetime now = TimeCurrent();
   MqlDateTime d; TimeToStruct(now, d);
   int daysFromMon = (d.day_of_week + 6) % 7;
   d.day -= daysFromMon; d.hour = 0; d.min = 0; d.sec = 0;
   datetime weekStart = StructToTime(d);

   if(g_lastResetWeek == 0) { g_lastResetWeek = weekStart; return; }
   if(weekStart != g_lastResetWeek)
   {
      if(VerboseLog)
         PrintFormat("[LIMIT] New week — weekly trades reset (%d → 0)", g_weekTrades);
      g_weekTrades    = 0;
      g_lastResetWeek = weekStart;
   }
}

//+------------------------------------------------------------------+
//| Gate: all limit checks (ORIGINAL)                                |
//+------------------------------------------------------------------+
bool TradingAllowed()
{
   ResetDailyCounter();
   ResetWeeklyCounter();

   if(NoTradeOnFriday && DayOfWeek() == 5)
   {
      if(VerboseLog) Print("[LIMIT] Friday — no new trades");
      return false;
   }
   if(MaxTradesPerDay > 0 && g_todayTrades >= MaxTradesPerDay)
   {
      if(VerboseLog) PrintFormat("[LIMIT] Daily limit %d/%d", g_todayTrades, MaxTradesPerDay);
      return false;
   }
   if(MaxTradesPerWeek > 0 && g_weekTrades >= MaxTradesPerWeek)
   {
      if(VerboseLog) PrintFormat("[LIMIT] Weekly limit %d/%d", g_weekTrades, MaxTradesPerWeek);
      return false;
   }
   return true;
}

void RecordTrade()
{
   g_totalTrades++;
   g_todayTrades++;
   g_weekTrades++;
   if(VerboseLog)
      PrintFormat("[LIMIT] Trade recorded — Total:%d Today:%d/%d Week:%d/%d",
                  g_totalTrades, g_todayTrades, MaxTradesPerDay,
                  g_weekTrades, MaxTradesPerWeek);
}

//+------------------------------------------------------------------+
//| Count own positions (ORIGINAL)                                   |
//+------------------------------------------------------------------+
int CountPositions(int direction = 0)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(direction ==  0) count++;
      else if(direction ==  1 && ptype == POSITION_TYPE_BUY)  count++;
      else if(direction == -1 && ptype == POSITION_TYPE_SELL) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close own positions (ORIGINAL)                                   |
//+------------------------------------------------------------------+
void ClosePositions(int direction)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      bool isBuy  = (ptype == POSITION_TYPE_BUY);
      bool isSell = (ptype == POSITION_TYPE_SELL);
      if((direction ==  1 && isBuy) || (direction == -1 && isSell))
      {
         if(trade.PositionClose(ticket) && VerboseLog)
            PrintFormat("[CLOSE] Closed %s #%I64u", isBuy ? "BUY" : "SELL", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| SL / TP calculation (ORIGINAL)                                   |
//+------------------------------------------------------------------+
void CalcSLTP(int direction, double entryPrice, double atrVal,
              double &sl, double &tp)
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   double pt  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

   double slDist = 0;
   if(UsePercentSL)
      slDist = entryPrice * StopLossPercent / 100.0;
   else if(atrVal > 0)
      slDist = atrVal * ATRMultiplierSL;
   else
      slDist = StopLossPoints * pt;

   double tpDist = 0;
   if(UsePercentTP)
      tpDist = entryPrice * TakeProfitPercent / 100.0;
   else if(atrVal > 0)
      tpDist = atrVal * ATRMultiplierTP;
   else
      tpDist = TakeProfitPoints * pt;

   if(direction == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(entryPrice - slDist, digits);
      tp = NormalizeDouble(entryPrice + tpDist, digits);
   }
   else
   {
      sl = NormalizeDouble(entryPrice + slDist, digits);
      tp = NormalizeDouble(entryPrice - tpDist, digits);
   }
}

//+------------------------------------------------------------------+
//| Auto lot size (ORIGINAL)                                         |
//+------------------------------------------------------------------+
double CalcLotSize(double atrVal)
{
   if(!UseAutoLot) return FixedLotSize;

   double acctBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt    = acctBal * RiskPercent / 100.0;
   double pt         = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double tickVal    = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz     = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep    = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);

   double slDist = (atrVal > 0) ? atrVal * ATRMultiplierSL : StopLossPoints * pt;
   if(slDist <= 0) return minLot;

   double riskPerLot = (slDist / tickSz) * tickVal;
   if(riskPerLot <= 0) return minLot;

   double lots = riskAmt / riskPerLot;
   lots = MathRound(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| Mean & standard deviation (ORIGINAL)                             |
//+------------------------------------------------------------------+
void CalcMeanStdDev(double &data[], int period, double &mean, double &stddev)
{
   mean = 0; stddev = 0;
   if(period <= 0) return;
   for(int i = 0; i < period; i++) mean += data[i];
   mean /= period;
   for(int i = 0; i < period; i++) stddev += MathPow(data[i] - mean, 2);
   stddev = MathSqrt(stddev / period);
}

//+------------------------------------------------------------------+
//| MFG entry score (ORIGINAL)                                       |
//+------------------------------------------------------------------+
double CalcMFGScore(double &prices[], long &volumes[], double atr)
{
   int sz = ArraySize(prices) - 1;
   if(sz <= 1) return 0.5;

   double returns[];
   ArrayResize(returns, sz);
   for(int i = 0; i < sz; i++)
      returns[i] = (prices[i+1] != 0) ? (prices[i] - prices[i+1]) / prices[i+1] : 0;

   double retMean = 0, volatility = 0;
   CalcMeanStdDev(returns, sz, retMean, volatility);

   double volMom = (volumes[1] > 0) ? (double)volumes[0] / (double)volumes[1] : 1.0;

   double score = 0;
   score += 0.4 * (1.0 - volatility / (atr + 1e-10));
   score += 0.3 * MathMin(volMom, 2.0) / 2.0;
   score += 0.3 * (1.0 - MathAbs(returns[0]) / (atr + 1e-10));
   return MathMax(0.0, MathMin(1.0, score));
}

//+------------------------------------------------------------------+
//| Simulated TP probability (ORIGINAL)                              |
//+------------------------------------------------------------------+
double SimTPProbability(double &prices[], double rsi, double atr)
{
   int limit = MathMin(10, ArraySize(prices) - 1);
   if(limit <= 0) return 0.5;
   double rv = 0;
   for(int i = 0; i < limit; i++)
      rv += (prices[i+1] != 0) ? MathAbs(prices[i] - prices[i+1]) / prices[i+1] : 0;
   rv /= limit;

   double prob = 0.5;
   prob += 0.2 * (1.0 - rv / (atr + 1e-10));
   prob += 0.2 * (1.0 - MathAbs(rsi - 50.0) / 50.0);
   prob += 0.1 * (ArraySize(prices) > 5 && prices[0] > prices[5] ? 0.1 : -0.1);
   return MathMax(0.0, MathMin(1.0, prob));
}

//+------------------------------------------------------------------+
//| Simulated exit probability (ORIGINAL)                            |
//+------------------------------------------------------------------+
double SimExitProbability(double profitPct, double atr)
{
   double target = ATRMultiplierTP / 100.0;
   double dist   = target - profitPct;
   if(dist <= 0) return 1.0;
   double prob = 1.0 - (dist / (target + 1e-10));
   prob *= (1.0 - MathMin(atr / 0.01, 0.9));
   return MathMax(0.0, MathMin(1.0, prob));
}

//+------------------------------------------------------------------+
//| Trailing stop management (ORIGINAL)                              |
//+------------------------------------------------------------------+
void ManageTrailingStop(double atrVal)
{
   if(!UseTrailingStop) return;
   double pt      = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double trailDist = TrailByATR ? atrVal * ATRMultiplierTrail
                                 : TrailingStopPoints * pt;
   if(trailDist <= 0) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      long   ptype  = PositionGetInteger(POSITION_TYPE);

      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

      if(ptype == POSITION_TYPE_BUY)
      {
         if(openPx > 0 && (bid - openPx) / openPx < TrailActivatePct / 100.0) continue;
         double newSL = NormalizeDouble(bid - trailDist, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
         if(newSL > curSL + pt)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         if(openPx > 0 && (openPx - ask) / openPx < TrailActivatePct / 100.0) continue;
         double newSL = NormalizeDouble(ask + trailDist, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
         if(curSL == 0.0 || newSL < curSL - pt)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Manage open positions (ORIGINAL)                                 |
//+------------------------------------------------------------------+
void ManageOpenPositions(double atrVal)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   bool isEOD = (EndOfDayClose && dt.hour >= EndOfDayHour);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      long   ptype    = PositionGetInteger(POSITION_TYPE);
      double openPx   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPx    = PositionGetDouble(POSITION_PRICE_CURRENT);
      double profitPct = (openPx > 0)
                         ? ((ptype == POSITION_TYPE_BUY)
                            ? (curPx - openPx) / openPx
                            : (openPx - curPx) / openPx)
                         : 0;

      bool   exitNow    = false;
      string exitReason = "";

      double tpProb = SimExitProbability(profitPct, atrVal);
      if(tpProb < 0.3 && profitPct > 0)
      {
         exitNow    = true;
         exitReason = "MFG_OPTIMAL";
      }

      if(isEOD && profitPct > 0)
      {
         exitNow    = true;
         exitReason = "END_OF_DAY";
      }

      if(exitNow)
      {
         if(trade.PositionClose(ticket) && VerboseLog)
            PrintFormat("[EXIT] %s #%I64u reason=%s profit=%.2f%%",
                        ptype == POSITION_TYPE_BUY ? "BUY" : "SELL",
                        ticket, exitReason, profitPct * 100.0);
      }
   }
}

//+------------------------------------------------------------------+
//| Core signal + entry logic (ORIGINAL + adaptive validation)      |
//+------------------------------------------------------------------+
void CheckForEntry(double atrVal)
{
   if(!TradingAllowed()) return;
   if(CountPositions(0) >= MaxOpenTrades)
   {
      if(VerboseLog)
         PrintFormat("[LIMIT] MaxOpenTrades reached (%d/%d)", CountPositions(0), MaxOpenTrades);
      return;
   }

   if(MinBarsBetweenTrades > 0 && g_lastTradeBar > 0)
   {
      int barsSince = (int)Bars(g_symbol, g_tf) - g_lastTradeBar;
      if(barsSince < MinBarsBetweenTrades)
      {
         if(VerboseLog)
            PrintFormat("[FILTER] %d/%d bars since last trade", barsSince, MinBarsBetweenTrades);
         return;
      }
   }

   double prices[];
   ArraySetAsSeries(prices, true);
   if(CopyClose(g_symbol, g_tf, 0, NashPeriod + 50, prices) < NashPeriod + 50) return;

   long volumes[];
   ArraySetAsSeries(volumes, true);
   if(CopyTickVolume(g_symbol, g_tf, 0, NashPeriod + 50, volumes) < NashPeriod + 50) return;

   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(g_hRSI, 0, 0, 3, rsi) < 3) return;

   double mean = 0, stddev = 0;
   CalcMeanStdDev(prices, NashPeriod, mean, stddev);
   double nashEq    = mean;
   double bandWidth = (stddev > 0) ? stddev * NashDeviationMultiplier : 0;
   double lowerBand = nashEq - bandWidth;
   double upperBand = nashEq + bandWidth;
   bool   inNash    = (prices[0] >= lowerBand && prices[0] <= upperBand);
   double nashDev   = (stddev > 0) ? (prices[0] - nashEq) / stddev : 0;

   bool herd = ((rsi[0] > 70 || rsi[0] < 30) && volumes[0] > volumes[1] * 1.5);

   double mfgScore = CalcMFGScore(prices, volumes, atrVal);
   double tpProb = SimTPProbability(prices, rsi[0], atrVal);

   double conf = 0;
   conf += 0.25 * MathMax(0, 1.0 - MathAbs(nashDev) / 5.0);
   conf += 0.20 * mfgScore;
   conf += 0.25 * tpProb;
   conf += 0.15 * (1.0 - MathAbs(rsi[0] - 50.0) / 50.0);
   conf += 0.15 * (herd ? 0.5 : 1.0);
   if(ValidateNashZone && inNash) conf *= 0.5;

   if(VerboseLog)
      PrintFormat("[SIGNAL] conf=%.3f nash=%.3f mfg=%.3f tp=%.3f rsi=%.1f inNash=%s",
                  conf, nashDev, mfgScore, tpProb, rsi[0], inNash ? "Y" : "N");

   if(conf < MinConfidenceEntry || inNash) return;

   int direction = (prices[0] > nashEq) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(CloseOppositeOnSignal && CountPositions(-1 * (direction == ORDER_TYPE_BUY ? 1 : -1)) > 0)
      ClosePositions(direction == ORDER_TYPE_BUY ? -1 : 1);

   double entryPrice = (direction == ORDER_TYPE_BUY)
                       ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                       : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   CalcSLTP(direction, entryPrice, atrVal, sl, tp);

   // Apply adaptive validation
   ValidateStopLevels(direction, entryPrice, sl, tp);

   double lots = CalcLotSize(atrVal);

   Print("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║ [TRADE] %s  %s %s  conf=%.3f",
               direction == ORDER_TYPE_BUY ? "BUY ▲" : "SELL ▼",
               g_symbol, EnumToString(g_tf), conf);
   PrintFormat("║  Entry:%.5f  SL:%.5f  TP:%.5f  Lots:%.2f", entryPrice, sl, tp, lots);
   PrintFormat("║  Nash:%.3f  MFG:%.3f  TPprob:%.3f  ATR:%.5f",
               nashDev, mfgScore, tpProb, atrVal);
   if(g_discoveryComplete)
      PrintFormat("║  Adaptive: %s mode | MinStop:%.0f pts",
                  g_brokerProfile.filling_mode == ORDER_FILLING_FOK ? "FOK" : "IOC",
                  g_brokerProfile.min_stop_distance_pts);
   Print("╚════════════════════════════════════════════════════════════════╝");

   if(OpenPosition(direction, lots, sl, tp, conf))
   {
      RecordTrade();
      g_lastTradeBar = (int)Bars(g_symbol, g_tf);
      LogTradeDecision(TimeCurrent(), direction, entryPrice,
                       conf, nashDev, inNash, mfgScore, tpProb);
   }
}

//+------------------------------------------------------------------+
//| CSV trade log (ORIGINAL)                                         |
//+------------------------------------------------------------------+
void LogTradeDecision(datetime time, int direction, double price,
                      double confidence, double nashDev, bool inNash,
                      double mfgScore, double tpProb)
{
   MqlDateTime dt; TimeToStruct(time, dt);
   string file = StringFormat("ai_game_trades_%04d%02d.csv", dt.year, dt.mon);
   int h = FileOpen(file, FILE_WRITE|FILE_CSV|FILE_READ, ",");
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
      FileWrite(h, "Time","Direction","Price","Confidence",
                   "NashDeviation","InNashZone","MFGScore","TPProbability");
   FileWrite(h,
             TimeToString(time, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
             direction == ORDER_TYPE_BUY ? "BUY" : "SELL",
             DoubleToString(price, _Digits),
             DoubleToString(confidence, 4),
             DoubleToString(nashDev, 4),
             inNash ? "YES" : "NO",
             DoubleToString(mfgScore, 4),
             DoubleToString(tpProb, 4));
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Periodic status log (ORIGINAL + adaptive info)                   |
//+------------------------------------------------------------------+
void LogStatus()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl = AccountInfoDouble(ACCOUNT_PROFIT);
   Print("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║ AI GAME THEORY EA v3.0  |  %s (%s)",
               TimeToString(TimeCurrent()), DayName(DayOfWeek()));
   PrintFormat("║  Symbol: %s %s  |  Ticks: %d  |  Total trades: %d",
               g_symbol, EnumToString(g_tf), g_tickCounter, g_totalTrades);
   PrintFormat("║  Open: %d/%d  |  Today: %d/%d  |  Week: %d/%d",
               CountPositions(0), MaxOpenTrades,
               g_todayTrades, MaxTradesPerDay, g_weekTrades, MaxTradesPerWeek);
   PrintFormat("║  Balance: %.2f  |  Equity: %.2f  |  P&L: %.2f", bal, eq, pnl);
   if(g_discoveryComplete)
   {
      PrintFormat("║  Adaptive: %s mode | MinStop:%.0f pts",
                  g_brokerProfile.filling_mode == ORDER_FILLING_FOK ? "FOK" : "IOC",
                  g_brokerProfile.min_stop_distance_pts);
   }
   Print("╚════════════════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| OnInit (UPGRADED with broker discovery)                          |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║  AI GAME THEORY EA v3.0 — Auto Broker Discovery Enabled       ║");
   Print("╚════════════════════════════════════════════════════════════════╝");

   g_symbol = Symbol();
   g_tf     = Period();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);

   // Run broker discovery (NEW)
   CBrokerDiscovery discovery(g_symbol, ShowDiscoveryDetails);
   if(discovery.Discover(g_brokerProfile))
   {
      g_discoveryComplete = true;
      Print("[INIT] ✅ Broker auto-discovery complete");
   }
   else
   {
      Print("[INIT] ⚠️ Using conservative defaults");
   }

   // Create indicator handles
   g_hRSI = iRSI(g_symbol, g_tf, 14, PRICE_CLOSE);
   g_hATR = iATR(g_symbol, g_tf, 14);

   if(g_hRSI == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Print("[ERROR] Failed to create indicator handles");
      return INIT_FAILED;
   }

   ResetDailyCounter();
   ResetWeeklyCounter();

   PrintFormat("[INIT] %s %s  Magic=%d  Risk=%.1f%%  MaxOpen=%d",
               g_symbol, EnumToString(g_tf), MagicNumber,
               RiskPercent, MaxOpenTrades);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("[WARN] ⚠️ AUTO-TRADING IS DISABLED in terminal");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit (ORIGINAL)                                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   PrintFormat("[DEINIT] reason=%d  ticks=%d  trades=%d", reason, g_tickCounter, g_totalTrades);
}

//+------------------------------------------------------------------+
//| OnTick (ORIGINAL)                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   g_tickCounter++;

   double atrBuf[2];
   double atrVal = 0;
   if(CopyBuffer(g_hATR, 0, 0, 2, atrBuf) == 2)
      atrVal = atrBuf[1];

   ManageTrailingStop(atrVal);

   if(g_tickCounter % LogEveryNTicks == 1)
      LogStatus();

   datetime barTime = iTime(g_symbol, g_tf, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   if(VerboseLog)
      PrintFormat("──── [%s %s] NEW BAR %s (tick #%d) ────",
                  g_symbol, EnumToString(g_tf),
                  TimeToString(barTime, TIME_DATE|TIME_MINUTES), g_tickCounter);

   ManageOpenPositions(atrVal);
   CheckForEntry(atrVal);
}
//+------------------------------------------------------------------+