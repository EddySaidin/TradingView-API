//+------------------------------------------------------------------+
//|                                  Marubozu_Strategy_EA.mq5        |
//|                        Converted from Pine Script Strategy        |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Marubozu Strategy EA"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade trade;
CPositionInfo position;
CAccountInfo account;
COrderInfo order;

//--- Input parameters
input group "=== Pattern Settings ==="
input int      C_Len = 14;                    // EMA depth for bodyAvg
input double   C_ShadowPercent = 5.0;         // Shadow size percentage
input double   C_DojiBodyPercent = 5.0;       // Doji body percentage
input double   C_MarubozuShadowPercent = 5.0; // Marubozu shadow percentage

input group "=== Trading Settings ==="
input bool     BuyEnabled = true;             // Enable BUY Signals
input bool     SellEnabled = false;           // Enable SELL Signals
input bool     EnabledOneTrade = true;        // Do not entry until previous one closes
input double   LotSize = 0.1;                 // Lot Size
input int      MagicNumber = 123456;          // Magic Number

input group "=== Risk Management ==="
input double   TpRiskRewardRatio = 1.0;       // TP/SL Risk-Reward Ratio
input double   SlRiskRewardRatio = 0.0;       // Stop Loss Extra Margin
input bool     UsePipAmount = false;          // Use pip amount as SL
input double   MaxPipLoss = 30.0;             // Max pip allowed to SL
input bool     UseAtrSL = true;               // Use ATR for SL
input int      nATRPeriod = 5;                // ATR Period
input double   nATRMultip = 3.5;              // ATR Multiplier
input double   AtrXtraMargin = 0;             // ATR Extra Margin

input group "=== Support/Resistance ==="
input bool     EnableSRplot = false;          // Enable Lux Algo S&R
input int      Periods = 10;                  // Period for pivot points
input int      VolumeThresh = 20;              // Volume Threshold

input group "=== Display ==="
input bool     ShowLabels = true;             // Show Labels
input bool     UseMarketOrders = false;       // Use Market Orders (better for backtesting)

//--- Global variables
int atrHandle;
int emaVolume5Handle;
int emaVolume10Handle;

double entryPrice = 0;
double takeProfitPrice = 0;
double stopLossPrice = 0;
ulong ticket = 0;

// Body EMA calculation
double bodyEMA = 0;

// Statistics
double cumulativePL = 0;
int winTrades = 0;
int totalTrades = 0;
double lastPL = 0;

// Support/Resistance
double highUsePivot = 0;
double lowUsePivot = 0;
double prevHighPivot = 0;
double prevLowPivot = 0;

// ATR Trailing Stop
double xATRTrailingStop = 0;
double prevATRTrailingStop = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize indicators
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, nATRPeriod);
   emaVolume5Handle = iMA(_Symbol, PERIOD_CURRENT, 5, 0, MODE_EMA, VOLUME_TICK);
   emaVolume10Handle = iMA(_Symbol, PERIOD_CURRENT, 10, 0, MODE_EMA, VOLUME_TICK);
   
   if(atrHandle == INVALID_HANDLE || emaVolume5Handle == INVALID_HANDLE || 
      emaVolume10Handle == INVALID_HANDLE)
   {
      Print("Error creating indicators");
      return(INIT_FAILED);
   }
   
   // Initialize body EMA
   InitializeBodyEMA();
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaVolume5Handle != INVALID_HANDLE) IndicatorRelease(emaVolume5Handle);
   if(emaVolume10Handle != INVALID_HANDLE) IndicatorRelease(emaVolume10Handle);
   
   // Delete all labels
   ObjectsDeleteAll(0, "MarubozuLabel_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if new bar
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;
   
   // Check for exits first
   CheckExits();
   
   // Update ticket if order was executed and became a position
   if(ticket > 0 && !HasPendingOrder() && HasOpenPosition())
   {
      ticket = GetPositionTicket();
   }
   
   // Check for new entries only if no position or pending order exists (if enabled)
   if(EnabledOneTrade && (HasOpenPosition() || HasPendingOrder()))
      return;
   
   // Calculate indicators
   double atr[];
   double emaVol5[];
   double emaVol10[];
   double emaBody[];
   
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(emaVol5, true);
   ArraySetAsSeries(emaVol10, true);
   ArraySetAsSeries(emaBody, true);
   
   if(CopyBuffer(atrHandle, 0, 0, 3, atr) <= 0) return;
   if(CopyBuffer(emaVolume5Handle, 0, 0, 3, emaVol5) <= 0) return;
   if(CopyBuffer(emaVolume10Handle, 0, 0, 3, emaVol10) <= 0) return;
   
   // Update body EMA
   UpdateBodyEMA();
   double bodyAvg = bodyEMA;
   
   // Safety check - if bodyEMA is 0 or invalid, skip this bar
   if(bodyAvg <= 0)
   {
      if(MQLInfoInteger(MQL_TESTER))
         Print("Warning: Body EMA is invalid: ", bodyAvg);
      return;
   }
   
   // Get current candle data
   double open = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double low = iLow(_Symbol, PERIOD_CURRENT, 0);
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   
   // Calculate candle body and shadows
   double C_BodyHi = MathMax(close, open);
   double C_BodyLo = MathMin(close, open);
   double C_Body = C_BodyHi - C_BodyLo;
   bool C_LongBody = C_Body > bodyAvg;
   double C_UpShadow = high - C_BodyHi;
   double C_DnShadow = C_BodyLo - low;
   double C_Range = high - low;
   
   // Calculate ATR values
   double xATR = atr[0];
   double nLoss = nATRMultip * xATR;
   double AtrBuyStopLoss = close - nLoss;
   double AtrSellStopLoss = close + nLoss;
   
   // Update ATR Trailing Stop
   UpdateATRTrailingStop(close, nLoss);
   
   // Calculate Support/Resistance
   CalculateSupportResistance();
   
   // Check for Marubozu Bullish Pattern
   bool C_MarubozuWhiteBullish = (open < close) && C_LongBody && 
                                  (C_UpShadow <= C_MarubozuShadowPercent / 100.0 * C_Body) && 
                                  (C_DnShadow <= C_MarubozuShadowPercent / 100.0 * C_Body);
   
   // Debug output
   if(MQLInfoInteger(MQL_TESTER) && C_MarubozuWhiteBullish)
   {
      Print("Pattern detected - Open: ", open, " Close: ", close, " Body: ", C_Body, " BodyAvg: ", bodyAvg, 
            " UpShadow: ", C_UpShadow, " DnShadow: ", C_DnShadow, " BuyEnabled: ", BuyEnabled,
            " Close > AtrBuyStopLoss: ", (close > (AtrBuyStopLoss - AtrXtraMargin)));
   }
   
   if(BuyEnabled && C_MarubozuWhiteBullish && close > (AtrBuyStopLoss - AtrXtraMargin))
   {
      // Calculate entry, TP, and SL
      entryPrice = (close - open) / 2.0 + open;
      stopLossPrice = (lowUsePivot < entryPrice && lowUsePivot > 0) ? lowUsePivot - SlRiskRewardRatio : open - SlRiskRewardRatio;
      
      if(UsePipAmount)
      {
         double pipValue = GetPipValue();
         stopLossPrice = entryPrice - MaxPipLoss * pipValue - SlRiskRewardRatio;
      }
      if(UseAtrSL)
         stopLossPrice = AtrBuyStopLoss - AtrXtraMargin;
      
      takeProfitPrice = entryPrice + TpRiskRewardRatio * (entryPrice - stopLossPrice);
      
      // Normalize prices
      entryPrice = NormalizeDouble(entryPrice, _Digits);
      stopLossPrice = NormalizeDouble(stopLossPrice, _Digits);
      takeProfitPrice = NormalizeDouble(takeProfitPrice, _Digits);
      
      bool orderPlaced = false;
      
      if(UseMarketOrders || MQLInfoInteger(MQL_TESTER))
      {
         // Use market order for immediate execution (better for backtesting)
         orderPlaced = trade.Buy(LotSize, _Symbol, 0, stopLossPrice, takeProfitPrice, "Marubozu Buy");
         if(orderPlaced)
         {
            ticket = GetPositionTicket();
            Print("BUY Market Order executed at: ", entryPrice, " TP: ", takeProfitPrice, " SL: ", stopLossPrice);
         }
      }
      else
      {
         // Use pending order - place BuyStop above the high of the pattern candle
         double orderPrice = high + (high * 0.0001); // Slightly above high to ensure execution
         orderPrice = NormalizeDouble(orderPrice, _Digits);
         
         if(orderPrice > close)
         {
            // Place BuyStop order (price needs to rise to entry)
            orderPlaced = trade.BuyStop(LotSize, orderPrice, _Symbol, stopLossPrice, takeProfitPrice, ORDER_TIME_GTC, 0, "Marubozu Buy");
         }
         else
         {
            // If order price is below close, use market order instead
            orderPlaced = trade.Buy(LotSize, _Symbol, 0, stopLossPrice, takeProfitPrice, "Marubozu Buy");
         }
         
         if(orderPlaced)
         {
            ticket = trade.ResultOrder();
            if(ticket == 0) ticket = GetPositionTicket();
         }
      }
      
      if(orderPlaced)
      {
         if(ShowLabels)
            CreateLabel("BUY: " + DoubleToString(entryPrice, _Digits) + " TP: " + 
                       DoubleToString(takeProfitPrice, _Digits) + " SL: " + 
                       DoubleToString(stopLossPrice, _Digits), clrBlue);
      }
      else
      {
         Print("Failed to place BUY order. Error: ", trade.ResultRetcodeDescription(), " Entry: ", entryPrice, " Close: ", close);
      }
   }
   
   // Check for Marubozu Bearish Pattern
   bool C_MarubozuBlackBearish = (open > close) && C_LongBody && 
                                 (C_UpShadow <= C_MarubozuShadowPercent / 100.0 * C_Body) && 
                                 (C_DnShadow <= C_MarubozuShadowPercent / 100.0 * C_Body);
   
   if(SellEnabled && C_MarubozuBlackBearish && close < (AtrSellStopLoss + AtrXtraMargin))
   {
      // Calculate entry, TP, and SL
      entryPrice = open - (open - close) / 2.0;
      stopLossPrice = (highUsePivot > entryPrice && highUsePivot > 0) ? highUsePivot + SlRiskRewardRatio : close + SlRiskRewardRatio;
      
      if(UsePipAmount)
      {
         double pipValue = GetPipValue();
         stopLossPrice = entryPrice + MaxPipLoss * pipValue + SlRiskRewardRatio;
      }
      if(UseAtrSL)
         stopLossPrice = AtrSellStopLoss + AtrXtraMargin;
      
      takeProfitPrice = entryPrice - TpRiskRewardRatio * (stopLossPrice - entryPrice);
      
      // Normalize prices
      entryPrice = NormalizeDouble(entryPrice, _Digits);
      stopLossPrice = NormalizeDouble(stopLossPrice, _Digits);
      takeProfitPrice = NormalizeDouble(takeProfitPrice, _Digits);
      
      bool orderPlaced = false;
      
      if(UseMarketOrders || MQLInfoInteger(MQL_TESTER))
      {
         // Use market order for immediate execution (better for backtesting)
         orderPlaced = trade.Sell(LotSize, _Symbol, 0, stopLossPrice, takeProfitPrice, "Marubozu Sell");
         if(orderPlaced)
         {
            ticket = GetPositionTicket();
            Print("SELL Market Order executed at: ", entryPrice, " TP: ", takeProfitPrice, " SL: ", stopLossPrice);
         }
      }
      else
      {
         // Use pending order - place SellStop below the low of the pattern candle
         double orderPrice = low - (low * 0.0001); // Slightly below low to ensure execution
         orderPrice = NormalizeDouble(orderPrice, _Digits);
         
         if(orderPrice < close)
         {
            // Place SellStop order (price needs to fall to entry)
            orderPlaced = trade.SellStop(LotSize, orderPrice, _Symbol, stopLossPrice, takeProfitPrice, ORDER_TIME_GTC, 0, "Marubozu Sell");
         }
         else
         {
            // If order price is above close, use market order instead
            orderPlaced = trade.Sell(LotSize, _Symbol, 0, stopLossPrice, takeProfitPrice, "Marubozu Sell");
         }
         
         if(orderPlaced)
         {
            ticket = trade.ResultOrder();
            if(ticket == 0) ticket = GetPositionTicket();
         }
      }
      
      if(orderPlaced)
      {
         if(ShowLabels)
            CreateLabel("SELL: " + DoubleToString(entryPrice, _Digits) + " TP: " + 
                       DoubleToString(takeProfitPrice, _Digits) + " SL: " + 
                       DoubleToString(stopLossPrice, _Digits), clrRed);
      }
      else
      {
         Print("Failed to place SELL order. Error: ", trade.ResultRetcodeDescription(), " Entry: ", entryPrice, " Close: ", close);
      }
   }
}

//+------------------------------------------------------------------+
//| Check for exit conditions                                        |
//+------------------------------------------------------------------+
void CheckExits()
{
   // Find position by magic number
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Symbol() == _Symbol && position.Magic() == MagicNumber)
         {
            ticket = position.Ticket();
            found = true;
            break;
         }
      }
   }
   
   if(!found) return;
   
   // Select position by ticket to access properties
   if(!position.SelectByTicket(ticket)) return;
   
   double posOpenPrice = position.PriceOpen();
   double posSL = position.StopLoss();
   double posTP = position.TakeProfit();
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)position.PositionType();
   
   double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double low = iLow(_Symbol, PERIOD_CURRENT, 0);
   
   // Check TP hit for long position
   if(posType == POSITION_TYPE_BUY && high >= posTP && posTP > 0)
   {
      lastPL = 9.683893627696939 * (posTP - posOpenPrice) * LotSize;
      cumulativePL += lastPL;
      totalTrades++;
      if(lastPL > 0) winTrades++;
      
      if(trade.PositionClose(ticket))
      {
         double winRate = (totalTrades > 0) ? (winTrades / (double)totalTrades) * 100.0 : 0;
         if(ShowLabels)
            CreateLabel("GAINED: ++$" + DoubleToString(lastPL, 2) + 
                       "\nCumulative P/L: $" + DoubleToString(cumulativePL, 2) + 
                       "\nWin Rate: " + DoubleToString(winRate, 2) + "%" + 
                       "\nTotal Trades: " + IntegerToString(totalTrades), clrGreen);
         ticket = 0;
      }
   }
   
   // Check TP hit for short position
   if(posType == POSITION_TYPE_SELL && low <= posTP && posTP > 0)
   {
      lastPL = 9.683893627696939 * (posOpenPrice - posTP) * LotSize;
      cumulativePL += lastPL;
      totalTrades++;
      if(lastPL > 0) winTrades++;
      
      if(trade.PositionClose(ticket))
      {
         double winRate = (totalTrades > 0) ? (winTrades / (double)totalTrades) * 100.0 : 0;
         if(ShowLabels)
            CreateLabel("GAINED: ++$" + DoubleToString(lastPL, 2) + 
                       "\nCumulative P/L: $" + DoubleToString(cumulativePL, 2) + 
                       "\nWin Rate: " + DoubleToString(winRate, 2) + "%" + 
                       "\nTotal Trades: " + IntegerToString(totalTrades), clrGreen);
         ticket = 0;
      }
   }
   
   // Check SL hit for long position
   if(posType == POSITION_TYPE_BUY && low <= posSL && posSL > 0)
   {
      lastPL = 9.683893627696939 * (posSL - posOpenPrice) * LotSize;
      cumulativePL += lastPL;
      totalTrades++;
      if(lastPL > 0) winTrades++;
      
      if(trade.PositionClose(ticket))
      {
         double winRate = (totalTrades > 0) ? (winTrades / (double)totalTrades) * 100.0 : 0;
         if(ShowLabels)
            CreateLabel("LOST: --$" + DoubleToString(MathAbs(lastPL), 2) + 
                       "\nCumulative P/L: $" + DoubleToString(cumulativePL, 2) + 
                       "\nWin Rate: " + DoubleToString(winRate, 2) + "%" + 
                       "\nTotal Trades: " + IntegerToString(totalTrades), clrRed);
         ticket = 0;
      }
   }
   
   // Check SL hit for short position
   if(posType == POSITION_TYPE_SELL && high >= posSL && posSL > 0)
   {
      lastPL = 9.683893627696939 * (posOpenPrice - posSL) * LotSize;
      cumulativePL += lastPL;
      totalTrades++;
      if(lastPL > 0) winTrades++;
      
      if(trade.PositionClose(ticket))
      {
         double winRate = (totalTrades > 0) ? (winTrades / (double)totalTrades) * 100.0 : 0;
         if(ShowLabels)
            CreateLabel("LOST: --$" + DoubleToString(MathAbs(lastPL), 2) + 
                       "\nCumulative P/L: $" + DoubleToString(cumulativePL, 2) + 
                       "\nWin Rate: " + DoubleToString(winRate, 2) + "%" + 
                       "\nTotal Trades: " + IntegerToString(totalTrades), clrRed);
         ticket = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Support and Resistance levels                          |
//+------------------------------------------------------------------+
void CalculateSupportResistance()
{
   int leftBars = Periods;
   int rightBars = Periods;
   int lookbackBar;
   bool isPivot;
   
   // Find pivot high (looking at bar offset by rightBars+1)
   double pivotHigh = 0;
   bool foundHigh = false;
   lookbackBar = rightBars + 1;
   
   if(lookbackBar < Bars(_Symbol, PERIOD_CURRENT) - leftBars)
   {
      isPivot = true;
      double centerHigh = iHigh(_Symbol, PERIOD_CURRENT, lookbackBar);
      
      for(int j = lookbackBar - rightBars; j <= lookbackBar + leftBars; j++)
      {
         if(j != lookbackBar && iHigh(_Symbol, PERIOD_CURRENT, j) >= centerHigh)
         {
            isPivot = false;
            break;
         }
      }
      
      if(isPivot)
      {
         pivotHigh = centerHigh;
         foundHigh = true;
      }
   }
   
   if(foundHigh && pivotHigh != prevHighPivot)
   {
      highUsePivot = pivotHigh;
      prevHighPivot = pivotHigh;
   }
   
   // Find pivot low (looking at bar offset by rightBars+1)
   double pivotLow = 0;
   bool foundLow = false;
   lookbackBar = rightBars + 1;
   
   if(lookbackBar < Bars(_Symbol, PERIOD_CURRENT) - leftBars)
   {
      isPivot = true;
      double centerLow = iLow(_Symbol, PERIOD_CURRENT, lookbackBar);
      
      for(int j = lookbackBar - rightBars; j <= lookbackBar + leftBars; j++)
      {
         if(j != lookbackBar && iLow(_Symbol, PERIOD_CURRENT, j) <= centerLow)
         {
            isPivot = false;
            break;
         }
      }
      
      if(isPivot)
      {
         pivotLow = centerLow;
         foundLow = true;
      }
   }
   
   if(foundLow && pivotLow != prevLowPivot)
   {
      lowUsePivot = pivotLow;
      prevLowPivot = pivotLow;
   }
}

//+------------------------------------------------------------------+
//| Update ATR Trailing Stop                                         |
//+------------------------------------------------------------------+
void UpdateATRTrailingStop(double close, double nLoss)
{
   if(xATRTrailingStop == 0)
   {
      xATRTrailingStop = close - nLoss;
   }
   else
   {
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(close > xATRTrailingStop && prevClose > prevATRTrailingStop)
         xATRTrailingStop = MathMax(prevATRTrailingStop, close - nLoss);
      else if(close < xATRTrailingStop && prevClose < prevATRTrailingStop)
         xATRTrailingStop = MathMin(prevATRTrailingStop, close + nLoss);
      else if(close > xATRTrailingStop)
         xATRTrailingStop = close - nLoss;
      else
         xATRTrailingStop = close + nLoss;
   }
   prevATRTrailingStop = xATRTrailingStop;
}

//+------------------------------------------------------------------+
//| Initialize Body EMA                                               |
//+------------------------------------------------------------------+
void InitializeBodyEMA()
{
   double sum = 0;
   for(int i = 1; i <= C_Len; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      sum += MathAbs(close - open);
   }
   bodyEMA = sum / C_Len;
}

//+------------------------------------------------------------------+
//| Update Body EMA                                                   |
//+------------------------------------------------------------------+
void UpdateBodyEMA()
{
   double open = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double currentBody = MathAbs(close - open);
   
   double multiplier = 2.0 / (C_Len + 1.0);
   bodyEMA = (currentBody * multiplier) + (bodyEMA * (1.0 - multiplier));
}

//+------------------------------------------------------------------+
//| Check if position exists                                          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Symbol() == _Symbol && position.Magic() == MagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if pending order exists                                     |
//+------------------------------------------------------------------+
bool HasPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0)
      {
         if(order.Select(orderTicket))
         {
            if(order.Symbol() == _Symbol && order.Magic() == MagicNumber)
               return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get pip value based on symbol                                     |
//+------------------------------------------------------------------+
double GetPipValue()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return _Point * 10;
   else
      return _Point;
}

//+------------------------------------------------------------------+
//| Get position ticket by magic number                               |
//+------------------------------------------------------------------+
ulong GetPositionTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Symbol() == _Symbol && position.Magic() == MagicNumber)
            return position.Ticket();
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Create label on chart                                            |
//+------------------------------------------------------------------+
void CreateLabel(string text, color clr)
{
   string name = "MarubozuLabel_" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   double price = iClose(_Symbol, PERIOD_CURRENT, 0);
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   if(ObjectCreate(0, name, OBJ_TEXT, 0, time, price))
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   }
}

//+------------------------------------------------------------------+

