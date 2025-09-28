#property copyright "Copyright 2025, Bulygin Maxim"
#property link      "https://mql5.com"
#property version   "1.00"

input double Lot = 1;
input int StartDistance = 5;
input double MultiLot = 2;
input ulong Magic = 1111;
input ulong Slippage = 3;

struct price {
   double bid;
   double ask;
};

struct positionPrice {
   double buy;
   double sell;
};

positionPrice orderOpen;

class OrderChain {
   private:
      uint count;
   protected:
   public:
};

ulong orderBuy = 0;
ulong orderSell = 0;
uchar buyOrderNumber = 1;
uchar sellOrderNumber = 1;

class Order {
   private:
      MqlTradeRequest request;
      MqlTradeResult  result;
      double commission;

      void writeCommission() {
         commission = 0.0;
         if (!HistoryDealGetDouble(result.deal, DEAL_COMMISSION, commission)) {
            Print(__FUNCTION__, ": Error reading commission: ", GetLastError());
         }
      }

      double lotCalculation(uchar num) {
         double lot = Lot;
         if (MultiLot != 1) {
            for (int i = 1; i < (int)num; i++) {
               lot *= MultiLot;
            }
         }
         return lot;
      }

   public:
      Order() {
         ZeroMemory(request);
         ZeroMemory(result);
         commission = 0.0;
      }

      MqlTradeResult getOrderInfo() {return result;}

      ulong OrderOpen(ENUM_ORDER_TYPE type, uchar numberOfOrder) {
         ZeroMemory(request);
         ZeroMemory(result);

         request.action = TRADE_ACTION_DEAL;
         request.magic = Magic;
         request.symbol = _Symbol;
         request.volume = lotCalculation(numberOfOrder);
         request.type_filling = ORDER_FILLING_FOK;
         request.deviation = (uint)Slippage;
         request.type = type;
         request.price = (type == ORDER_TYPE_BUY)
            ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
            : SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if (!OrderSend(request, result)) {
            Print(__FUNCTION__, ": OrderSend returned false. Error: ", GetLastError());
            return 0;
         }

         Print(__FUNCTION__, ": ", result.comment, " Response Code: ", result.retcode);
         if (result.retcode != 10008 && result.retcode != 10009) {
            Print(__FUNCTION__, ": unexpected retcode ", result.retcode);
            return 0;
         }

         writeCommission();
         if (result.order != 0) {
            return result.order;
         }
         return result.deal;
      }

      bool select(ulong ticket) {
         if (!PositionSelectByTicket(ticket)) {
            PrintFormat("PositionSelectByTicket(%I64u) failed. Error %d", ticket, GetLastError());
            return false;
         }
         return true;
      }

      double getProfit(ulong ticket) {
         if (!select(ticket)) {
            return 0.0;
         }
         return PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_PROFIT) + commission;
      }
};

Order trade;

int OnInit() {
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
}

void OnTick() {
   price tick;
   tick.bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   tick.ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   Comment("Bid: ", tick.bid, "\n",
           "Ask: ", tick.ask);

   if (orderOpen.buy == 0.0 && orderOpen.sell == 0.0) {
      orderOpen.buy = tick.ask + StartDistance * _Point;
      orderOpen.sell = tick.bid - StartDistance * _Point;
   } else {
      if (tick.bid >= orderOpen.buy && orderBuy == 0) {
         ulong ticket = trade.OrderOpen(ORDER_TYPE_BUY, buyOrderNumber);
         if (ticket != 0) {
            orderBuy = ticket;
            buyOrderNumber++;
         }
      }

      if (tick.ask <= orderOpen.sell && orderSell == 0) {
         ulong ticket = trade.OrderOpen(ORDER_TYPE_SELL, sellOrderNumber);
         if (ticket != 0) {
            orderSell = ticket;
            sellOrderNumber++;
         }
      }
   }
}
