//+------------------------------------------------------------------+
//|                                   QuantumMathAI_V6_Guardian.mq5  |
//|          REFACTORED - RANGING-REGIME MEAN-REVERSION SYSTEM       |
//|     Core fix: block entries in strong trends (R2 >= 0.5) and      |
//|     replace rigid 1:4 RR with BE + 50% partial + running target.  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Project Quantum"
#property version   "6.02"
#property strict
#property description "Quantum Math AI V6 - Ranging Regime Mean Reversion (XAUUSD)"

#include <Trade\Trade.mqh>

//==================================================================
// 1. INPUT PARAMETERS
//==================================================================
input group "--- 1. Quantum Math Settings ---"
input int      LRC_Period        = 34;     // Linear Regression Lookback Period (N)
input double   Slope_Threshold   = 0.05;   // Min |slope| to accept a regression fit
input double   R2_Max            = 0.50;   // Max R-Squared -> BLOCK entries above (strong trend)
input double   BandMultiplier    = 2.0;    // Channel width in StdDev (sigma)

input group "--- 2. Risk Management ---"
input double   RiskPercent       = 0.5;    // Risk % per Trade of account balance (0 = Fixed Lot)
input double   FixedLot          = 0.0;    // Fixed Lot Size (0 = use Risk%)
input int      ATR_Period        = 14;     // ATR Period
input double   ATR_Multiplier_SL = 2.0;    // SL Distance = ATR * this
input double   PartialRR         = 2.0;    // Partial trigger: close % of volume at + this R
input double   PartialPct        = 50.0;   // Partial close size (percent of position volume)
input double   BERR               = 1.0;    // Break-even trigger: SL->entry at + this R
input double   TPRR               = 4.0;    // Remainder runner target: R:R for the open 50%
input int      MaxPositions      = 1;      // Max concurrent positions
input int      MaxHoldMinutes    = 480;    // Max hold time in minutes (0=off)

input group "--- 2b. Optional Trend Confluence (keep OFF for pure mean-reversion) ---"
input bool     UseTrendConfluence = false;  // Require 100-bar regression agreement (BUY: >0, SELL: <0)

input group "--- 3. Auto News Filter (ForexFactory) ---"
input bool     UseAutoNews       = true;   // Enable Auto-Calendar Fetching
input bool     IncludeMedium     = false;  // If true, pause on 'Medium' impact too
input int      PauseMinsBefore   = 30;     // Minutes to pause BEFORE news
input int      PauseMinsAfter    = 30;     // Minutes to pause AFTER news
input int      ServerTimeOffset  = 2;      // Broker Timezone Offset from UTC

input group "--- 4. Filters & Time ---"
input int      MaxSpreadPoints   = 150;    // Max Spread Allowed (points)
input int      StartHour         = 8;      // Trading Start Hour (Server Time)
input int      EndHour           = 22;     // Trading End Hour (Server Time, excludes Asian rollover)

input group "--- 5. System ---"
input int      MagicNumber       = 66666;  // Unique Magic Number

//==================================================================
// 2. GLOBAL STRUCTURES & VARIABLES
//==================================================================
CTrade trade;
int atrHandle;
datetime lastBarTime = 0;
datetime lastNewsFetchTime = 0;
bool   notEnoughMoney = false;
ulong  partialDoneTickets[];   // tickets that already fired their partial close

struct RegressionResult {
   double slope;
   double intercept;
   double rSquared;
   double stdDev;
   double lowerBand;       // 2-sigma lower channel evaluated at last closed bar (bar 1)
   double upperBand;       // 2-sigma upper channel evaluated at last closed bar (bar 1)
   double lowerBandPrev;   // lower channel at bar 2
   double upperBandPrev;   // upper channel at bar 2
};

struct NewsEvent {
   datetime time;
   string   title;
   string   impact;
   string   currency;
};

NewsEvent WeeklyNews[];
string ObjPrefix = "QMAI_V6_";

//==================================================================
// 3. INITIALIZATION
//==================================================================
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   long fillPolicy = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillPolicy & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillPolicy & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
   trade.SetDeviationInPoints(30);

   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   if(atrHandle == INVALID_HANDLE) {
      Print("Error: Failed to create ATR handle");
      return(INIT_FAILED);
   }

   if(UseAutoNews)
      Print("NOTE: If Auto-News is active, ensure 'Allow WebRequest' is enabled in Tools > Options > Expert Advisors and that https://nfs.faireconomy.media is whitelisted.");

   Print(">>> QuantumMathAI V6.02 REFACTORED INITIALIZED (XAUUSD, Ranging Regime)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, ObjPrefix);
   Comment("");
}

//==================================================================
// 4. MAIN TICK LOOP
//   - ENTRY evaluated ONLY on a new bar (closed-bar data -> no repaint)
//   - MENT management runs on every tick but only touches thresholds
//==================================================================
void OnTick() {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid <= 0 || tick.ask <= 0) return;      // reject bad/empty ticks

   RegressionResult math = CalculateRegression(LRC_Period);
   double currentATR = GetCurrentATR();

   DrawChannel(math);
   bool isNews = CheckNewsFilter();
   UpdateDashboard(math, currentATR, isNews);

   // Management (BE / partial / max-hold) - every tick, threshold-based
   ManagePositions();

   // --- ENTRY BLOCK - new bar only ---------------------------------
   if(!CheckTimeFilter()) return;
   if(!isNewBar()) return;
   if(CountMyPositions() >= MaxPositions) return;
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;
   if(isNews) return;

   // Closed-bar reference data (bar 2 and bar 1)
   double close2 = iClose(_Symbol, _Period, 2);
   double close1 = iClose(_Symbol, _Period, 1);
   if(close2 <= 0 || close1 <= 0) return;

   // Ranging-regime gate: block mean-reversion when R^2 >= R2_Max (strong linear trend)
   if(math.rSquared >= R2_Max) return;
   // Reject near-flat regressions
   if(MathAbs(math.slope) < Slope_Threshold) return;

   // Optional 100-bar confluence gate (agreement with medium-term trend)
   if(UseTrendConfluence) {
      RegressionResult tf = CalculateRegression(100);
      if(tf.slope <= 0) return;   // block BUY style entries into a confirmed downtrend
      if(tf.slope >= 0) return;   // block SELL style entries into a confirmed uptrend
   }

   // BUY: bar 2 closed BELOW lower band AND bar 1 closed ABOVE lower band (reversal back inside)
   if(close2 < math.lowerBandPrev && close1 > math.lowerBand) {
      OpenTrade(ORDER_TYPE_BUY, currentATR);
      return;
   }
   // SELL: bar 2 closed ABOVE upper band AND bar 1 closed BELOW upper band (reversal back inside)
   if(close2 > math.upperBandPrev && close1 < math.upperBand) {
      OpenTrade(ORDER_TYPE_SELL, currentATR);
   }
}

//==================================================================
// 5. MATH CORE - LINEAR REGRESSION (N=34, y=Close, x anchored at bar 1)
//   slope     = (N*SumXY - SumX*SumY) / (N*SumX2 - (SumX)^2)
//   intercept = (SumY - slope*SumX) / N
//   R^2       = (N*SumXY - SumX*SumY)^2 /
//               [(N*SumX2 - (SumX)^2) * (N*SumY2 - (SumY)^2)]
//   StdDev    = sqrt( (1/N) * Sum( (yi - (m*xi + b))^2 ) )
//   bands     = regression value at bar +/- BandMultiplier * StdDev
//==================================================================
RegressionResult CalculateRegression(int n) {
   RegressionResult res;
   ZeroMemory(res);

   double prices[];
   ArraySetAsSeries(prices, true);                    // prices[0] = bar 1 (last closed)
   if(CopyClose(_Symbol, _Period, 1, n, prices) < n) return res;

   double sumX=0, sumY=0, sumXY=0, sumX2=0, sumY2=0;
   for(int i=0; i<n; i++) {
      double x = -((double)i);                         // bar 1 -> x=0, bar 2 -> x=-1, ...
      double y = prices[i];                            // closes of bar1..barN
      sumX  += x;
      sumY  += y;
      sumXY += x*y;
      sumX2 += x*x;
      sumY2 += y*y;
   }

   double denom = n*sumX2 - sumX*sumX;
   if(denom == 0) return res;

   res.slope = (n*sumXY - sumX*sumY) / denom;
   res.intercept = (sumY - res.slope*sumX) / n;

   double numR = n*sumXY - sumX*sumY;
   double denR = (n*sumX2 - sumX*sumX) * (n*sumY2 - sumY*sumY);
   if(denR > 0) res.rSquared = (numR*numR) / denR;
   else         res.rSquared = 0;

   double sumSqDiff = 0;
   for(int i=0; i<n; i++) {
      double regVal = res.slope*(-((double)i)) + res.intercept;
      sumSqDiff += MathPow(prices[i] - regVal, 2);
   }
   res.stdDev = MathSqrt(sumSqDiff / n);

   double sigma = res.stdDev * BandMultiplier;
   res.lowerBand     = res.intercept          - sigma;   // bar 1 lower
   res.upperBand     = res.intercept          + sigma;   // bar 1 upper
   res.lowerBandPrev = res.intercept - res.slope - sigma; // bar 2 lower
   res.upperBandPrev = res.intercept - res.slope + sigma; // bar 2 upper

   return res;
}

//==================================================================
// 6. AUTO NEWS FILTER LOGIC (WEB REQUEST)
//==================================================================
bool CheckNewsFilter() {
   if(!UseAutoNews) return false;

   if(TimeCurrent() - lastNewsFetchTime > 14400) {
      FetchNewsData();
   }

   datetime now = TimeCurrent();
   for(int i=0; i<ArraySize(WeeklyNews); i++) {
      if(WeeklyNews[i].currency != "USD") continue;

      bool isHigh   = (StringFind(WeeklyNews[i].impact, "High") >= 0);
      bool isMedium = (StringFind(WeeklyNews[i].impact, "Medium") >= 0);

      if(!isHigh && (!IncludeMedium || !isMedium)) continue;

      long diff = (long)now - (long)WeeklyNews[i].time;
      if(diff >= -PauseMinsBefore*60 && diff <= PauseMinsAfter*60) {
         return true;
      }
   }
   return false;
}

void FetchNewsData() {
   string cookie=NULL, headers;
   char post[], result[];
   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";

   int res = WebRequest("GET", url, cookie, NULL, 500, post, 0, result, headers);
   lastNewsFetchTime = TimeCurrent();

   if(res == 200) {
      string json = CharArrayToString(result);
      ParseNewsJson(json);
      Print(">>> News Data Fetched Successfully. Total Events: ", ArraySize(WeeklyNews));
   } else {
      Print(">>> Error fetching news. Code: ", res, ". Check 'Allow WebRequest' in Options.");
   }
}

void ParseNewsJson(string json) {
   ArrayResize(WeeklyNews, 0);

   string objects[];
   StringSplit(json, '}', objects);

   for(int i=0; i<ArraySize(objects); i++) {
      string obj = objects[i];
      if(StringFind(obj, "\"country\":\"USD\"") < 0) continue;

      string impact = "";
      if(StringFind(obj, "\"impact\":\"High\"") >= 0) impact = "High";
      else if(StringFind(obj, "\"impact\":\"Medium\"") >= 0) impact = "Medium";

      if(impact == "") continue;

      int dateStart = StringFind(obj, "\"date\":\"");
      if(dateStart < 0) continue;

      string dateStr = StringSubstr(obj, dateStart + 8, 19);
      StringReplace(dateStr, "T", " ");

      datetime newsTime = StringToTime(dateStr);
      newsTime = newsTime + (ServerTimeOffset * 3600);

      int titleStart = StringFind(obj, "\"title\":\"");
      string title = "News";
      if(titleStart >= 0) {
         int titleEnd = StringFind(obj, "\"", titleStart + 9);
         title = StringSubstr(obj, titleStart + 9, titleEnd - (titleStart + 9));
      }

      int newIdx = ArrayResize(WeeklyNews, ArraySize(WeeklyNews) + 1);
      WeeklyNews[newIdx-1].time    = newsTime;
      WeeklyNews[newIdx-1].impact  = impact;
      WeeklyNews[newIdx-1].currency= "USD";
      WeeklyNews[newIdx-1].title   = title;
   }
}

//==================================================================
// 7. EXECUTION & LOT SIZING (RiskPercent = 0.5% of balance)
//==================================================================
void OpenTrade(ENUM_ORDER_TYPE type, double atr) {
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0) return;

   // --- Stop Loss: ATR(14) * ATR_Multiplier_SL, floored ---
   double slDist = atr * ATR_Multiplier_SL;
   if(slDist < 200 * _Point) slDist = 200 * _Point;
   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;

   // --- Target for the running 50% ---
   double tpDist = slDist * TPRR;
   double tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;

   // --- Lot sizing: RiskPercent% of account BALANCE at the SL distance ---
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = FixedLot;
   notEnoughMoney = false;

   if(RiskPercent > 0 && slDist > 0) {
      double onePointCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) /
                            (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point);
      double slPts     = slDist / _Point;
      double riskMoney = balance * RiskPercent / 100.0;
      if(onePointCost > 0) lot = riskMoney / (slPts * onePointCost) ;
   }

   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;

   if(RiskPercent > 0 && slDist > 0 && lot > 0) {
      double onePointCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) /
                            (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point);
      double riskCap = RiskPercent * 2.0;   // never more than 2x target risk %
      double minLotRiskPct = (min * (slDist / _Point) * onePointCost) / balance * 100.0;
      if(onePointCost > 0 && minLotRiskPct > riskCap)
         notEnoughMoney = true;            // even 0.01 lot is too big -> skip
   }

   lot = MathFloor(lot / step) * step;
   if(lot < min) lot = min;
   if(lot > max) lot = max;
   if(notEnoughMoney) lot = 0.0;
   if(notEnoughMoney) return;

   string comment = (type == ORDER_TYPE_BUY) ? "QMAI-V6 Buy" : "QMAI-V6 Sell";
   if(type == ORDER_TYPE_BUY) trade.Buy(lot, _Symbol, price, sl, tp, comment);
   else                       trade.Sell(lot, _Symbol, price, sl, tp, comment);
}

int CountMyPositions() {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      count++;
   }
   return count;
}

//==================================================================
// 7b. POSITION MANAGEMENT
//   - Break-even: once profit >= BERR x SL distance -> SL to entry
//   - Partial:    once profit >= PartialRR x SL distance -> close PartialPct%
//   - Remainder:  runs to the TP target
//   - Max hold:   close after MaxHoldMinutes
//==================================================================
bool IsPartialDone(ulong ticket) {
   for(int i=0; i<ArraySize(partialDoneTickets); i++)
      if(partialDoneTickets[i] == ticket) return true;
   return false;
}

void MarkPartialDone(ulong ticket) {
   if(!IsPartialDone(ticket)) {
      int sz = ArraySize(partialDoneTickets);
      ArrayResize(partialDoneTickets, sz + 1);
      partialDoneTickets[sz] = ticket;
   }
}

void ManagePositions() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(openPrice <= 0) continue;

      double currentPrice = (type == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(currentPrice <= 0) continue;

      double dist = MathAbs(currentPrice - openPrice);
      double slDist = MathAbs(openPrice - sl);
      if(slDist <= 0) slDist = dist + 200 * _Point;
      bool inProfit = (type == POSITION_TYPE_BUY) ? (currentPrice > openPrice)
                                                  : (currentPrice < openPrice);
      double profitR = inProfit ? (dist / slDist) : 0.0;

      // --- 0. Max hold time exit ---
      if(MaxHoldMinutes > 0 && (TimeCurrent() - openTime) > MaxHoldMinutes * 60) {
         trade.PositionClose(ticket);
         continue;
      }

      bool partialDone = IsPartialDone(ticket);

      // --- 1. Partial profit: close PartialPct% at +PartialRR ---
      if(!partialDone && profitR >= PartialRR && volume > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
         double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double min   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double closeVol = NormalizeDouble(volume * PartialPct / 100.0, 2);
         closeVol = MathFloor(closeVol / step) * step;
         double remainVol = NormalizeDouble(volume - closeVol, 2);

         if(closeVol >= min && remainVol >= min) {
            if(trade.PositionClosePartial(ticket, closeVol)) {
               MarkPartialDone(ticket);
               // Lock in the runner at break-even
               double beBuf = 10 * _Point;
               double newSl = (type == POSITION_TYPE_BUY) ? (openPrice - beBuf) : (openPrice + beBuf);
               if((type == POSITION_TYPE_BUY && (sl < newSl)) ||
                  (type == POSITION_TYPE_SELL && (sl > newSl || sl == 0)))
                  trade.PositionModify(ticket, newSl, tp);
               Print(">>> V6: Partial close 50% @ +", PartialRR, "R, runner SL -> BE");
            }
            continue;
         }
      }

      // --- 2. Break-even trigger at +BERR ---
      if(profitR >= BERR && profitR < PartialRR) {
         bool needBE = false;
         if(type == POSITION_TYPE_BUY && (sl < openPrice || sl == 0)) needBE = true;
         if(type == POSITION_TYPE_SELL && (sl > openPrice || sl == 0)) needBE = true;
         if(needBE) trade.PositionModify(ticket, openPrice, tp);
      }
   }
}

//==================================================================
// 8. UTILITIES & VISUALS
//==================================================================
void UpdateDashboard(RegressionResult &m, double atr, bool newsPause) {
   string text = "=== QUANTUM MATH V6.02 (RANGING REVERSION) ===\n";
   text += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   text += "----------------------------------------\n";
   text += "R-Squared: " + DoubleToString(m.rSquared, 4) + "\n";
   string regime = (m.rSquared >= R2_Max) ? "STRONG TREND (NO ENTRY)" : "RANGING (ENTRY OK)";
   text += "Regime: " + regime + "\n";
   text += "Slope: " + DoubleToString(m.slope, 5) + "\n";
   text += "Volatility (ATR): " + DoubleToString(atr / _Point, 0) + " pts\n";

   if(newsPause) text += "STATUS: PAUSED (NEWS DETECTED)\n";
   else if(!CheckTimeFilter()) text += "STATUS: SLEEPING (TIME FILTER)\n";
   else text += "STATUS: HUNTING...\n";

   text += "----------------------------------------\n";
   text += "Auto-News: " + (UseAutoNews ? "ON" : "OFF") + "\n";

   Comment(text);
}

void DrawChannel(RegressionResult &m) {
   DrawLine(ObjPrefix+"Center", m.intercept, clrGold, 2);
   DrawLine(ObjPrefix+"Upper", m.upperBand, clrRed, 1, STYLE_DOT);
   DrawLine(ObjPrefix+"Lower", m.lowerBand, clrLime, 1, STYLE_DOT);
   ChartRedraw();
}

void DrawLine(string name, double price, color col, int width, ENUM_LINE_STYLE style=STYLE_SOLID) {
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectMove(0, name, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
}

double GetCurrentATR() {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) < 1) return 0;
   return atr[0];
}

bool CheckTimeFilter() {
   datetime time = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(time, dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

bool isNewBar() {
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == 0) return false;
   if(lastBarTime != bt) {
      lastBarTime = bt;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+