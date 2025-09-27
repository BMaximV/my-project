//+------------------------------------------------------------------+
//|                                                  TrendBot_v2.mq5 |
//|                                                    Maxim Bulygin |
//|                                                 https://mql5.com |
//| 09.05.2025 - Initial release                                     |
//+------------------------------------------------------------------+
#property copyright "Maxim Bulygin"
#property link      "https://mql5.com"
#property version   "1.00"

input double Lot = 0;
input double LotP = 10;
input double MultiLot = 2;
input int StartTrail = 0;
input int FirstTrail = 2;
input int StepTrail = 2;
input int Trail = 20;
input int Distanse_1 = 50;
input int Distanse_2 = 200;
input int MaxOrder = 3;
input int MaxLossP = 20;
input int Magic = 111;
input int Slippage = 3;

class OrdersChain {
   private:
      int count;
      int amount[2];
      double nextBuy;
      double nextSell;
      OrdersChain *order[];
      double distanse_2;
      bool sellTrand;
      double profit;
      OrdersChain *sl;

   protected:  
      double firstLot;
      int slippage;
      int magic;
      string symbol;
      double oneTickCost;

   public:
      OrdersChain() {
         slippage = Slippage;
         magic = Magic;
         symbol = Symbol();
         firstLot = (Lot==0)?NormalizeDouble(AccountBalance()*(LotP/100)/100/MarketInfo(symbol, MODE_MARGINREQUIRED), 2):Lot; // To Do 0.1 
         double minLot = MarketInfo(symbol, MODE_MINLOT);
         if (firstLot < minLot) firstLot = minLot;
         oneTickCost = MarketInfo(symbol, MODE_TICKVALUE);

         nextBuy = Ask + Distanse_1 * Point;
         nextSell = Bid - Distanse_1 * Point;
         distanse_2 = Distanse_2 * Point;
      }

      void updateNextOrderPrise(int type) {
         if (type) {
               nextSell = order[count-1].getPrise() - distanse_2;
               sellTrand = true;
         }
         else {
               nextBuy = order[count-1].getPrise() + distanse_2;
               sellTrand = false;
         }
      }

      void updateOrdersVars(OrdersChain *newOrder, int type, bool lastOrder = true) {
         amount[type]++;
         count = ArrayResize(order, count + 1) ;
         if (lastOrder) {
               order[count-1] = newOrder;
               updateNextOrderPrise(type);
         }
         else {
               order[count-1] = order[count-2];
               order[count-2] = newOrder;
         }
      }

      void openOrder(int type) {
         Order *newOrder = new Order();
         if (!newOrder.open(type, amount[type] + 1)) {
               delete newOrder;
               return;
         }

         updateOrdersVars(newOrder, type);
      }

      void addOrder(int ticket, int type, double lot, double prise, bool lastOrder) {
         Order *newOrder = new Order(ticket, type, lot, prise);

         updateOrdersVars(newOrder, type, lastOrder);

         if (!firstLot || firstLot > lot) firstLot = lot;
      }

      void checkNexts() {
         if (amount[1] == 1) nextBuy = order[count-1].getPrise() + Distanse_1 * Point * 2;
         if (amount[0] == 1) nextSell = order[count-1].getPrise() - Distanse_1 * Point * 2;
      }

      int evaluateOrderOpening() {  // return 1 for Buy and 2 for Sell
         int needOrder = 0;
         if (Bid <= nextSell && (!sellTrand || amount[0] == amount[1])) needOrder = 2;
         else if (Ask >= nextBuy && (sellTrand || count == 0 || amount[0] == amount[1])) needOrder = 1;
         return needOrder;
      }

      void calcProfit() {
         profit = 0;
         for(int i=0; i<count; i++) {
               profit+= order[i].getProfit();
         }
      }

      double getChainProfit() {
         calcProfit();
         return profit;
      }

      double getZeroPrise() {
         double prise;
         double distance = profit/oneTickCost/order[count-1].getLot();
         if (TimeCurrent() < D'20226.03.06') distance = distance * Point;
         distance = NormalizeDouble(distance, Digits);
         if (sellTrand) prise = Ask + distance;
         else prise = Bid - distance;

         return prise;
      }

      void stopLossCreater() {
         TrailControll *stopLoss = new TrailControll();
         sl = stopLoss;
      }

      bool isStopLoss() {
         if (!count) return false;

         if (CheckPointer(sl) != POINTER_DYNAMIC) stopLossCreater();
         if (!sl.getSlPrise()) {
               if (amount[0] != amount[1]) {
                  sl.checkStartTrail(sellTrand, getZeroPrise());
               }
               return false;
         }
         return sl.isTachTrail();
      }

      void writeStopLoss(double prise) {
         stopLossCreater();
         sl.writeSl(sellTrand, prise);
      }

      int getCount() {return count;}
      virtual double getPrise() {return 0;}
      virtual double getProfit() {return 0;}
      virtual double getLot() {return 0;}
      virtual double getSlPrise() {return 0;}
      virtual void checkStartTrail(bool type, double zeroPrise) {}
      virtual void writeSl(bool type, double prise) {}
      virtual bool isTachTrail() {return false;}
      virtual int getType() {return 0;}
      virtual int getTicket() {return 0;}

      ~OrdersChain() {
         for(int i=0; i<count; i++)
               if(CheckPointer(order[i]) == POINTER_DYNAMIC)
                  delete order[i]; 
         if (CheckPointer(sl) == POINTER_DYNAMIC) delete sl;
      }
};


int OnInit() {

   return(INIT_SUCCEEDED);
   }

void OnDeinit(const int reason) {
   
   }

void OnTick() {

   }

