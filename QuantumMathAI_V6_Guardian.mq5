//+------------------------------------------------------------------+
//|                                   QuantumMathAI_V6_Guardian.mq5  |
//|               INSTITUTIONAL GRADE - LINEAR REGRESSION SYSTEM     |
//|                   UPDATED FOR GOLD $4000+ (NOV 2025)             |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Project Quantum"
#property version   "6.01" // Auto-News Integrated
#property strict
#property description "Quantum Math AI with Auto-News Filter (ForexFactory)"

#include <Trade\Trade.mqh>

//==================================================================
// 1. INPUT PARAMETERS
//==================================================================
input group "--- 1. Quantum Math Settings ---"
input int      LRC_Period        = 30;     // Linear Regression Lookback Period
input double   Slope_Threshold   = 0.06;   // Min Slope to confirm Trend
input double   R_Squared_Min     = 0.20;   // Min R-Squared (Trend Quality) [0.0-1.0]

input group "--- 2. Risk Management ---"
input double   RiskPercent       = 1.0;    // Risk % per Trade (0 = Use Fixed Lot)
input double   RiskStepPercent   = 0.0;    // Risk ramp: extra % per further consec-loss after trigger
input int      ConsecLossTrigger = 1;      // Risk ramp: start ramping after N consecutive losses
input double   LotStepPerLoss    = 0.0;   // Lot size add per consecutive loss (on top of risk lot)
input double   FixedLot          = 0.0;    // Fixed Lot Size (0 = use Risk%)
input int      ATR_Period        = 14;     // ATR Period
input double   ATR_Multiplier_SL = 1.0;    // SL Distance = ATR * this (1.0 x ATR ~ realistic room)
input int      SL_Mode           = 0;      // SL source: 0=ATR-based, 1=prev candle +gap, 2=fixed points
input int      SL_GapPoints      = 30;     // Extra buffer pts beyond prev candle (used when SL_Mode=1)
input int      SL_MinNaturalPts  = 100;    // Prev-candle SL < this = "sideways/tiny", fall back to fixed SL pts
input int      SL_FixedPoints    = 450;    // Fixed SL (pts) used when SL_Mode=2 (or sideways fallback in mode 1)
input double   ATR_Multiplier_TP = 3.0;    // TP Target = ATR * this (if UseFixedRR)
input bool     UseFixedRR        = true;   // Use fixed R:R instead of channel TP
input double   FixedRR           = 4.0;    // R:R ratio (if UseFixedRR=true)
input int      EarlyBEThreshold  = 0;      // Early BE: lock SL at open after N pts GENUINE profit (0 = off)
input int      TrendFilterPeriod = 100;    // Longer LRC window (bars) for medium-term trend alignment (0=off)
input int      CoolDownBars      = 0;      // Skip N bars re-entering SAME direction after a loss (0=off)
input int      MaxPositions      = 3;      // Max concurrent positions
input int      MaxHoldMinutes    = 480;    // Max hold time in minutes (0=off)

input group "--- 3. Auto News Filter (ForexFactory) ---"
input bool     UseAutoNews       = true;   // Enable Auto-Calendar Fetching
input bool     IncludeMedium     = false;  // If true, pause on 'Medium' impact too. False = 'High' only.
input int      PauseMinsBefore   = 30;     // Minutes to pause BEFORE news
input int      PauseMinsAfter    = 30;     // Minutes to pause AFTER news
input int      ServerTimeOffset  = 2;      // Your Broker Timezone Offset from UTC (e.g., UTC+2)

input group "--- 4. Filters & Time ---"
input int      MaxSpreadPoints   = 150;    // Max Spread Allowed (150 pts = $1.5)
input int      StartHour         = 8;      // Trading Start Hour (Server Time)
input int      EndHour           = 22;     // Trading End Hour (Server Time)

input group "--- 4b. Trailing Stop ---"
input bool     EnableTrailing    = false;  // Enable Trailing Stop
input int      TrailingStart     = 200;    // Trail activation: profit pts from open
input double   TrailingPercent   = 10.0;   // Trail distance = this % of profit from entry to price
input int      TrailStep         = 50;     // Trail step: only update SL on each X pts move

input group "--- 5. System ---"
input int      MagicNumber       = 66666;  // Unique Magic Number

//==================================================================
// 2. GLOBAL STRUCTURES & VARIABLES
//==================================================================
CTrade trade;
int atrHandle;
datetime lastBarTime = 0;
datetime lastNewsFetchTime = 0;
int    lastClosedDirection = 0;   // +1 = last magic trade was BUY, -1 = SELL, 0 = none
datetime lastClosedTime   = 0;
bool   lastClosedWasLoss  = false;
int    consecLosses       = 0;   // consecutive losing trades (same/any direction) since last win
MqlTick lastTick;
bool   notEnoughMoney     = false;

// Struct for Linear Regression Results
struct RegressionResult {
   double slope;
   double intercept;
   double rSquared;
   double stdDev;
   double centerLine;
   double upperChannel;
   double lowerChannel;
};

// Struct for News Events
struct NewsEvent {
   datetime time;
   string   title;
   string   impact;
   string   currency;
};

NewsEvent WeeklyNews[]; // Array to store fetched news

// Visual Objects Prefix
string ObjPrefix = "QMAI_V6_";

//==================================================================
// 3. INITIALIZATION
//==================================================================
int OnInit() {
   // Setup Trade Object
   trade.SetExpertMagicNumber(MagicNumber);
   long fillPolicy = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillPolicy & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillPolicy & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
   trade.SetDeviationInPoints(30);

   // Initialize ATR Indicator
   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   if(atrHandle == INVALID_HANDLE) {
      Print("Error: Failed to create ATR handle");
      return(INIT_FAILED);
   }
   
// Check Auto-News note (Informational only).
    // MQL5 has no API to query WebRequest permission directly, so we only remind
    // the user to verify 'Allow WebRequest' in terminal Options when Auto-News is on.
    if(UseAutoNews) {
       Print("NOTE: If Auto-News is active, ensure 'Allow WebRequest' is enabled in Tools > Options > Expert Advisors and that https://nfs.faireconomy.media is whitelisted.");
    }

   Print(">>> QuantumMathAI V6.0 INITIALIZED (Target: XAUUSD $4000+)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, ObjPrefix);
   Comment("");
}

//==================================================================
// 4. MAIN TICK LOOP
//==================================================================
void OnTick() {
   // --- A. DASHBOARD & DATA UPDATE ---
   // 1. Get Math Data
   RegressionResult math = CalculateRegression(LRC_Period);
   double currentATR = GetCurrentATR();
   
   // 2. Update Visuals
   DrawChannel(math);
   
   // 3. News Status Check
   bool isNews = CheckNewsFilter();
   
   // 4. Update Dashboard
   UpdateDashboard(math, currentATR, isNews);
   
   // --- B. TRADING LOGIC ---
   
   // 1. Spread Filter
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;
   
   // 2. News Filter Block
   if(isNews) return; // STOP here if news is active

   // 3. Trade Management (Trailing & Partial Close)
   ManagePositions(math);

   // 4. Entry Filters (New Bar & Time)
   if(!CheckTimeFilter()) return;
   if(!isNewBar()) return;
    if(CountMyPositions() >= MaxPositions) return;

   // --- C. ENTRY SIGNALS ---
   double close = iClose(_Symbol, _Period, 1);
   double low   = iLow(_Symbol, _Period, 1);
   double high  = iHigh(_Symbol, _Period, 1);

   // Quality gates shared by both directions
   bool allowBuy  = true, allowSell = true;
   if(TrendFilterPeriod > 0) {
      RegressionResult tf = CalculateRegression(TrendFilterPeriod);
      // Medium-term trend must confirm: only BUY when longer window still slopes up
      if(tf.slope <= 0) allowBuy = false;
      if(tf.slope >= 0) allowSell = false;
   }
   if(CoolDownBars > 0 && lastClosedWasLoss && TimeCurrent() - lastClosedTime < CoolDownBars * 60) {
      if(lastClosedDirection == 1)  allowBuy  = false;   // last BUY lost -> wait before next BUY
      if(lastClosedDirection == -1) allowSell = false;   // last SELL lost -> wait before next SELL
   }

   // BUY LOGIC
   if(allowBuy && math.slope > Slope_Threshold && math.rSquared >= R_Squared_Min) {
      double lowerCh1 = (math.slope * (-1) + math.intercept) - (2.0 * math.stdDev);
      // Price touches lower channel and closes back inside
      if(low <= lowerCh1 && close > lowerCh1) {
         OpenTrade(ORDER_TYPE_BUY, currentATR, math);
      }
   }

   // SELL LOGIC
   else if(allowSell && math.slope < -Slope_Threshold && math.rSquared >= R_Squared_Min) {
      double upperCh1 = (math.slope * (-1) + math.intercept) + (2.0 * math.stdDev);
      // Price touches upper channel and closes back inside
      if(high >= upperCh1 && close < upperCh1) {
         OpenTrade(ORDER_TYPE_SELL, currentATR, math);
      }
   }
}

//==================================================================
// 5. MATH CORE FUNCTIONS
//==================================================================
RegressionResult CalculateRegression(int n) {
   RegressionResult res;
   ZeroMemory(res);
   
   double sumX=0, sumY=0, sumXY=0, sumX2=0, sumY2=0;
   double prices[];
   
   if(CopyClose(_Symbol, _Period, 0, n, prices) < n) return res;
   
   for(int i=0; i<n; i++) {
      double price = prices[n-1-i]; // 0 is newest
      double x = -i;
      
      sumX  += x;
      sumY  += price;
      sumXY += (x * price);
      sumX2 += (x * x);
      sumY2 += (price * price);
   }
   
   double denominator = (n * sumX2 - sumX * sumX);
   if(denominator == 0) return res;
   
   res.slope = (n * sumXY - sumX * sumY) / denominator;
   res.intercept = (sumY - res.slope * sumX) / n;
   
   // R-Squared
   double num_r = (n * sumXY - sumX * sumY);
   double den_r = ((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY));
   if (den_r > 0) res.rSquared = (num_r * num_r) / den_r;
   
   // StdDev
   double sumSqDiff = 0;
   for(int i=0; i<n; i++) {
      double price = prices[n-1-i];
      double regVal = res.slope * (-i) + res.intercept;
      sumSqDiff += MathPow(price - regVal, 2);
   }
   res.stdDev = MathSqrt(sumSqDiff / n);
   
   // Current Channel Values
   res.centerLine   = res.intercept;
   res.upperChannel = res.centerLine + (2.0 * res.stdDev);
   res.lowerChannel = res.centerLine - (2.0 * res.stdDev);
   
   return res;
}

//==================================================================
// 6. AUTO NEWS FILTER LOGIC (WEB REQUEST)
//==================================================================
bool CheckNewsFilter() {
   if(!UseAutoNews) return false;
   
   // Update news data every 4 hours
   if(TimeCurrent() - lastNewsFetchTime > 14400) {
      FetchNewsData();
   }
   
   datetime now = TimeCurrent();
   
   for(int i=0; i<ArraySize(WeeklyNews); i++) {
      // Filter logic: Only USD and High Impact (or Medium if enabled)
      if(WeeklyNews[i].currency != "USD") continue;
      
      bool isHigh   = (StringFind(WeeklyNews[i].impact, "High") >= 0);
      bool isMedium = (StringFind(WeeklyNews[i].impact, "Medium") >= 0);
      
      if(!isHigh && (!IncludeMedium || !isMedium)) continue;
      
      // Time Check
      long diff = (long)now - (long)WeeklyNews[i].time;
      
      // If within [Before, After] window
      if(diff >= -PauseMinsBefore * 60 && diff <= PauseMinsAfter * 60) {
         // Optional: Display alert on dashboard
         return true; // PAUSE TRADING
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

// Simple JSON Parser adapted for ForexFactory structure
void ParseNewsJson(string json) {
   ArrayResize(WeeklyNews, 0);
   
   // Split JSON by objects "},{"
   string objects[];
   StringSplit(json, '}', objects); // Crude split
   
   for(int i=0; i<ArraySize(objects); i++) {
      string obj = objects[i];
      
      // We look for "country":"USD" inside this object string
      if(StringFind(obj, "\"country\":\"USD\"") < 0) continue;
      
      // Extract Impact
      string impact = "";
      if(StringFind(obj, "\"impact\":\"High\"") >= 0) impact = "High";
      else if(StringFind(obj, "\"impact\":\"Medium\"") >= 0) impact = "Medium";
      
      if(impact == "") continue; // Skip Low impact
      
      // Extract Date string like "2025-11-24T09:00:00-05:00"
      int dateStart = StringFind(obj, "\"date\":\"");
      if(dateStart < 0) continue;
      
      string dateStr = StringSubstr(obj, dateStart + 8, 19); // Get "2025-11-24T09:00:00"
      StringReplace(dateStr, "T", " "); // Convert to "2025-11-24 09:00:00"
      
      datetime newsTime = StringToTime(dateStr);
      
      // Adjust Timezone (Simple Offset)
      // ForexFactory usually provides time with offset in the string, but StringToTime ignores it often.
      // We assume the time in JSON is roughly UTC-5 (NY) or UTC. 
      // It is safer to manually align via input 'ServerTimeOffset' if needed.
      // For simplicity here, we add ServerTimeOffset hours to the parsed time.
      newsTime = newsTime + (ServerTimeOffset * 3600); 
      
      // Extract Title
      int titleStart = StringFind(obj, "\"title\":\"");
      string title = "News";
      if(titleStart >= 0) {
         int titleEnd = StringFind(obj, "\"", titleStart + 9);
         title = StringSubstr(obj, titleStart + 9, titleEnd - (titleStart + 9));
      }
      
      // Add to Array
      int newIdx = ArrayResize(WeeklyNews, ArraySize(WeeklyNews) + 1);
      WeeklyNews[newIdx-1].time = newsTime;
      WeeklyNews[newIdx-1].impact = impact;
      WeeklyNews[newIdx-1].currency = "USD";
      WeeklyNews[newIdx-1].title = title;
   }
}

//==================================================================
// 7. EXECUTION & MANAGEMENT
//==================================================================
void OpenTrade(ENUM_ORDER_TYPE type, double atr, RegressionResult &math) {
double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
   double slDist;
   double sl;
   if(SL_Mode == 2) {
      // Fixed-point SL: exact point distance requested
      slDist = SL_FixedPoints * _Point;
      sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   } else if(SL_Mode == 1) {
      // Previous candle extreme + fixed gap buffer (no ATR dependence)
      double prevLow  = iLow(_Symbol, _Period, 1);
      double prevHigh = iHigh(_Symbol, _Period, 1);
      double gap      = SL_GapPoints * _Point;
      sl = (type == ORDER_TYPE_BUY) ? prevLow  - gap : prevHigh + gap;
      // Keep SL on the correct side of the entry price
      if(type == ORDER_TYPE_BUY) {
         if(sl >= price) sl = price - gap;
      } else {
         if(sl <= price) sl = price + gap;
      }
      slDist = MathAbs(price - sl);
      // Sideways/small prev candle -> natural SL too tight: use fixed SL for THIS trade
      double prevRange = prevHigh - prevLow;
      if(prevRange < SL_MinNaturalPts * _Point || slDist < SL_MinNaturalPts * _Point) {
         slDist = SL_FixedPoints * _Point;
         sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
      }
   } else {
      slDist = atr * ATR_Multiplier_SL;
      if (slDist < 200 * _Point) slDist = 200 * _Point;
      sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   }
   
   double tp;
   if(UseFixedRR) {
      double tpDist = slDist * FixedRR;
      tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;
   } else {
      tp = (type == ORDER_TYPE_BUY) ? math.upperChannel : math.lowerChannel;
   }
   
   // Lot Size Calculation
   // Risk base = RiskPercent% of balance at the SL distance.
   // Money rule (user 2026-09-10): EVERY consecutive loss adds LotStepPerLoss (0.01 lot)
   // on top of that, reset to base lot once a trade wins.
   double effRisk = RiskPercent;
   if(consecLosses >= ConsecLossTrigger)
      effRisk = RiskPercent + (consecLosses - ConsecLossTrigger + 1) * RiskStepPercent;

double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = FixedLot;

   if(effRisk > 0 && slDist > 0) {
      SymbolInfoTick(_Symbol, lastTick);
      double onePointCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) /
                            (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point);
      double slPts     = slDist / _Point;
      double riskMoney = balance * effRisk / 100.0;
      double lotFromRisk = 0.0;
      if(onePointCost > 0) lotFromRisk = riskMoney / (slPts * onePointCost);
      lot = lotFromRisk;
   }
   // +0.01 lot per consecutive loss (reset on win via consecLosses=0)
   lot += consecLosses * LotStepPerLoss;

   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   notEnoughMoney = false;
   if(effRisk > 0 && slDist > 0 && lot > 0) {
      // Cap: never risk more than 2.0x the target risk % of BALANCE on one trade.
      double onePointCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) /
                            (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point);
      double actualRiskStop = (lot * (slDist / _Point) * onePointCost) / balance * 100.0;
      double riskCap = effRisk * 2.0;
      if(actualRiskStop > riskCap && lot > 0 && onePointCost > 0) {
         lot = (balance * riskCap / 100.0) / ((slDist / _Point) * onePointCost);
         actualRiskStop = riskCap;
      }
      // Skip entirely if even min-lot risks more than riskCap% of balance.
      double minLotRiskPct = (min * (slDist / _Point) * onePointCost) / balance * 100.0;
      if(minLotRiskPct > riskCap) notEnoughMoney = true;
   }

   lot = MathFloor(lot/step) * step;
   if(lot < min) lot = min;
   if(lot > max) lot = max;
   if(notEnoughMoney) lot = 0.0;

   if(notEnoughMoney) return;
   
   if(type == ORDER_TYPE_BUY) trade.Buy(lot, _Symbol, price, sl, tp, "QMAI-V6 Buy");
   else trade.Sell(lot, _Symbol, price, sl, tp, "QMAI-V6 Sell");
}

int CountMyPositions() {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      count++;
   }
   return count;
}

void ManagePositions(RegressionResult &math) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      string comment = PositionGetString(POSITION_COMMENT);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      
      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // 0. Max Hold Time Exit
      if(MaxHoldMinutes > 0 && (TimeCurrent() - openTime) > MaxHoldMinutes * 60) {
         trade.PositionClose(ticket);
         continue;
      }
      
      // 1. Partial Close at Mean Reversion (Center Line)
      // DISABLED: pulling SL down to entry here pins winners at break-even and can
      // close in loss while price is still moving in our favour. Only the forward-only
      // 10% trail below is allowed to manage the stop now.
      //if(StringFind(comment, "Partial") < 0 && vol > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
      //   bool hitTarget = false;
      //   if(type == POSITION_TYPE_BUY && currentPrice >= math.centerLine) hitTarget = true;
      //   if(type == POSITION_TYPE_SELL && currentPrice <= math.centerLine) hitTarget = true;
      //
      //   if(hitTarget) {
      //      double closeVol = NormalizeDouble(vol * 0.5, 2);
      //      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      //      closeVol = MathFloor(closeVol/step) * step;
      //
      //      if(closeVol >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
      //         trade.PositionClosePartial(ticket, closeVol);
      //         Print(">>> V6: Partial Close 50% at Mean Reversion");
      //      }
      //      // Move SL to Break Even
      //      trade.PositionModify(ticket, openPrice, tp);
      //   }
      //}
      
      // 1b. EARLY BREAK-EVEN at EarlyBE pts GENUINE profit
      // DISABLED per user request 2026-09-09: pulling SL to open = trailing to BE,
      // which user does NOT want. SL left untouched. Only initial SL + max-hold manage.
      //double profitNow = (type == POSITION_TYPE_BUY) ? currentPrice - openPrice : openPrice - currentPrice;
      //double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
      //double realProfit = (type == POSITION_TYPE_BUY) ? profitNow + spreadPts : profitNow + spreadPts;
      //if(realProfit >= EarlyBEThreshold * _Point) {
      //   if(type == POSITION_TYPE_BUY && (sl == 0 || sl < openPrice)) trade.PositionModify(ticket, openPrice, tp);
      //   else if(type == POSITION_TYPE_SELL && (sl == 0 || sl > openPrice)) trade.PositionModify(ticket, openPrice, tp);
      //}

      
      // 2. Trailing Stop - REMOVED per user request 2026-09-09.
      // Positions now run to target/SL untouched (max-hold still manages them).
      //if(EnableTrailing) {
      //   double trailTrig = TrailingStart * _Point;
      //   double stepPts   = (TrailStep > 0) ? TrailStep * _Point : 1 * _Point;
      //   if(type == POSITION_TYPE_BUY) {
      //      if(currentPrice > openPrice + trailTrig) { // profit beyond activation
      //         double profitDist = currentPrice - openPrice;
      //         double trailGap  = profitDist * TrailingPercent / 100.0;
      //         double newSL     = currentPrice - trailGap;
      //         if(newSL - sl >= stepPts && newSL > sl) trade.PositionModify(ticket, newSL, tp);
      //      }
      //   }
      //   else if(type == POSITION_TYPE_SELL) {
      //      if(currentPrice < openPrice - trailTrig) {
      //         double profitDist = openPrice - currentPrice;
      //         double trailGap  = profitDist * TrailingPercent / 100.0;
      //         double newSL     = currentPrice + trailGap;
      //         if(sl - newSL >= stepPts && (sl == 0 || newSL < sl)) trade.PositionModify(ticket, newSL, tp);
      //      }
      //   }
      //}
   }
}

//==================================================================
// 7b. POSITION-CLOSE TRACKER (for same-direction cooldown)
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   // Find a closing deal on our magic number
   HistorySelectByPosition(trans.position);
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++) {
      ulong dt = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dt, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      // Direction from the closing deal type: DEAL_TYPE_BUY closes a SELL position...
      long dType = HistoryDealGetInteger(dt, DEAL_TYPE);
      int dir = (dType == DEAL_TYPE_BUY) ? -1 : 1;   // ...so BUY-deal => closed SELL (dir -1)
      double pnl = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP)
                 + HistoryDealGetDouble(dt, DEAL_COMMISSION);
      // Only record once the whole position is gone from the terminal
      if(PositionSelectByTicket(trans.position)) return;
      lastClosedDirection = dir;
      lastClosedWasLoss   = (pnl < 0);
      lastClosedTime      = TimeCurrent();
      // Risk-ramp streak: reset on any winning (>=0) close, else grow the streak
      if(pnl < 0) { consecLosses++; }
      else        { consecLosses = 0; }
      break;
   }
}

//==================================================================
// 8. UTILITIES & VISUALS
//==================================================================
void UpdateDashboard(RegressionResult &m, double atr, bool newsPause) {
   string text = "=== QUANTUM MATH V6.0 (THE GUARDIAN) ===\n";
   text += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   text += "----------------------------------------\n";
   
   // R-Squared Status
   string r2Text = DoubleToString(m.rSquared, 4);
   if(m.rSquared >= R_Squared_Min) r2Text += " [Tradable]";
   else r2Text += " [Weak Trend]";
   text += "R-Squared: " + r2Text + "\n";
   
   // Consecutive-loss risk ramp status
   double effRisk = RiskPercent;
   if(consecLosses >= ConsecLossTrigger)
      effRisk = RiskPercent + (consecLosses - ConsecLossTrigger + 1) * RiskStepPercent;
   text += "Risk: " + DoubleToString(effRisk, 2) + "% (consecLosses=" + IntegerToString(consecLosses) + ")" + "\n";
   if(consecLosses > 0)
      text += "Lot add: +" + DoubleToString(consecLosses * LotStepPerLoss, 2) + " lot (streak)\n";
   
   // Volatility
   text += "Volatility (ATR): " + DoubleToString(atr / _Point, 0) + " pts\n";
   
   // Filter Status
   if(newsPause) text += "STATUS: PAUSED (NEWS DETECTED)\n";
   else if(!CheckTimeFilter()) text += "STATUS: SLEEPING (TIME FILTER)\n";
   else text += "STATUS: HUNTING...\n";
   
   // News Info
   text += "----------------------------------------\n";
   text += "Auto-News: " + (UseAutoNews ? "ON" : "OFF") + "\n";
   
   Comment(text);
}

void DrawChannel(RegressionResult &m) {
   DrawLine(ObjPrefix+"Center", m.centerLine, clrGold, 2);
   DrawLine(ObjPrefix+"Upper", m.upperChannel, clrRed, 1, STYLE_DOT);
   DrawLine(ObjPrefix+"Lower", m.lowerChannel, clrLime, 1, STYLE_DOT);
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
   if(dt.hour >= StartHour && dt.hour < EndHour) return true;
   return false;
}

bool isNewBar() {
   if(lastBarTime != iTime(_Symbol, _Period, 0)) {
      lastBarTime = iTime(_Symbol, _Period, 0);
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+







