h:hopen `:127.0.0.1:5063;
dt:2026.09.09;
tot:first exec x from h ("{[d] select x:count i from eq_m1_yfinance where date=d}";dt);
dups:first exec x from h ("{[d] select x:sum n>1 from (select n:count i by sym,barTime,exchange from eq_m1_yfinance where date=d)}";dt);
ex:h ("{[d] 0!select c:count i, mn:min barTime, mx:max barTime by exchange from eq_m1_yfinance where date=d}";dt);
-1 "2026.09.09 total rows          : ",string tot;
-1 "dup (sym,barTime,exchange) keys: ",string dups;
show ex;
hclose h; exit 0
