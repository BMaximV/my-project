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


class Order {
   private:
      MqlTradeRequest request;
      MqlTradeResult  result;
      double commission;

   public:
      MqlTradeResult getOrderInfo() {return result;}

      Order () {}

      void writeCommission() {
         bool rez = HistoryDealGetDouble(result.order, DEAL_COMMISSION, commission);
         if (!rez) Print(__FUNCTION__,": Error: ", GetLastError());
      }

      double lotCalculation(uchar num) {
         double lot = Lot;

         double marginForOneLot = MarketInfo(symbol, MODE_MARGINREQUIRED);
         double freeMargin = AccountFreeMargin();
         
         if (MultiLot != 1)  {
               for (int i=1; i<num; i++) lot*= MultiLot;
         }

         return lot;
      } 

      bool OrderOpen(ENUM_ORDER_TYPE type, uchar numberOfOrder) {
         request.action = TRADE_ACTION_DEAL;
         request.magic = Magic;
         request.symbol =_Symbol;
         request.volume = lotCalculation(numberOfOrder);
         request.type_filling = ORDER_FILLING_FOK;
         request.deviation = Slippage;
         request.type = type;

         if (OrderSend(request, result)) {
            Print(__FUNCTION__,": ",result.comment," Response Code: ",result.retcode);
            if (result.retcode != 10008 || result.retcode != 10009) return false;
         } else {
            Print(__FUNCTION__,": OrderSend return False");
            return false;
         }

         writeCommission();
         return true;
      }

      void select() {
         if (!PositionSelectByTicket(result.order)) {
               PrintFormat("PositionSelectByTicket(%I64u) failed. Error %d", result.order, GetLastError()); 
               ExpertRemove();
         };
      }

      double getProfit() {
         select(); 
         return PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_PROFIT) + commission;
      } 
   };

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
   
   if (orderOpen.buy == 0 && orderOpen.sell == 0) {
      orderOpen.buy = tick.ask + StartDistance * _Point;
      orderOpen.sell = tick.bid - StartDistance * _Point;
   }
   else {
      if (tick.bid >= orderOpen.buy && orderBuy == 0) orderBuy = OrderOpen(ORDER_TYPE_BUY);
      if (tick.ask <= orderOpen.sell && orderSell == 0) orderSell = OrderOpen(ORDER_TYPE_SELL);
   }
}
