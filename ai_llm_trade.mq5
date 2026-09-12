//+------------------------------------------------------------------+
//|                                              ai_llm_trader.mq5    |
//|              Expert Advisor — LAN LLM Signal Generator            |
//+------------------------------------------------------------------+
#property copyright "AI LLM Trader"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "--- LLM Server ---"
input string   InpLLM_BaseURL    = "http://127.0.0.1:12345"; // LLM base URL (OpenAI-style)
input string   InpLLM_Model      = "local";                  // Model name sent in payload
input int      InpLLM_Timeout    = 8000;                     // Request timeout (ms)

input group "--- Risk Management ---"
input double   InpSL_Percent     = 2.0;                      // Stop Loss (% from entry)
input double   InpTrail_Trigger  = 5.0;                      // Trailing trigger (% profit)
input double   InpTrail_Step     = 2.0;                      // Trailing step (% from price)

input group "--- Trade Settings ---"
input int      InpMagicNumber    = 202610;                   // Magic number
input int      InpSignalInterval = 60;                       // Seconds between signal checks
input double   InpLotSize        = 0.01;                     // Fixed lot size

//--- Globals
CTrade   trade;
datetime lastSignalTime = 0;
string   signalURL;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);

    signalURL = InpLLM_BaseURL + "/v1/chat/completions";

    Print("EA initialized. Endpoint: ", signalURL);
    Print("Ensure WebRequest is allowed for: ", InpLLM_BaseURL);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
    if(TimeCurrent() - lastSignalTime < InpSignalInterval)
        return;

    if(HasOpenPosition())
    {
        ManageTrailingStop();
        return;
    }

    string signal = GetLLMSignal();

    if(signal == "BUY")
    {
        ExecuteTrade(ORDER_TYPE_BUY);
        lastSignalTime = TimeCurrent();
    }
    else if(signal == "SELL")
    {
        ExecuteTrade(ORDER_TYPE_SELL);
        lastSignalTime = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
string GetLLMSignal()
{
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, 20, rates);

    if(copied < 20)
    {
        Print("Failed to copy rates. Error: ", GetLastError());
        return "NONE";
    }

    string prompt      = BuildPrompt(rates);
    string jsonPayload = BuildJSONPayload(prompt);

    char   postData[];
    char   resultData[];
    string resultHeaders;
    string headers = "Content-Type: application/json\r\n";

    StringToCharArray(jsonPayload, postData, 0, StringLen(jsonPayload));

    int res = WebRequest("POST", signalURL, headers, InpLLM_Timeout,
                         postData, resultData, resultHeaders);

    if(res == -1)
    {
        int err = GetLastError();
        Print("WebRequest failed. Error ", err, ": ", GetWebRequestError(err));
        return "NONE";
    }

    string response = CharArrayToString(resultData);
    Print("LLM raw response: ", response);

    return ParseSignalFromResponse(response);
}

//+------------------------------------------------------------------+
string BuildPrompt(const MqlRates &rates[])
{
    string prompt = StringFormat(
        "Analyze this market snapshot and reply with exactly one word: BUY, SELL, or NONE.\n"
        "Symbol: %s\nTimeframe: %s\nCurrent price: %.5f\n"
        "Last 5 candles (O,H,L,C):\n",
        _Symbol,
        EnumToString((ENUM_TIMEFRAMES)Period()),
        rates[0].close
    );

    for(int i = 0; i < 5; i++)
    {
        prompt += StringFormat("  %d: %.5f %.5f %.5f %.5f\n",
                               i, rates[i].open, rates[i].high,
                               rates[i].low, rates[i].close);
    }

    prompt += "Reply with only one word.";
    return prompt;
}

//+------------------------------------------------------------------+
string BuildJSONPayload(string prompt)
{
    StringReplace(prompt, "\\", "\\\\");
    StringReplace(prompt, "\"", "\\\"");
    StringReplace(prompt, "\n", "\\n");
    StringReplace(prompt, "\r", "\\r");
    StringReplace(prompt, "\t", "\\t");

    string json = StringFormat(
        "{"
        "\"model\":\"%s\","
        "\"messages\":["
        "{\"role\":\"system\",\"content\":\"You are a trading signal assistant. Reply with only BUY, SELL, or NONE.\"},"
        "{\"role\":\"user\",\"content\":\"%s\"}"
        "],"
        "\"temperature\":0.1,"
        "\"max_tokens\":8,"
        "\"stream\":false"
        "}",
        InpLLM_Model,
        prompt
    );

    return json;
}

//+------------------------------------------------------------------+
string ParseSignalFromResponse(string response)
{
    string upper = response;
    StringToUpper(upper);

    // Prefer the assistant "content" field to avoid false positives in metadata
    int contentPos = StringFind(upper, "\"CONTENT\":\"");
    if(contentPos >= 0)
    {
        string slice = StringSubstr(upper, contentPos, 200);
        if(StringFind(slice, "BUY")  >= 0) return "BUY";
        if(StringFind(slice, "SELL") >= 0) return "SELL";
    }

    // Fallback: scan whole body
    if(StringFind(upper, "BUY")  >= 0) return "BUY";
    if(StringFind(upper, "SELL") >= 0) return "SELL";

    return "NONE";
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
{
    double price, sl;
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    if(orderType == ORDER_TYPE_BUY)
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl    = NormalizeDouble(price * (1.0 - InpSL_Percent / 100.0), digits);
    }
    else
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl    = NormalizeDouble(price * (1.0 + InpSL_Percent / 100.0), digits);
    }

    price = NormalizeDouble(price, digits);

    double lot    = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                            MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpLotSize));

    bool ok = (orderType == ORDER_TYPE_BUY)
              ? trade.Buy (lot, _Symbol, price, sl, 0, "AI LLM Signal")
              : trade.Sell(lot, _Symbol, price, sl, 0, "AI LLM Signal");

    if(ok)
        Print("Trade executed: ", EnumToString(orderType),
              " @ ", price, " SL: ", sl);
    else
        Print("Trade failed. Retcode ", trade.ResultRetcode(),
              ": ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)         continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL  = PositionGetDouble(POSITION_SL);

        if(type == POSITION_TYPE_BUY)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profitPct = (bid - openPrice) / openPrice * 100.0;

            if(profitPct >= InpTrail_Trigger)
            {
                double newSL = NormalizeDouble(bid * (1.0 - InpTrail_Step / 100.0), digits);
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                        Print("Trailing SL (BUY) -> ", newSL);
                }
            }
        }
        else if(type == POSITION_TYPE_SELL)
        {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPct = (openPrice - ask) / openPrice * 100.0;

            if(profitPct >= InpTrail_Trigger)
            {
                double newSL = NormalizeDouble(ask * (1.0 + InpTrail_Step / 100.0), digits);
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                        Print("Trailing SL (SELL) -> ", newSL);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
string CharArrayToString(const char &array[])
{
    return CharArrayToString(array, 0, WHOLE_ARRAY, CP_UTF8);
}

//+------------------------------------------------------------------+
string GetWebRequestError(int code)
{
    switch(code)
    {
        case 4014: return "Function not allowed — add URL to WebRequest whitelist.";
        case 4060: return "Failed to connect to server.";
        case 5270: return "Invalid URL or connection timeout.";
        default:   return "Unknown error.";
    }
}
//+------------------------------------------------------------------+