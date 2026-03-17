//+------------------------------------------------------------------+
//|                                                 LossAccumulation |
//|                                              (c) 2025, Max       |
//|                                                                  |
//| Intended for symbols with Market Execution mode.                 |
//| Volume filling policy: ORDER_FILLING_FOK.                        |
//+------------------------------------------------------------------+

input double Lot = 0.1; // "Lot" If 0 -> Using Lot Percentage from Balance (LotP)
input double LotP = 0.1; // "LotP" 1 = Max Lots from Balance, 0.5 = 50% Max Lots from Balance, etc.
input double MultiplyLot = 2.0;
input int Distance = 50; // Distance (in pips)
input int Trail_Start = 20; // Trail_Start (in pips)
input int Trail_Distance = 20; // Trail_Distance (in pips)
input uint Max_Trades = 5; // Max number of trades in chain
input int Magic = 111;
input int Slippage = 3;

string symbol;
double vol_min;
double vol_max;
double vol_step;
double distance;
double point;
double lots_cost;
int digits;

double ask;
double bid;
double first_lot;
bool trade_allowed;
double loss_accumulated;
double zero;
bool sell_direction;
double next_open;
uint cur_index;

bool is_trail;
double trail;
double trail_start;
double take_profit_price;

struct PositionData{
   double lot;
   double price;
   long ticket;
};

PositionData pos;

void StopExpert (string reason) {
   PrintFormat("=== Expert stopped ===: %s | err=%d", reason, GetLastError());
   ExpertRemove();
} 

double StopExpertDouble(string reason) {
   StopExpert(reason);
   return 0.0;
}

double GetSymbolInfoDouble(ENUM_SYMBOL_INFO_DOUBLE prop, const string err){
   ResetLastError();
   double value = SymbolInfoDouble(symbol, prop);
   if(value <= 0.0)  return StopExpertDouble("Volume min invalid");
   return value;
}

double FirstLotCalculate(ENUM_ORDER_TYPE order_type) {
   if (Lot > 0.0) {
      first_lot = Lot;
      return Lot;
   }
   // --- balance target
   ResetLastError();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE) * LotP;
   if(balance <= 0.0) return StopExpertDouble("Balance is zero or negative");

   // --- price
   ResetLastError();
   double price = 0.0;
   switch(order_type) {
      case ORDER_TYPE_BUY:
         price = ask; break;
      case ORDER_TYPE_SELL:
         price = bid; break;
      default:
         return StopExpertDouble("Unsupported order type (use BUY/SELL)");
   }
   if(price <= 0.0) return StopExpertDouble("Price is zero or negative (no quotes?)");

   // --- margin for 1 lot (account currency, handled by terminal)
   ResetLastError();
   double margin_1lot = 0.0;
   if(!OrderCalcMargin(order_type, symbol, 1.0, price, margin_1lot)) return StopExpertDouble("OrderCalcMargin failed");
   if(margin_1lot <= 0.0) return StopExpertDouble("Margin for 1 lot is zero or negative");

   // --- raw lots
   ResetLastError();
   first_lot = balance / margin_1lot;

   // --- apply max, check min
   if(first_lot > vol_max) return StopExpertDouble("Lots upper limit after step normalization");
   if(first_lot < vol_min) return StopExpertDouble("Calculated lots below minimum allowed");

   // --- normalize to step (floor)
   first_lot = MathFloor(first_lot / vol_step) * vol_step;
   first_lot = NormalizeDouble(first_lot, 2);

   if(first_lot < vol_min) {
      if (first_lot < vol_min/2) StopExpertDouble("Lots lower limit after step normalization");
      else first_lot = vol_min;
   }

   return first_lot;
}

double LotCalculate(ENUM_ORDER_TYPE cmd, uint index) {
   if (index == 1) {
      return FirstLotCalculate(cmd);
   } else {
      double lot = first_lot;
      for(uint i=1; i<index; i++) 
         lot *= MultiplyLot;
      return lot;
   }
}

ENUM_ORDER_TYPE GetReversOrderType() {
   return sell_direction ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
}

double GetZeroPoint() {
   double profit_per_point = lots_cost * pos.lot;
   double pips_needed = -loss_accumulated / profit_per_point;
   double direction_sign = sell_direction ? -1.0 : 1.0;
   double breakeven_price = pos.price + direction_sign * pips_needed;

   return NormalizeDouble(breakeven_price, digits);
}

MqlTradeRequest GetRequestByClose() {
   MqlTradeRequest request={};

   request.action       =TRADE_ACTION_DEAL;
   request.position     =pos.ticket;
   request.volume       =pos.lot;
   request.symbol       =symbol;
   request.type         =GetReversOrderType();
   request.price        =sell_direction ? ask : bid;
   request.type_filling =ORDER_FILLING_FOK;
   request.deviation    =Slippage;
   request.magic        =Magic;

   return request;
}

MqlTradeRequest GetRequestByOpen(ENUM_ORDER_TYPE cmd, uint index) {
   MqlTradeRequest request={};

   request.action       =TRADE_ACTION_DEAL;
   request.symbol       =symbol;
   request.volume       =LotCalculate(cmd, index);
   request.type         =cmd;
   request.price        =cmd == ORDER_TYPE_BUY? ask: bid;
   request.type_filling =ORDER_FILLING_FOK;
   request.comment      =(string)index;
   request.deviation    =Slippage;
   request.magic        =Magic;

   return request;
}

void SendOrder(MqlTradeRequest &request) {
   MqlTradeResult  result={};

   ResetLastError();
   if(!OrderSendAsync(request,result)) {
      int err = GetLastError();
      if (err == 4756)  StopExpert("Not enough money to open position");
      else PrintFormat("!!!OrderSend error %d", err);
   } else {
      trade_allowed = false;
   }
}

void OrderOpen (ENUM_ORDER_TYPE cmd) {
   if (pos.ticket != 0) SendOrder(GetRequestByClose());
   else SendOrder(GetRequestByOpen(cmd, cur_index + 1));
}

void ManageTrail(double price) {
   take_profit_price = price;
   string line_name = "TrailLine";
   
   if (price == 0.0) {
      // Удалить линию
      if (ObjectFind(0, line_name) != -1) {
         ObjectDelete(0, line_name);
         ChartRedraw(0);
      }
   } else if (ObjectFind(0, line_name) == -1) {
      // Создать линию если её нет
      ObjectCreate(0, line_name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, line_name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, line_name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, line_name, OBJPROP_STYLE, STYLE_DASH);
      ChartRedraw(0);
   } else {
      // Обновить цену существующей линии
      ObjectSetDouble(0, line_name, OBJPROP_PRICE, price);
      ChartRedraw(0);
   }
}

void ResetChain() {
   is_trail = false;
   ManageTrail(0);
   loss_accumulated = 0.0;
   cur_index = 0;
   ZeroMemory(pos);
}

int OnInit() {
   symbol = Symbol();
   vol_min  = GetSymbolInfoDouble(SYMBOL_VOLUME_MIN, "Failed to get volume min");
   vol_max  = GetSymbolInfoDouble(SYMBOL_VOLUME_MAX, "Failed to get volume max");
   vol_step = GetSymbolInfoDouble(SYMBOL_VOLUME_STEP, "Failed to get volume step");
   point = GetSymbolInfoDouble(SYMBOL_POINT, "Failed to get symbol point");
   double tick_value = GetSymbolInfoDouble(SYMBOL_TRADE_TICK_VALUE, "Failed to get tick value");
   double tick_size  = GetSymbolInfoDouble(SYMBOL_TRADE_TICK_SIZE, "Failed to get tick size");
   lots_cost = tick_value / tick_size;
   distance = (double)Distance * point;
   trail = (double)Trail_Distance * point;
   trail_start = (double)Trail_Start * point;
   digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if (SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE) == SYMBOL_TRADE_EXECUTION_MARKET) {
      Print("Symbol trade execution mode is MARKET");
   } else {
      StopExpert("Symbol trade execution mode is not MARKET");
   }

   // loss_accumulated, first_lot and next_open should calculate from history if position exist already - TO DO
   trade_allowed = true;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){}

void OnTick() {
   if (!trade_allowed) return;
   ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
   bid = SymbolInfoDouble(symbol,SYMBOL_BID);

   if (take_profit_price != 0.0) {
      if (!sell_direction) {
         if (bid > take_profit_price + trail) {
            ManageTrail(bid - trail); return;
         }
         if (bid <= take_profit_price) {
            OrderOpen(ORDER_TYPE_SELL); return;
         }
      }
      if (sell_direction) {
         if (ask < take_profit_price - trail) {
            ManageTrail(ask + trail); return;
         }
         if (ask >= take_profit_price) {
            OrderOpen(ORDER_TYPE_BUY); return;
         }
      }
      return;
   }

   if (!sell_direction) {
      if (next_open == 0 || bid <= next_open) {
         if (cur_index >= Max_Trades) ResetChain();
         OrderOpen(ORDER_TYPE_SELL); return;
      }
      if (bid >= zero + trail_start) {
         ManageTrail(zero); return;
      }
   }
   if (sell_direction) {
      if (next_open == 0 || ask >= next_open) {
         if (cur_index >= Max_Trades) ResetChain();
         OrderOpen(ORDER_TYPE_BUY); return;
      }
      if (ask <= zero - trail_start) {
         ManageTrail(zero); return;
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {

   //Print(TransactionDescription(trans));
   if(trans.type==TRADE_TRANSACTION_REQUEST && request.symbol==symbol && request.magic==Magic) {
      // Print(TradeResultDescription(result));
      // Print(RequestDescription(request));

      long ticket = 0;
      ResetLastError();

      if (result.retcode != TRADE_RETCODE_DONE) {
         StopExpert("Trade request failed with code: " + (string)result.retcode + ". Request comment: " + result.comment);
         return;
      }
      if (!HistoryDealSelect(result.deal)) {
         StopExpert("Failed to select deal with ticket: " + (string)result.deal + " Error: " + (string)GetLastError());
         return;
      }
      if (!HistoryDealGetInteger(result.deal, DEAL_POSITION_ID, ticket)) {
         StopExpert("Failed to get position ID for deal: " + (string)result.deal + " Error: " + (string)GetLastError());
         return;
      }

      loss_accumulated += HistoryDealGetDouble(result.deal, DEAL_COMMISSION);

      if (ticket == pos.ticket) { // Order has been closed
         double profit = HistoryDealGetDouble(result.deal, DEAL_PROFIT);
         if (profit < 0) {
            loss_accumulated += profit;
         } else ResetChain();

         trade_allowed = true;
         SendOrder(GetRequestByOpen(GetReversOrderType(), cur_index + 1));
         return;
      }

      pos.ticket = ticket;
      trade_allowed = true;
      pos.lot = request.volume;
      pos.price = request.price;
      cur_index ++;
      sell_direction = (bool)request.type;
      next_open = sell_direction ? pos.price + distance : pos.price - distance;
      zero = GetZeroPoint();
   }
}

string TransactionDescription(const MqlTradeTransaction &trans) {
   string desc = "---- MqlTradeTransaction -----\r\n";
   desc+="Type: "+EnumToString(trans.type)+"\r\n";
   desc+="Symbol: "+trans.symbol+"\r\n";
   desc+="Deal ticket: "+(string)trans.deal+"\r\n";
   desc+="Deal type: "+EnumToString(trans.deal_type)+"\r\n";
   desc+="Order ticket: "+(string)trans.order+"\r\n";
   desc+="Order type: "+EnumToString(trans.order_type)+"\r\n";
   desc+="Order state: "+EnumToString(trans.order_state)+"\r\n";
   desc+="Order time type: "+EnumToString(trans.time_type)+"\r\n";
   desc+="Order expiration: "+TimeToString(trans.time_expiration)+"\r\n";
   desc+="Price: "+StringFormat("%G",trans.price)+"\r\n";
   desc+="Price trigger: "+StringFormat("%G",trans.price_trigger)+"\r\n";
   desc+="Stop Loss: "+StringFormat("%G",trans.price_sl)+"\r\n";
   desc+="Take Profit: "+StringFormat("%G",trans.price_tp)+"\r\n";
   desc+="Volume: "+StringFormat("%G",trans.volume)+"\r\n";
   desc+="Position: "+(string)trans.position+"\r\n";
   desc+="Position by: "+(string)trans.position_by+"\r\n";
   return desc;
}

string RequestDescription(const MqlTradeRequest &request) {
   string desc = "---- MqlTradeRequest -----\r\n";
   desc+="Action: "+EnumToString(request.action)+"\r\n";
   desc+="Symbol: "+request.symbol+"\r\n";
   desc+="Magic Number: "+StringFormat("%d",request.magic)+"\r\n";
   desc+="Order ticket: "+(string)request.order+"\r\n";
   desc+="Order type: "+EnumToString(request.type)+"\r\n";
   desc+="Order filling: "+EnumToString(request.type_filling)+"\r\n";
   desc+="Order time type: "+EnumToString(request.type_time)+"\r\n";
   desc+="Order expiration: "+TimeToString(request.expiration)+"\r\n";
   desc+="Price: "+StringFormat("%G",request.price)+"\r\n";
   desc+="Deviation points: "+StringFormat("%G",request.deviation)+"\r\n";
   desc+="Stop Loss: "+StringFormat("%G",request.sl)+"\r\n";
   desc+="Take Profit: "+StringFormat("%G",request.tp)+"\r\n";
   desc+="Stop Limit: "+StringFormat("%G",request.stoplimit)+"\r\n";
   desc+="Volume: "+StringFormat("%G",request.volume)+"\r\n";
   desc+="Comment: "+request.comment+"\r\n";
   return desc;
}

string TradeResultDescription(const MqlTradeResult &result) {
   string desc = "---- MqlTradeResult -----\r\n";
   desc+="Retcode "+(string)result.retcode+"\r\n";
   desc+="Request ID: "+StringFormat("%d",result.request_id)+"\r\n";
   desc+="Order ticket: "+(string)result.order+"\r\n";
   desc+="Deal ticket: "+(string)result.deal+"\r\n";
   desc+="Volume: "+StringFormat("%G",result.volume)+"\r\n";
   desc+="Price: "+StringFormat("%G",result.price)+"\r\n";
   desc+="Ask: "+StringFormat("%G",result.ask)+"\r\n";
   desc+="Bid: "+StringFormat("%G",result.bid)+"\r\n";
   desc+="Comment: "+result.comment+"\r\n";
   return desc;
}
