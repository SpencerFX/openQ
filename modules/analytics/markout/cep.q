//====================================================================
// Directory: modules/analytics/markout/cep.q
//
// About:
// Everything else in this module - tp, rdb, idb, hdb - is the exact same
// core/ code the default pipeline uses, pointed at schemas/schema_markout.q
// instead of the default schema; none of it needed custom code, since
// tp.q/rdb.q/idb.q/hdb.q are already schema-agnostic. This file is the
// one genuinely custom piece: loading markOutImpact.q (its own sibling
// file, the "in addition to core" import) and wiring its real-time
// entrypoints to the incoming trade/order/rate streams, plus the
// periodic sweep timer the library's own docs recommend running
// alongside them. rdb (an active/standby pair - see core/rdb.q's header)
// points its -tpaddr at this CEP rather than at the tp directly (the
// default process flow: fh -> tp -> cep -> rdb -> eod -> hdb, plus idb
// pivoting the rdb pair on its own timer rather than subscribing
// anywhere - see core/idb.q's header - see the README's "Modules"
// section), so alongside the analytics this file also relays every row
// of every table unchanged via .u.upd - otherwise nothing downstream of
// the CEP would ever see any data.
//
// Namespaces:
//   .markoutMod.*       - client DEAL markout: how the market mid moves
//                       relative to a trade's execution rate, at a
//                       grid of offsets from -10 minutes to +10 minutes,
//                       and the relay
//====================================================================
system "l ../modules/analytics/markout/markOutImpact.q";

//@func   | .markoutMod.onTrade
//@param  | t | -11 | Table name (always `trade)
//@param  | x | 98  | Incoming batch of `trade rows
//@desc
//Registers every incoming trade with .markout.onTrade (client deal markout)
//@desc
.markoutMod.onTrade:{[t;x]
 {[row] .markout.onTrade `tradeID`tradeTime`tradeRate`sym!(row[`tradeID];row[`timestamp];row[`price];row[`sym])} each 0!x;
 };

//@func   | .markoutMod.onOrder
//@param  | t | -11 | Table name (always `order)
//@param  | x | 98  | Incoming batch of `order rows
//@desc
//Registers every incoming order with .impact.onOrder (order/execution impact)
//@desc
.markoutMod.onOrder:{[t;x]
 {[row] .impact.onOrder `orderID`orderTime`orderRate`sym`side!(row[`orderID];row[`timestamp];row[`price];row[`sym];row[`side])} each 0!x;
 };

//@func   | .markoutMod.onRate
//@param  | t | -11 | Table name (always `rate)
//@param  | x | 98  | Incoming batch of `rate ticks
//@desc
//Feeds every incoming rate tick to both .markout.onRate (completes
//pending trade offsets) and .impact.onBook (completes pending order
//offsets) - both libraries treat this same mid as their reference feed
//@desc
.markoutMod.onRate:{[t;x]
 {[row]
   rt:`sym`time`mid!(row[`sym];row[`timestamp];row[`mid]);
   .markout.onRate rt;
   .impact.onBook rt;
  } each 0!x;
 };

//How often .markoutMod.sweep fires - frequent relative to both
//libraries' pendingTTL (.markout.pendingTTL 5min, .impact.pendingTTL 2min)
.markoutMod.sweepFreq:0D00:01:00;

//@func   | .markoutMod.sweep
//@desc
//Timer callback: evicts pending trade/order rows a dead symbol or a gap
//in the rate feed would otherwise leak forever - both libraries'
//sweepPending docs recommend calling this periodically off a timer
//@desc
.markoutMod.sweep:{[]
 now:.z.p;
 .markout.sweepPending now;
 .impact.sweepPending now;
 };

//@func   | .markoutMod.relay
//@param  | t | -11 | Table name (`trade, `order, or `rate)
//@param  | x | 98  | Incoming batch of rows for t
//@desc
//Republishes an incoming batch unchanged - logs it to this CEP's own
//tplog and publishes it to its subscribers (rdb - idb doesn't subscribe to
//anything, see core/idb.q's header),
//same as a real tp would. Registered on every schema table, alongside
//(not instead of) the analytics handlers above.
//@desc
.markoutMod.relay:{[t;x]
 .u.upd[t;x];
 };

// TEMPORARY (2026-09-05 ops incident, see openQ README/memory): NOT
// registering onTrade/onOrder/onRate here for this one restart - .markout.pending
// grows unbounded during a fast-forward replay of a multi-day backlog (eviction
// is a real-wall-clock timer, .markoutMod.sweep, which barely fires while
// replay races through days of message-time in seconds), and every rate tick
// full-table-scans .markout.pending - a runaway CPU blowup once caught, not
// caught before because the pre-existing .oq.cep.dispatch type bug made every
// replayed row fail instantly. Re-registered by hand over IPC once this
// restart's backlog replay is done and caught up to live - see the relevant
// memory entry for the restore-to-normal command. Only .markoutMod.relay is
// registered below, so rdb/idb/hdb still get the full backlog untouched.
{.oq.cep.addHandler[x;.markoutMod.relay;`$"markoutRelay",string x]} each .oq.schema.tables[];
.markoutMod.info.timer.sweep:.util.timer.add[.z.p+.markoutMod.sweepFreq;0Wp;.markoutMod.sweepFreq;`.markoutMod.sweep;`REL;"markout/impact pending sweep"];
