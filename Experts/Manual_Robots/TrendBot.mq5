#include <stderror.mqh>
#include <stdlib.mqh>
#property strict
#property script_show_inputs

extern double Lot = 0; 
extern double LotP = 10;
extern double MultiLot = 2;
extern int StartTrail = 0;
extern int FirstTrail = 2;
extern int StepTrail = 2;
extern int Trail = 20;
extern int Distanse_1 = 50;
extern int Distanse_2 = 200;
extern int MaxOrder = 3;
extern int MaxLossP = 20;
extern int Magic = 111;
extern int Slippage = 3;

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

class TrailControll : public OrdersChain {
    private:
        bool trendSell;
        double trail;
        double startTrail;
        double firstTrail;
        double slPrise;
        double extremePrise;
        TrailControll *sl;

    public: 
        TrailControll () {
            trail = Trail * Point;
            startTrail = StartTrail * Point;
            firstTrail = FirstTrail * Point;
        }

        void slLineCreate (bool writen = false) {
            HLine *hLine = new HLine("SL", writen);
            sl = hLine;
        }

        void writeSl(bool type, double prise) {
            trendSell = type;
            slPrise = prise;
            slLineCreate(true);
        }

        void checkStartTrail(bool type, double zeroPrise) {
            trendSell = type;
            
            if (trendSell) {
                if (Ask <= zeroPrise - startTrail) {
                    slPrise = Ask + firstTrail;
                    extremePrise = Ask;
                }
            } else {
                if (Bid >= zeroPrise + startTrail) {
                    slPrise = Bid - firstTrail;
                    extremePrise = Bid;
                }
            }

            if (slPrise) {
                slLineCreate();
                sl.HLineMove(slPrise);
            }
        }

        double getDeltaSl(double deltaEx) {
            int deltaExPips = int(deltaEx / Point);
            int deltaSlPips = int(deltaExPips / StepTrail);
            return deltaSlPips * Point;
        }

        void moveSl(double newSl) {
            if (newSl == slPrise) return;
            slPrise = newSl;
            sl.HLineMove(slPrise);
        }

        void updateSl_Sell () {
            double newSlPrise = 0;
            
            if (Ask < slPrise - trail) {
                extremePrise = Ask;
                newSlPrise = extremePrise + trail;
            }
            else if (Ask < extremePrise - StepTrail * Point) {
                double deltaSl = getDeltaSl(extremePrise - Ask);
                newSlPrise = slPrise - deltaSl;
                extremePrise = extremePrise - deltaSl * StepTrail;
            }

            if (newSlPrise) moveSl(newSlPrise);
        }

        void updateSl_Buy () {
            double newSlPrise = 0;
            
            if (Bid > slPrise + trail) {
                extremePrise = Bid;
                newSlPrise = extremePrise - trail;
            }
            else if (Bid > extremePrise + StepTrail * Point) {
                double deltaSl = getDeltaSl(Bid - extremePrise);
                newSlPrise = slPrise + deltaSl;
                extremePrise = extremePrise + deltaSl * StepTrail;
            }

            if (newSlPrise) moveSl(newSlPrise);
        }

        bool isExtremeUpdate () {
            if (trendSell) {
                if (Ask < extremePrise || !extremePrise) {
                    updateSl_Sell();
                    return true;
                }
            } else {
                if (Bid > extremePrise) {
                    updateSl_Buy();
                    return true;
                }
            }

            return false;
        }

        bool isTachTrail () {
            if (isExtremeUpdate()) return false;

            if (trendSell) {
                if (Ask >= slPrise && slPrise) return true;
            } else {
                if (Bid <= slPrise) return true;
            }

            return false;
        }

        double getSlPrise () {return slPrise;}
        virtual void HLineMove(double inpPrice) {}

        ~TrailControll () {
            if (CheckPointer(sl) == POINTER_DYNAMIC) delete sl;
        }
};

class Order : public OrdersChain {
    private:  
        int ticket;
        int type;
        double lot;
        double prise;
        double stopLoss;
        double tackeProfit;

    public:
        int getTicket() {return ticket;}
        int getType() {return type;}
        double getLot() {return lot;}
        double getPrise() {return prise;}

        Order() {}
        Order(int inpTicket, int inpType, double inpLot, double inpPrise) {
            ticket = inpTicket;
            type = inpType;
            lot = inpLot;
            prise = inpPrise;
        }

        void select() {
            if (!OrderSelect(ticket, SELECT_BY_TICKET)) {
                Print("Can't select order in the order class. Error: ", ErrorDescription(GetLastError()));
                ExpertRemove();
            };
        }

        double getProfit() {
            select(); 
            return OrderProfit()+ OrderSwap()+ OrderCommission();
        } 

        void lotCalculation(int numberOfOrder) {
            lot = firstLot;
            
            double marginForOneLot = MarketInfo(symbol, MODE_MARGINREQUIRED);
            double freeMargin = AccountFreeMargin();

            if (MultiLot != 1)  {
                for (int i=1; i<numberOfOrder; i++) lot*= MultiLot;
            }
            
            if (marginForOneLot * lot > freeMargin) {
                Print("Can't open order ", lot, " lots. It needed ", marginForOneLot * lot, "$ free margin. But Account has only ", freeMargin, "$ free margin");
                ExpertRemove();
            }
        }

        bool open(int orderType, int numOfOrder) {
            type = orderType;
            lotCalculation(numOfOrder);

            ticket = OrderSend(symbol, type, lot, type?Bid:Ask, slippage, NULL, NULL, NULL, magic);
            if (ticket == 0) {
                Print("Can't open order. Error: ", ErrorDescription(GetLastError()));
                if (IsTesting()) ExpertRemove();
                return false;
            }
            
            select();
            prise = OrderOpenPrice();
            return true;
        }

        ~Order() {
            if (!OrderClose(ticket, lot, type?Ask:Bid, slippage)) {
                Print("Can't close order. Error: ", ErrorDescription(GetLastError()));
                if (IsTesting()) ExpertRemove();
            }
        }

};

class HLine : public TrailControll {
    protected:  
            long chart_ID;
            string name; 
            int sub_window; 
            color clr; 
            ENUM_LINE_STYLE style; 
            int width; 
            bool back; 
            bool selection;
            bool hidden; 
            long z_order;
            bool writen;

    public:
        HLine (string inpName, bool inpWriten = false) {
            name = inpName;      // имя линии 
            writen = inpWriten;  // Уже нарисованна

            chart_ID = ChartID();          // ID графика 
            sub_window = 0;         // номер подокна 
            clr = clrRed;       // цвет линии 
            style = STYLE_DASHDOT; // стиль линии 
            width = 1;              // толщина линии 
            back = false;          // на заднем плане 
            selection = false;     // выделить для перемещений 
            hidden = true;         // скрыт в списке объектов 
            z_order = 0;           //приоритет на получение события нажатия мыши на графике
        }

        bool HLineCreate(double inpPrice) { 
            ResetLastError(); 
            if(!ObjectCreate(chart_ID, name, OBJ_HLINE, sub_window, 0, inpPrice)) {
                Print(__FUNCTION__, ": не удалось создать горизонтальную линию! Ошибка: ", ErrorDescription(GetLastError())); 
                return false;
            }

            ObjectSetInteger(chart_ID,name,OBJPROP_COLOR,clr);
            ObjectSetInteger(chart_ID,name,OBJPROP_STYLE,style);
            ObjectSetInteger(chart_ID,name,OBJPROP_WIDTH,width);
            ObjectSetInteger(chart_ID,name,OBJPROP_BACK,back);
            ObjectSetInteger(chart_ID,name,OBJPROP_SELECTABLE,selection); 
            ObjectSetInteger(chart_ID,name,OBJPROP_SELECTED,selection); 
            ObjectSetInteger(chart_ID,name,OBJPROP_HIDDEN,hidden); 
            ObjectSetInteger(chart_ID,name,OBJPROP_ZORDER,z_order); 
            return true;
        }

        void HLineMove(double inpPrice) { 
            if (!writen) {
                writen = HLineCreate(inpPrice);
                return;
            }

            ResetLastError(); 
            if(!ObjectMove(chart_ID, name, 0, 0, inpPrice))
                Print(__FUNCTION__, ": не удалось переместить горизонтальную линию! Ошибка: ", ErrorDescription(GetLastError())); 
        } 

        void HLineDelete() { 
            ResetLastError(); 
            if(!ObjectDelete(chart_ID, name))
                Print(__FUNCTION__, ": не удалось удалить горизонтальную линию! Код ошибки = ", ErrorDescription(GetLastError())); 
        } 

        ~HLine() {
            if (writen) {
                ResetLastError(); 
                if(!ObjectDelete(chart_ID, name))
                    Print(__FUNCTION__, ": не удалось удалить горизонтальную линию! Код ошибки = ",GetLastError());
            }
        }
};

OrdersChain *chain;

int OnInit() {
    chain = new OrdersChain();

    datetime lastOrderTime = 0;
    for (int i = OrdersTotal()-1; i>=0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS)) {
            Print("Can't select order. Error: ", ErrorDescription(GetLastError()));
            ExpertRemove();
        }

        bool lastOrder = false;
        if (OrderMagicNumber() == Magic) {
            if(OrderOpenTime() > lastOrderTime) {
                lastOrderTime = OrderOpenTime();
                lastOrder  = true;
            }
            chain.addOrder(OrderTicket(), OrderType(), OrderLots(), OrderOpenPrice(), lastOrder);
        }
    }

    chain.checkNexts();

    double slPrise;
    if (ObjectGetDouble(ChartID(), "SL", OBJPROP_PRICE, 0, slPrise)) chain.writeStopLoss(slPrise);
    else Print("Don't found 'SL' line: ", ErrorDescription(GetLastError()));

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {

}

void OnTick() {
    int codeOrder = chain.evaluateOrderOpening(); // 1 for Buy, 2 for Sell
    
    if (codeOrder && chain.getCount() < MaxOrder) {
        chain.openOrder(codeOrder - 1);
        codeOrder = 0;
    }

    double profit = chain.getChainProfit();

    int closeRison = 0;
    if (codeOrder && chain.getCount() == MaxOrder) closeRison = 1;
    else if ((chain.isStopLoss())) closeRison = 2;
    else if (profit * -1 >= AccountBalance() * (NormalizeDouble(MaxLossP, 2)/100)) closeRison = 3;

    if (closeRison) {
        Print("profit: ", profit, " || reson: ", closeRison);
        //if (profit < 0) ExpertRemove();
        delete chain;
        chain = new OrdersChain();
    }

    Comment("Profit: ", NormalizeDouble(profit, 2));
}