//====================================================================
// 01_publish_and_query.q
//
// The most basic openQ walkthrough there is: publish a few ticks onto
// the tickerplant, then read them back out through the gateway - the
// same round trip any feed handler + client pair makes, just typed by
// hand instead of automated.
//
// Prerequisite: the default pipeline running (tp/rdb/hdb/gw on
// 5010-5013), e.g.:
//   ./scripts/startStop/startup.sh
//
// Run from the repo root:
//   q examples/scripts/01_publish_and_query.q
//====================================================================

//---------------------------------------------------------------
// 1) Publish: open a handle to the tickerplant and call `upd` - the
//    classic tick.q feed-handler convention every publisher in this
//    repo uses, whether it's q, Python, or a real vendor feed.
//---------------------------------------------------------------
tph:hopen `$":localhost:5010";

n:10;
syms:n?`AAPL`MSFT`GOOG`AMZN;
now:.z.p;

// schemas/schema.q's quote/trade shape - timestamp,sym first, as every
// openQ table requires
quotes:flip `timestamp`sym`bid`ask`bidSize`askSize`source!
  (n#now; syms; 100+n?10.0; 101+n?10.0; n?1000.0; n?1000.0; n#`example);
trades:flip `timestamp`sym`price`size`side`source!
  (n#now; syms; 100+n?10.0; n?500.0; n?`buy`sell; n#`example);

neg[tph] (`upd;`quote;quotes);
neg[tph] (`upd;`trade;trades);
neg[tph][];  // flush the async queue before closing
hclose tph;

-1 "published ",(string n)," quote row(s) and ",(string n)," trade row(s)";

//---------------------------------------------------------------
// 2) Query: a client never talks to the RDB or HDB directly - it asks
//    the gateway, which decides which backend(s) to route to based on
//    the requested time range (see README's "Gateway" section) and
//    joins the results if it needed both. The call is async - fire the
//    request, then block on the same handle for the reply.
//---------------------------------------------------------------
// small pause so the tickerplant's broadcast reaches the RDB before we
// query it - in a real client you'd retry/poll instead of sleeping
system "sleep 1";

gwh:hopen `$":localhost:5013";

// .oq.gw.query[table;cols;sTime;eTime;sym;whereClause] - ` means "no
// filter" for any argument; here we ask for every quote row, all time,
// all symbols
neg[gwh] (`.oq.gw.query;`quote;`;`;`;`;`);
res:gwh[];
hclose gwh;

if[res`error; '"query failed: ",res`data];

-1 "queried back ",(string count res`data)," quote row(s) via the gateway:";
show res`data;

exit 0
