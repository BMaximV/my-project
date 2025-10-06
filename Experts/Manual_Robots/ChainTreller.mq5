//+------------------------------------------------------------------+
//|                                                 ChainTreller.mq5 |
//|                                    Copyright 2025, Bulygin Maxim |
//|                                                 https://mql5.com |
//| 05.10.2025 - Initial release                                     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Bulygin Maxim"
#property link      "https://mql5.com"
#property version   "1.00"

input double Lot = 0.1;
input uchar LotP  = 10;
input uint StartDistance = 5;
input uint ContinueDistance = 20;
input double Multilot = 1.6;
input uint Magic = 111;
input uint Slippage = 3;


class OrderChain {
   private:
      Order *order[];
      uint count;
      double nextOrderPrice[2];
      double continueDistance;
      bool buyTrend;

      double CalcFirstLot () {
         double lot = 0.0;
         double marginPerLot = 0.0;
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

         bool rez = OrderCalcMargin(ORDER_TYPE_BUY, symbol, 1.0, ask, marginPerLot);
         if (! rez || marginPerLot <= 0.0)
            marginPerLot = SymbolInfoDouble(symbol, SYMBOL_MARGIN_INITIAL);

         lot = Lot;
         if (lot == 0) {
            if (marginPerLot > 0.0) {
               double maxLot = NormalizeDouble(balance / marginPerLot, 2);
               Print(__FUNCTION__, ": Max Lot: ", maxLot);
               lot = NormalizeDouble(maxLot * 100 / LotP, 2);
            }
            else
               lot = minLot;
         }
         if (lot < minLot)
            lot = minLot;

         return lot;
      }

   protected:  
      double firstLot;
      uint slippage;
      uint magic;
      string symbol;
      double oneTickCost;
      double ask;
      double bid;

   public:
      OrderChain() {
         slippage = Slippage;
         magic = Magic;
         symbol = _Symbol;
         ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         bid = SymbolInfoDouble(symbol, SYMBOL_BID);

         oneTickCost = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         nextOrderPrice[ORDER_TYPE_BUY] = ask + StartDistance * _Point;
         nextOrderPrice[ORDER_TYPE_SELL] = bid - StartDistance * _Point;
         continueDistance = ContinueDistance * _Point;
         firstLot = CalcFirstLot();
      }
};

class Order : public OrderChain {
   private:
      MqlTradeRequest request;
      MqlTradeResult  result;
      ulong ticket;

      double lotCalculation(uchar num) {
         double lot = Lot;
         if (Multilot != 1) {
            for (int i = 1; i < (int)num; i++) {
               lot *= Multilot;
            }
         }
         return lot;
      }

   public:
      Order() {}

      ulong open(ENUM_ORDER_TYPE type, uchar numberOfOrder) {
         request.action = TRADE_ACTION_DEAL;
         request.magic = magic;
         request.symbol = symbol;
         request.volume = lotCalculation(numberOfOrder);
         request.type_filling = ORDER_FILLING_FOK;
         request.deviation = slippage;
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

         ticket = (result.order != 0) ? result.order : result.deal;
         return ticket;
      }

};

int OnInit()
   {
   return(INIT_SUCCEEDED);
   }
void OnDeinit(const int reason)
   {
   }
void OnTick()
   {
   }

