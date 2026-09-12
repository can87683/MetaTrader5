//+------------------------------------------------------------------+
//|  ai_game_indicator.mq5
//|  AI Game Theory Trading System
//+------------------------------------------------------------------+
#property copyright "AI Game Theory Trading Indicator"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2

//--- Plot 1: Buy Signals (from model)
#property indicator_label1  "Model Buy Signals"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  3

//--- Plot 2: Sell Signals (from model)
#property indicator_label2  "Model Sell Signals"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  3

//--- Input parameters (visual only)
input string   ExpertName = "AI Game Theory Signal Display";
input int      MagicNumber = 2024;              // Match with EA
input int      ArrowOffset = 20;                 // Arrow offset in points
input bool     ShowConfidenceValues = true;      // Show confidence as text
input string   SignalFilePath = "ai_game_signals_"; // Signal file prefix
input int      MaxSignalsToShow = 1000;          // Maximum signals to display

//--- Indicator buffers
double buyBuffer[];
double sellBuffer[];

//--- Global variables
struct ModelSignal
{
   datetime     time;
   string       signal;        // "BUY" or "SELL"
   double       price;
   double       confidence;
   double       nashDeviation;
   bool         inNashZone;
   double       tpProbability;
   double       mfgScore;
   double       rsi;
   double       atr;
   long         volume;
   string       modelVersion;
};

ModelSignal signals[];
int signalCount;
string currentFile;
datetime lastFileCheck;
ENUM_TIMEFRAMES chartTimeframe;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set indicator buffers
   SetIndexBuffer(0, buyBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, sellBuffer, INDICATOR_DATA);

   // Set arrow codes (233 = up arrow, 234 = down arrow)
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);

   // Set arrow offsets
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, ArrowOffset);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, -ArrowOffset);

   // Set empty value
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0);

   // Set line labels
   PlotIndexSetString(0, PLOT_LABEL, "Model Buy Signal");
   PlotIndexSetString(1, PLOT_LABEL, "Model Sell Signal");

   // Initialize
   signalCount = 0;
   ArrayResize(signals, 0);
   lastFileCheck = 0;
   chartTimeframe = Period();

   // Find the most recent signal file
   FindLatestSignalFile();

   Print(ExpertName, " initialized on ", Symbol(), " ", EnumToString(chartTimeframe));
   Print("Reading signals from: ", currentFile);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up on-chart objects
   ObjectsDeleteAll(0, "ModelSignal_");
   Comment("");
   Print(ExpertName, " deinitialized. Total signals displayed: ", signalCount);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Check for new signal file every minute
   datetime currentTime = TimeCurrent();
   if(currentTime - lastFileCheck > 60)
   {
      lastFileCheck = currentTime;
      CheckForNewSignals();
   }

   // Update signal positions on chart
   UpdateSignalPositions(time, low, high);

   // Draw stats
   DrawStats();

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Find the latest signal file                                      |
//+------------------------------------------------------------------+
void FindLatestSignalFile()
{
   string searchPath = SignalFilePath + "*";
   string fileName;
   datetime latestTime = 0;
   long searchHandle = FileFindFirst(searchPath, fileName);

   if(searchHandle != INVALID_HANDLE)
   {
      do
      {
         // Extract date from filename (format: ai_game_signals_YYYYMM.csv)
         if(StringFind(fileName, ".csv") > 0)
         {
            string dateStr = StringSubstr(fileName, StringLen(SignalFilePath), 6);
            int year = (int)StringSubstr(dateStr, 0, 4);
            int month = (int)StringSubstr(dateStr, 4, 2);

            datetime fileTime = StructToTime(year, month, 1, 0, 0, 0);
            if(fileTime > latestTime)
            {
               latestTime = fileTime;
               currentFile = fileName;
            }
         }
      }
      while(FileFindNext(searchHandle, fileName));

      FileFindClose(searchHandle);
   }

   if(currentFile == "")
      currentFile = SignalFilePath + "current.csv";
}

//+------------------------------------------------------------------+
//| Check for new signals in file                                    |
//+------------------------------------------------------------------+
void CheckForNewSignals()
{
   int handle = FileOpen(currentFile, FILE_READ|FILE_CSV, ",");

   if(handle == INVALID_HANDLE)
   {
      // Try to find latest file again
      FindLatestSignalFile();
      handle = FileOpen(currentFile, FILE_READ|FILE_CSV, ",");

      if(handle == INVALID_HANDLE)
         return;
   }

   // Skip header
   FileReadString(handle);

   // Read all signals
   while(!FileIsEnding(handle))
   {
      ModelSignal newSignal;

      string timeStr = FileReadString(handle);
      newSignal.signal = FileReadString(handle);
      string priceStr = FileReadString(handle);
      string confStr = FileReadString(handle);
      string nashStr = FileReadString(handle);
      string inNashStr = FileReadString(handle);
      string tpStr = FileReadString(handle);
      string mfgStr = FileReadString(handle);
      string rsiStr = FileReadString(handle);
      string atrStr = FileReadString(handle);
      string volStr = FileReadString(handle);

      // Parse time (format: HH:MM)
      int hour = (int)StringSubstr(timeStr, 0, 2);
      int minute = (int)StringSubstr(timeStr, 3, 2);

      // Get today's date
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = hour;
      dt.min = minute;
      dt.sec = 0;
      newSignal.time = StructToTime(dt);

      // Parse values
      newSignal.price = StringToDouble(priceStr);
      newSignal.confidence = StringToDouble(confStr);
      newSignal.nashDeviation = StringToDouble(nashStr);
      newSignal.inNashZone = (inNashStr == "YES");
      newSignal.tpProbability = StringToDouble(tpStr);
      newSignal.mfgScore = StringToDouble(mfgStr);
      newSignal.rsi = StringToDouble(rsiStr);
      newSignal.atr = StringToDouble(atrStr);
      newSignal.volume = StringToInteger(volStr);
      newSignal.modelVersion = "1.0";

      // Add to array if not duplicate
      bool exists = false;
      for(int i = 0; i < signalCount; i++)
      {
         if(signals[i].time == newSignal.time &&
            signals[i].signal == newSignal.signal &&
            MathAbs(signals[i].price - newSignal.price) < 0.0001)
         {
            exists = true;
            break;
         }
      }

      if(!exists && signalCount < MaxSignalsToShow)
      {
         ArrayResize(signals, signalCount + 1);
         signals[signalCount] = newSignal;
         signalCount++;

         // Draw signal on chart immediately
         DrawSignal(newSignal);
      }
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Draw a single signal on chart                                    |
//+------------------------------------------------------------------+
void DrawSignal(ModelSignal &signal)
{
   string objName = "ModelSignal_" + IntegerToString(signal.time) + "_" + signal.signal;

   // Check if already exists
   if(ObjectFind(0, objName) >= 0)
      return;

   // Determine arrow position
   double arrowPrice;
   if(signal.signal == "BUY")
      arrowPrice = signal.price - ArrowOffset * Point();
   else
      arrowPrice = signal.price + ArrowOffset * Point();

   // Create arrow
   ObjectCreate(0, objName, OBJ_ARROW, 0, signal.time, arrowPrice);
   ObjectSetInteger(0, objName, OBJPROP_ARROWCODE, (signal.signal == "BUY") ? 233 : 234);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, (signal.signal == "BUY") ? clrLimeGreen : clrRed);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 10);

   // Add confidence label if enabled
   if(ShowConfidenceValues)
   {
      string labelObj = objName + "_label";
      string labelText = StringFormat("%s %.1f%%",
                         signal.signal,
                         signal.confidence * 100);

      ObjectCreate(0, labelObj, OBJ_TEXT, 0, signal.time,
                  arrowPrice + (signal.signal == "BUY" ? -ArrowOffset * Point() : ArrowOffset * Point()));
      ObjectSetString(0, labelObj, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelObj, OBJPROP_COLOR, (signal.signal == "BUY") ? clrLime : clrRed);
      ObjectSetInteger(0, labelObj, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, labelObj, OBJPROP_BACK, false);
      ObjectSetInteger(0, labelObj, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
//| Update signal positions on current chart                         |
//+------------------------------------------------------------------+
void UpdateSignalPositions(const datetime &time[], const double &low[], const double &high[])
{
   // This ensures signals stay aligned with price even after scrolling
   for(int i = 0; i < signalCount; i++)
   {
      string objName = "ModelSignal_" + IntegerToString(signals[i].time) + "_" + signals[i].signal;

      // Find corresponding bar index
      int barIndex = iBarShift(Symbol(), chartTimeframe, signals[i].time);

      if(barIndex >= 0)
      {
         // Update arrow position to current bar's price level
         double arrowPrice;
         if(signals[i].signal == "BUY")
            arrowPrice = low[barIndex] - ArrowOffset * Point();
         else
            arrowPrice = high[barIndex] + ArrowOffset * Point();

         ObjectSetDouble(0, objName, OBJPROP_PRICE, arrowPrice);
      }
   }
}

//+------------------------------------------------------------------+
//| Convert year, month, day to datetime                             |
//+------------------------------------------------------------------+
datetime StructToTime(int year, int month, int day, int hour, int minute, int second)
{
   MqlDateTime dt;
   dt.year = year;
   dt.mon = month;
   dt.day = day;
   dt.hour = hour;
   dt.min = minute;
   dt.sec = second;
   dt.day_of_week = 0;
   dt.day_of_year = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Draw statistics on chart                                         |
//+------------------------------------------------------------------+
void DrawStats()
{
   string stats = "=== AI MODEL SIGNALS ===\n";
   stats += "File: " + currentFile + "\n";
   stats += "Total Signals: " + IntegerToString(signalCount) + "\n";

   // Count buys and sells
   int buys = 0, sells = 0;
   double avgConfBuy = 0, avgConfSell = 0;

   for(int i = 0; i < signalCount; i++)
   {
      if(signals[i].signal == "BUY")
      {
         buys++;
         avgConfBuy += signals[i].confidence;
      }
      else
      {
         sells++;
         avgConfSell += signals[i].confidence;
      }
   }

   if(buys > 0) avgConfBuy /= buys;
   if(sells > 0) avgConfSell /= sells;

   stats += "\nBUY Signals: " + IntegerToString(buys);
   stats += " (avg conf: " + DoubleToString(avgConfBuy * 100, 1) + "%)\n";
   stats += "SELL Signals: " + IntegerToString(sells);
   stats += " (avg conf: " + DoubleToString(avgConfSell * 100, 1) + "%)\n";

   // Get most recent signals
   stats += "\n=== LAST 5 SIGNALS ===\n";
   int start = MathMax(0, signalCount - 5);
   for(int i = signalCount - 1; i >= start; i--)
   {
      string timeStr = TimeToString(signals[i].time);
      stats += StringFormat("%s %s @ %.5f (%.1f%%)\n",
                           timeStr,
                           signals[i].signal,
                           signals[i].price,
                           signals[i].confidence * 100);
   }

   // Add model performance if available
   stats += "\n=== MODEL METRICS ===\n";
   stats += "Nash Deviation: Current signals only\n";
   stats += "TP Probability: From model\n";
   stats += "MFG Score: From model\n";

   Comment(stats);
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // Toggle stats on 'S' key
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 'S' || lparam == 's')
      {
         static bool showStats = true;
         showStats = !showStats;
         if(!showStats)
            Comment("");
         ChartRedraw();
      }

      // Reload signals on 'R' key
      if(lparam == 'R' || lparam == 'r')
      {
         // Clear all existing signals
         ObjectsDeleteAll(0, "ModelSignal_");
         signalCount = 0;
         ArrayResize(signals, 0);

         // Reload from file
         CheckForNewSignals();
         ChartRedraw();
      }

      // Show signal details on mouse click
      if(id == CHARTEVENT_CLICK)
      {
         int x = (int)lparam;
         int y = (int)dparam;

         datetime clickTime;
         double clickPrice;
         ChartXYToTimePrice(0, x, y, 0, clickTime, clickPrice);

         // Find nearest signal
         int nearestIdx = -1;
         double nearestDist = DBL_MAX;

         for(int i = 0; i < signalCount; i++)
         {
            double timeDist = MathAbs(clickTime - signals[i].time);
            double priceDist = MathAbs(clickPrice - signals[i].price);

            if(timeDist < 3600 && priceDist < 100 * Point()) // Within 1 hour and 100 pips
            {
               double dist = timeDist + priceDist * 1000;
               if(dist < nearestDist)
               {
                  nearestDist = dist;
                  nearestIdx = i;
               }
            }
         }

         if(nearestIdx >= 0)
         {
            ShowSignalDetails(signals[nearestIdx]);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Show detailed signal information                                 |
//+------------------------------------------------------------------+
void ShowSignalDetails(ModelSignal &signal)
{
   string details = "=== SIGNAL DETAILS ===\n";
   details += "Time: " + TimeToString(signal.time) + "\n";
   details += "Signal: " + signal.signal + "\n";
   details += "Price: " + DoubleToString(signal.price, _Digits) + "\n";
   details += "\n=== MODEL OUTPUTS ===\n";
   details += "Confidence: " + DoubleToString(signal.confidence * 100, 2) + "%\n";
   details += "Nash Deviation: " + DoubleToString(signal.nashDeviation, 3) + "\n";
   details += "In Nash Zone: " + (signal.inNashZone ? "YES" : "NO") + "\n";
   details += "TP Probability: " + DoubleToString(signal.tpProbability * 100, 2) + "%\n";
   details += "MFG Score: " + DoubleToString(signal.mfgScore, 3) + "\n";
   details += "\n=== MARKET CONTEXT ===\n";
   details += "RSI: " + DoubleToString(signal.rsi, 2) + "\n";
   details += "ATR: " + DoubleToString(signal.atr, _Digits) + "\n";
   details += "Volume: " + IntegerToString(signal.volume) + "\n";
   details += "Model Version: " + signal.modelVersion + "\n";

   Comment(details);
}

//+------------------------------------------------------------------+
//| Time to string helper                                            |
//+------------------------------------------------------------------+
string TimeToString(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);
   return StringFormat("%02d:%02d", dt.hour, dt.min);
}

//+------------------------------------------------------------------+
//| Custom indicator end                                             |
//+------------------------------------------------------------------+