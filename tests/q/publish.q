// tests/publish.q - connects to the tickerplant and publishes sample quote/trade ticks
h:hopen `$":localhost:5010";
n:20;
syms:n?`AAPL`MSFT`GOOG`AMZN;
now:.z.p;
quoteData:flip `timestamp`sym`bid`ask`bidSize`askSize`source!(n#now;syms;100+n?10.0;101+n?10.0;n?1000.0;n?1000.0;n#`sim);
tradeData:flip `timestamp`sym`price`size`side`source!(n#now;syms;100+n?10.0;n?500.0;n?`buy`sell;n#`sim);
neg[h] (`upd;`quote;quoteData);
neg[h] (`upd;`trade;tradeData);
neg[h][];
hclose h;
-1 "published ",(string n)," quote and ",(string n)," trade rows";
exit 0
