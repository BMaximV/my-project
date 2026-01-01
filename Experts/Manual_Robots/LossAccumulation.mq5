

input double Lot = 0.0; // If 0 -> Using Lot Percentage from Balance (LotP)
input double LotP = 1.0; // 1 = Max Lots from Balance, 0.5 = 50% Max Lots from Balance, etc.
input double MultiplyLot = 2.0;
input int Magic = 111;
input int Slippage = 3;

string symbol;
double ask;
double bid;
long ticket;
double first_lot=0.0;
bool trade_allowed=true;

double StopExpert(string reason) {
   Print("Expert stopped: ", reason);
   ExpertRemove();
   return 0.0;
}

double GetSymbolInfoDouble(ENUM_SYMBOL_INFO_DOUBLE prop, const string err){
   ResetLastError();
   double value = SymbolInfoDouble(symbol, prop);
   int error_code = GetLastError();
   if(error_code != 0)
      return StopExpert(err + ". Code: " + (string)error_code);
   return value;
}

double FirstLotCalculate(ENUM_ORDER_TYPE order_type) {
   if (Lot > 0.0) {
      return Lot;
   }
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE) * LotP;
   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   string acc_ccy  = AccountInfoString(ACCOUNT_CURRENCY);
   string margin_ccy = SymbolInfoString(symbol, SYMBOL_CURRENCY_MARGIN);
   double contract_size = GetSymbolInfoDouble(SYMBOL_TRADE_CONTRACT_SIZE, "Failed to get contract size");
   double vol_min = GetSymbolInfoDouble(SYMBOL_VOLUME_MIN, "Failed to get minimum volume");
   double vol_max = GetSymbolInfoDouble(SYMBOL_VOLUME_MAX, "Failed to get maximum volume");
   double vol_step = GetSymbolInfoDouble(SYMBOL_VOLUME_STEP, "Failed to get volume step");
   double price = order_type == ORDER_TYPE_BUY ? ask : bid;

   if (balance <= 0) return StopExpert("Balance is zero or negative");
   if (leverage <= 0) return StopExpert("Leverage is zero or negative");
   if (price <= 0) return StopExpert("Price is zero or negative");
   if (contract_size <= 0) return StopExpert("Contract size is zero or negative");
   if (margin_ccy != acc_ccy) return StopExpert("Margin currency:" + margin_ccy + " mismatch. Account currency:" + acc_ccy);
   if (vol_step <= 0) return StopExpert("Volume step is zero or negative");

   double margin_per_lot = contract_size * price / leverage;
   if (margin_per_lot <= 0) return StopExpert("Margin per lot is zero or negative");

   double lots = balance / margin_per_lot;
   if (lots > vol_max) return StopExpert("Calculated lots exceed maximum allowed");
   if (lots < vol_min) return StopExpert("Calculated lots below minimum allowed");

   lots = MathFloor(lots / vol_step) * vol_step;
   lots = NormalizeDouble(lots, 2);

   Print("First lot calculated: ", lots);
   return lots;
}

double LotCalculate(ENUM_ORDER_TYPE cmd, uint index) {
   if (!(bool)index) {
      return FirstLotCalculate(cmd);
   } else {
      double lot = first_lot;
      for(uint i=0; i<=index; i++) 
         lot *= MultiplyLot;
      return lot;
   }
}

void OrderOpen (ENUM_ORDER_TYPE cmd, uint index) {
   MqlTradeRequest request={};
   MqlTradeResult  result={};

   request.action    =TRADE_ACTION_DEAL;
   request.symbol    =symbol;
   request.volume    =LotCalculate(cmd, index);
   request.type      =cmd;
   request.price     =cmd == ORDER_TYPE_BUY? ask: bid;
   request.deviation =Slippage;
   request.magic     =Magic;

   if(OrderSendAsync(request,result)) {
      trade_allowed = false;
   } else {
      PrintFormat("OrderSend error %d",GetLastError());
   }
}

int OnInit() {
   symbol = Symbol();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){}

void OnTick() {
   ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
   bid = SymbolInfoDouble(symbol,SYMBOL_BID);

   if (trade_allowed) {
      OrderOpen(ORDER_TYPE_BUY, 0);
   }

   Print("Current ticket: ", ticket);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {

   if(trans.type==TRADE_TRANSACTION_REQUEST) {
      //trade_allowed = true;
      if (result.retcode != TRADE_RETCODE_DONE) {
         Print("Trade request failed with code: ", result.retcode, ". Request comment: ", result.comment);
         return;
      }
      if (!HistoryDealSelect(result.deal)) {
         Print("Failed to select deal with ticket: ", ticket, " Error: ", GetLastError());
         return;
      }
      if (!HistoryDealGetInteger(result.deal, DEAL_POSITION_ID, ticket)) {
         Print("Failed to get position ID for deal: ", result.deal, " Error: ", GetLastError());
         return;
      }
   }
}

string TransactionDescription(const MqlTradeTransaction &trans) {
   string desc=EnumToString(trans.type)+"\r\n";
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
   string desc=EnumToString(request.action)+"\r\n";
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
   string desc="Retcode "+(string)result.retcode+"\r\n";
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