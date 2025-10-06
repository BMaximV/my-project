//+------------------------------------------------------------------+
//|                                                         test.mq5 |
//|                                    Copyright 2025, Bulygin Maxim |
//|                                                 https://mql5.com |
//| 05.10.2025 - Initial release                                     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Bulygin Maxim"
#property link      "https://mql5.com"
#property version   "1.00"

input double Lot = 1;
input int StartDistance = 5;
input int ContinueDistance = 20;
input int MaxOrders = 3;
input double MultiLot = 2;
input ulong Magic = 1111;
input ulong Slippage = 3;

struct price {
   double bid;
   double ask;
};

enum ChainSide {
   CHAIN_BUY = 0,
   CHAIN_SELL = 1
};

class Order {
   private:
      MqlTradeRequest request;
      MqlTradeResult  result;
      ulong ticket;
      ENUM_POSITION_TYPE positionType;
      double openPrice;
      double volume;
      datetime openTime;
      string symbol;

      double lotCalculation(uchar num) {
         double lot = Lot;
         if (MultiLot != 1) {
            for (int i = 1; i < (int)num; i++) {
               lot *= MultiLot;
            }
         }
         return lot;
      }

      bool select() const {
         if (ticket == 0) {
            Print(__FUNCTION__, ": ticket is zero");
            return false;
         }

         if (!PositionSelectByTicket(ticket)) {
            PrintFormat("%s: PositionSelectByTicket(%I64u) failed. Error %d", __FUNCTION__, ticket, GetLastError());
            return false;
         }
         return true;
      }

      bool updateSnapshot() {
         if (!select()) {
            return false;
         }

         positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         volume = PositionGetDouble(POSITION_VOLUME);
         openTime = (datetime)PositionGetInteger(POSITION_TIME);

         string posSymbol = "";
         if (!PositionGetString(POSITION_SYMBOL, posSymbol)) {
            PrintFormat("%s: PositionGetString failed. Error %d", __FUNCTION__, GetLastError());
            return false;
         }
         symbol = posSymbol;
         return true;
      }

   public:
      Order() {
         ZeroMemory(request);
         ZeroMemory(result);
         ticket = 0;
         positionType = POSITION_TYPE_BUY;
         openPrice = 0.0;
         volume = 0.0;
         openTime = (datetime)0;
         symbol = "";
      }

      bool loadFromPosition(ulong positionTicket) {
         ticket = positionTicket;
         return updateSnapshot();
      }

      ulong open(ENUM_ORDER_TYPE type, uchar numberOfOrder) {
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

         ticket = (result.order != 0) ? result.order : result.deal;
         if (!updateSnapshot()) {
            Print(__FUNCTION__, ": warning: unable to refresh position data for ticket ", ticket);
         }
         return ticket;
      }

      double profit() {
         if (!select()) {
            return 0.0;
         }
         double total = PositionGetDouble(POSITION_PROFIT);
         total += PositionGetDouble(POSITION_SWAP);
         total += PositionGetDouble(POSITION_COMMISSION);
         return total;
      }

      ulong getTicket() const {return ticket;}
      ENUM_POSITION_TYPE getPositionType() const {return positionType;}
      double getOpenPrice() const {return openPrice;}
      double getVolume() const {return volume;}
      datetime getOpenTime() const {return openTime;}
      string getSymbol() const {return symbol;}
};

class OrderChain {
   private:
      Order *orders[];
      uint count;
      uint amount[2];
      double nextBuy;
      double nextSell;
      double continuationDistance;
      bool sellTrend;

      void clearOrders() {
         int size = ArraySize(orders);
         for (int i = 0; i < size; ++i) {
            if (CheckPointer(orders[i]) == POINTER_DYNAMIC) {
               delete orders[i];
            }
         }
         ArrayResize(orders, 0);
         count = 0;
      }

      void resetTargets() {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         nextBuy = ask + StartDistance * _Point;
         nextSell = bid - StartDistance * _Point;
      }

      void sortByOpenTime() {
         int size = ArraySize(orders);
         for (int i = 1; i < size; ++i) {
            Order *current = orders[i];
            datetime currentTime = current.getOpenTime();
            int j = i - 1;
            while (j >= 0 && orders[j].getOpenTime() > currentTime) {
               orders[j + 1] = orders[j];
               j--;
            }
            orders[j + 1] = current;
         }
      }

      void addOrder(Order *newOrder) {
         int newSize = ArraySize(orders) + 1;
         ArrayResize(orders, newSize);
         orders[newSize - 1] = newOrder;
         count = (uint)newSize;
      }

      void rebuildState() {
         resetTargets();
         amount[CHAIN_BUY] = 0;
         amount[CHAIN_SELL] = 0;

         int size = ArraySize(orders);
         count = (uint)size;
         if (size == 0) {
            sellTrend = false;
            return;
         }

         for (int i = 0; i < size; ++i) {
            if (CheckPointer(orders[i]) != POINTER_DYNAMIC) {
               continue;
            }
            ENUM_POSITION_TYPE type = orders[i].getPositionType();
            if (type == POSITION_TYPE_BUY) {
               amount[CHAIN_BUY]++;
               nextBuy = orders[i].getOpenPrice() + continuationDistance;
            } else if (type == POSITION_TYPE_SELL) {
               amount[CHAIN_SELL]++;
               nextSell = orders[i].getOpenPrice() - continuationDistance;
            }
         }

         if (CheckPointer(orders[size - 1]) == POINTER_DYNAMIC) {
            sellTrend = (orders[size - 1].getPositionType() == POSITION_TYPE_SELL);
         } else {
            sellTrend = false;
         }
      }

   public:
      OrderChain() {
         count = 0;
         amount[CHAIN_BUY] = 0;
         amount[CHAIN_SELL] = 0;
         nextBuy = 0.0;
         nextSell = 0.0;
         continuationDistance = 0.0;
         sellTrend = false;
      }

      ~OrderChain() {
         clearOrders();
      }

      void initialize() {
         synchronize();
      }

      void synchronize() {
         continuationDistance = ContinueDistance * _Point;
         clearOrders();

         int total = PositionsTotal();
         for (int index = total - 1; index >= 0; --index) {
            ResetLastError();
            ulong selectedTicket = PositionGetTicket(index);
            if (selectedTicket == 0) {
               int err = GetLastError();
               PrintFormat("%s: PositionGetTicket(%d) failed. Error %d", __FUNCTION__, index, err);
               continue;
            }

            ulong positionMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
            if (positionMagic != Magic) {
               continue;
            }

            string positionSymbol = "";
            if (!PositionGetString(POSITION_SYMBOL, positionSymbol)) {
               PrintFormat("%s: PositionGetString failed. Error %d", __FUNCTION__, GetLastError());
               continue;
            }

            if (positionSymbol != _Symbol) {
               continue;
            }

            Order *existing = new Order();
            if (!existing.loadFromPosition(selectedTicket)) {
               delete existing;
               continue;
            }

            addOrder(existing);
         }

         if (count > 1) {
            sortByOpenTime();
         }

         rebuildState();
      }

      ENUM_ORDER_TYPE evaluate(double bid, double ask) {
         if (count == 0) {
            if (bid <= nextSell) {
               return ORDER_TYPE_SELL;
            }
            if (ask >= nextBuy) {
               return ORDER_TYPE_BUY;
            }
            return (ENUM_ORDER_TYPE)-1;
         }

         if (bid <= nextSell && (!sellTrend || amount[CHAIN_BUY] == amount[CHAIN_SELL])) {
            return ORDER_TYPE_SELL;
         }

         if (ask >= nextBuy && (sellTrend || amount[CHAIN_BUY] == amount[CHAIN_SELL])) {
            return ORDER_TYPE_BUY;
         }

         return (ENUM_ORDER_TYPE)-1;
      }

      uchar nextOrderNumber(ENUM_ORDER_TYPE type) const {
         if (type == ORDER_TYPE_SELL) {
            return (uchar)(amount[CHAIN_SELL] + 1);
         }
         return (uchar)(amount[CHAIN_BUY] + 1);
      }

      bool openOrder(ENUM_ORDER_TYPE type) {
         Order *newOrder = new Order();
         uchar orderNumber = nextOrderNumber(type);
         ulong ticket = newOrder.open(type, orderNumber);
         if (ticket == 0) {
            delete newOrder;
            return false;
         }

         addOrder(newOrder);
         if (count > 1) {
            sortByOpenTime();
         }
         rebuildState();
         return true;
      }

      uint getCount() const {return count;}

      double totalProfit() {
         double total = 0.0;
         int size = ArraySize(orders);
         for (int i = 0; i < size; ++i) {
            if (CheckPointer(orders[i]) != POINTER_DYNAMIC) {
               continue;
            }
            total += orders[i].profit();
         }
         return total;
      }

      double getNextBuyLevel() const {return nextBuy;}
      double getNextSellLevel() const {return nextSell;}
};

OrderChain chain;

int OnInit() {
   chain.initialize();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
}

void OnTick() {
   price tick;
   tick.bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   tick.ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   chain.synchronize();

   ENUM_ORDER_TYPE typeToOpen = chain.evaluate(tick.bid, tick.ask);
   bool canOpenMore = (MaxOrders <= 0) || (chain.getCount() < (uint)MaxOrders);
   if ((typeToOpen == ORDER_TYPE_BUY || typeToOpen == ORDER_TYPE_SELL) && canOpenMore) {
      if (chain.openOrder(typeToOpen)) {
         chain.synchronize();
      }
   }

   double chainProfit = chain.totalProfit();

   Comment("Bid: ", tick.bid, "\n",
           "Ask: ", tick.ask, "\n",
           "Chain profit: ", DoubleToString(chainProfit, 2), "\n",
           "Next buy >= ", DoubleToString(chain.getNextBuyLevel(), _Digits), "\n",
           "Next sell <= ", DoubleToString(chain.getNextSellLevel(), _Digits));
}
