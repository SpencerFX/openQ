//====================================================================
// Directory: modules/analytics/report/cep.q
//
// About:
// The "report" module: a live, always-refreshing "Desk Risk & TCA"
// view combining spread/markout/primefinance (see README's "Desk Risk
// & TCA" section and deskRisk.q, its own sibling file, which does the
// actual computation - this file is only glue). On a timer, it pulls
// the raw tables each module holds, recomputes the report fresh via
// deskRisk.q's pure batch functions, and stores the result in
// .report.latest for any client to query - deliberately NOT via
// .oq.cep.connectSource/.u.sub (there's no single upstream tp for a
// cross-module report, and the computation is inherently a point-in-time
// batch recompute anyway, not an incremental one). -srcaddr still points
// at primefinance's CEP so .oq.cep.init's unconditional connect succeeds
// cleanly (no handlers are registered on it, so nothing happens with
// what it relays - a live but unused subscription is harmless and avoids
// the reconnect-error noise a deliberately-unreachable address would
// cause every 30s).
//
// spread/markout's RDBs only ever hold whatever's arrived since the last
// idb pivot (core/idb.q's active/standby harvest cycle flushes the
// harvested side's memory once its data is durably segmented - see
// core/rdb.q/core/idb.q) - querying the RDB alone would make this
// report's numbers flicker to nothing every time idb's -checkpointfreq
// pivots (2 minutes here), found the hard way while building this.
// .report.readFull merges whatever's still live on the (currently
// active) RDB with everything already durably harvested into this
// trading day's segments (via .oq.save.readSegments, the same function
// core/idb.q's own EOD and eod.q's standalone one both already share),
// so the report is complete regardless of where in the pivot cycle it's
// called. primefinance's
// .prime.* tables don't have this problem - they're accumulated directly
// in that CEP's own memory by its handlers, never flushed - so they're
// read straight off primefinance's CEP with no merge needed.
//
// This module has no schema of its own (see cfg_proc/modules/report/
// cep.json - no "schema" key at all, which core/initFromCfg.q treats as
// "load nothing", perfectly safe here since core/tp.q's .u.tick handles
// zero output tables as a valid case) and no tp/rdb/hdb/idb/eod of its
// own either - it's a single lightweight process, the same shape
// core/gw.q's gateway is.
//====================================================================

system "l ../modules/analytics/report/deskRisk.q";

// NOTE: these are each module's rdb *instance 1* port specifically -
// under the active/standby pair (see core/rdb.q's header), whichever of
// port1/port2 is actually active at any given moment can be EITHER one,
// and this always queries port1. When instance 2 is the one currently
// active, .report.readFull's "liveRows" for that module comes back
// empty (nothing yet durably segmented since the last pivot just looks
// momentarily thin, same as the old flicker this function was built to
// avoid) - a real fix needs this to ask each pair which side is active
// (or query both and merge) rather than assuming port1; not done here.
.report.spreadAddr:":localhost:5056";
.report.markoutAddr:":localhost:5031";
.report.primeAddr:":localhost:5074";

// idb's segment root for each module - core-relative, same as every
// cfg_proc/modules/<name>/idb.json's own "idbroot" (see core/idb.q's
// header - a growing set of 0,1,2,... segments per trading day, not a
// single dated directory)
.report.spreadIdbRoot:`:../examples/data/spread/idb_staging;
.report.markoutIdbRoot:`:../examples/data/markout/idb_staging;

//@func   | .report.deenum
//@param  | t | 98 | any table
//@return | 98 | same table with every enumerated (20-76h) column cast
//              back to plain symbols (11h)
//@desc
//Resolving on-disk symbol columns against a loaded `sym` domain (see
//.report.readFull below) gets the right VALUES back, but the columns
//stay genuinely enumerated (type 20h, `sym$`AAPL, not 11h) - not the
//same type as a plain symbol column fetched live over IPC. Left
//unfixed, lj-ing a plain-symbol key (e.g. primefinance's live sym
//column) against an enumerated one throws 'type. value on an enum
//column resolves it back to a plain symbol vector.
//@desc
.report.deenum:{[t] flip (cols t)!{$[(type x) within 20 76h;value x;x]} each value flip t};

//@func   | .report.readFull
//@param  | liveRows | 98 | rows still on the (queried) RDB instance
//@param  | tabName  | -11 | table name
//@param  | idbRoot  | -11 | that module's idb segment root
//@param  | emptyTab | 98 | zero-row table of the right shape, used if
//                    there's nothing segmented yet today (e.g. a
//                    freshly-started module) - .oq.save.readSegments'
//                    own fallback for that case needs tabName to already
//                    be a defined global, which isn't true in this
//                    process, so the whole call is wrapped instead
//@return | 98 | every segment harvested so far today, plus whatever's still live
//@desc
.report.readFull:{[liveRows;tabName;idbRoot;emptyTab]
  / .oq.save.saveTable enumerates symbol columns against a `sym` domain
  / file stored right in idbRoot (.Q.en's doing) - reading the raw
  / column back without that domain loaded first gives back the raw
  / enumerated ints, not resolved symbols. The file itself doesn't exist
  / until the first segment has ever been written, so this load is
  / protected too - if it's missing there's nothing segmented to read
  / either, and the empty-table fallback below covers that.
  @[{`sym set get x};`$(string idbRoot),"/sym";{[e]}];
  / @[f;x;errFn] is protected *unary* apply (f x, one arg) - it curries
  / a 2-param function like readSegments into an unevaluated projection
  / instead of calling it. .[f;argList;errFn] is the n-ary form that
  / actually splats argList as separate positional args.
  chk:.[.oq.save.readSegments;(tabName;idbRoot);{[e;t]0#t}[;emptyTab]];
  (.report.deenum chk),liveRows
 };

.report.emptySpreadQuote:([] timestamp:`timestamp$(); sym:`symbol$(); aggression:`symbol$(); marketStatus:`symbol$(); weight:`float$(); refSprd:`float$(); baseSprd:`float$(); clientSprd:`float$(); volSprd:`float$(); smoothSprd:`float$(); fallbackSprd:`float$(); alphaSprd:`float$());
.report.emptyTrade:([] timestamp:`timestamp$(); sym:`symbol$(); tradeID:`long$(); price:`float$());
.report.emptyOrder:([] timestamp:`timestamp$(); sym:`symbol$(); orderID:`long$(); price:`float$(); side:`symbol$());
.report.emptyRate:([] timestamp:`timestamp$(); sym:`symbol$(); mid:`float$());

//@func   | .report.refresh
//@desc
//Pulls the raw wire/state tables each module already holds (spread/
//markout merged with their checkpointed history via .report.readFull;
//primefinance read straight off its CEP), recomputes the desk-risk
//report from scratch via .deskRisk.report, and stores it. Opens and
//closes its own handles each run rather than holding them open
//permanently - simplicity over connection reuse, since a refresh only
//runs once a minute.
//@desc
.report.refresh:{[]
  sh:hopen `$.report.spreadAddr;
  mh:hopen `$.report.markoutAddr;
  ph:hopen `$.report.primeAddr;
  quotes:.report.readFull[sh "select from spreadQuote";`spreadQuote;.report.spreadIdbRoot;.report.emptySpreadQuote];
  trades:.report.readFull[mh "select from trade";`trade;.report.markoutIdbRoot;.report.emptyTrade];
  orders:.report.readFull[mh "select from order";`order;.report.markoutIdbRoot;.report.emptyOrder];
  rate:.report.readFull[mh "select from rate";`rate;.report.markoutIdbRoot;.report.emptyRate];
  d:`quotes`trades`orders`rate`positions`locates`inventory`reservations`now!(
    quotes;
    trades;
    orders;
    rate;
    ph "select from .prime.positions";
    ph "select from .prime.locates";
    ph "select from .prime.inventory";
    ph "select from .prime.reservations";
    .z.p);
  hclose sh;
  hclose mh;
  hclose ph;
  .report.latest:.deskRisk.report[d];
  .util.log.ex[`INFO;`.report.refresh]"Desk risk report refreshed: ",(string count .report.latest)," symbol(s)";
  };

//@func   | .report.refreshSafe
//@desc
//Timer callback wrapper: one module being down shouldn't crash the
//report's own refresh cycle or stop future refreshes from being tried.
//@desc
.report.refreshSafe:{[] @[.report.refresh;`;{[e].util.log.ex[`ERROR;`.report.refreshSafe]"Refresh failed: ",e}]};

.report.latest:([] sym:`symbol$(); spreadCostBp:`float$(); markoutBp:`float$();
  impactBp:`float$(); financingFeeBp:`float$(); shortQty:`long$();
  locatedQty:`long$(); coverage:`float$(); bucket:`symbol$());

.report.info.timer.refresh:.util.timer.add[.z.p;0Wp;0D00:01:00;`.report.refreshSafe;`REL;"desk risk report refresh"];

// run once immediately at startup too, so there's real data without
// waiting a full minute for the first timer tick
.report.refreshSafe[];
