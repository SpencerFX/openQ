//====================================================================
// Directory: core/rdb.q
//
// About:
// RDB: subscribes to one or more tickerplants, holds today's ticks in
// memory, replays any log segments it missed while disconnected, and
// releases rows incrementally once save.q confirms they're durably on
// disk - rather than the naive "drop everything at midnight" approach.
//
// Dual-instance / active-standby: a module's rdb.json now carries BOTH
// -port1 and -port2 instead of a single -port (see
// .util.start.resolveInstancePort in core/utils/start.q) - launching the
// same config twice, once with -instance 1 and once with -instance 2,
// gives every module a redundant pair (e.g. rdb0_1/rdb0_2, mon_rdb_1/
// mon_rdb_2), each on its own resolved port and its own gateway-visible
// name. Only ONE of the two ever actually subscribes to the tickerplant
// at a time - instance 1 boots ACTIVE (subscribes normally, exactly like
// a single rdb always has), instance 2 boots STANDBY (comes up, binds
// its port, is queryable, but never subscribes at all, so it's never
// added to the tp's .u.w and never receives a single row - a tickerplant
// has no idea it exists). .oq.rdb.activate[]/.oq.rdb.standby[] flip a
// running instance between the two roles over IPC, driven by
// core/idb.q's repeating pivot-and-harvest cycle (see its header) rather
// than a one-off failover:
//   - .oq.rdb.activate does a plain LIVE subscribe with NO replay - this
//     is the key difference from a brand-new rdb's very first connection
//     (.oq.rdb.connectToTP, which always replays everything on-disk so
//     far). In this repeating design, whatever a standby missed while
//     idle was either already durably harvested into an earlier idb
//     segment, or is still sitting live in the OTHER half of the pair
//     (about to be harvested next cycle) - replaying it here on top of
//     that would duplicate it, not catch it up. A standby genuinely has
//     nothing to catch up on: it starts from a clean slate every time.
//   - .oq.rdb.standby hclose's its tp handle - the tickerplant's own
//     .z.pc cleanup (.u.del[;W] each .u.t, see core/tp.q) removes it
//     from .u.w for free, no explicit unsubscribe call needed.
// Nothing here decides WHEN to pivot on its own - core/idb.q's timer
// does that, on a schedule; there's no health-monitoring/failure-
// detection layer wired in (see core/housekeeping.q for the closest
// thing this repo has to that).
//
// Namespaces:
//   .oq.rdb.*   - tickerplant connect/replay/reconnect, confirmed-durable
//                 row flush, active/standby state, and .init - the full
//                 startup sequence
//====================================================================
.oq.info.rdb.loaded:0b;

//Per-tickerplant connection state
.oq.rdb.tpConns:([address:`symbol$()] handle:`int$(); logFile:`symbol$(); logTime:`timestamp$(); logIndex:`long$(); firstConn:`boolean$(); disconnTime:`timestamp$());

//Whether THIS instance is currently subscribed to (and receiving from)
//its tickerplant - see .oq.rdb.activate/.oq.rdb.standby. Set at .init
//time from -instance (1 -> active, anything else -> standby).
.oq.rdb.active:1b;

//This instance's tickerplant address, remembered so .oq.rdb.activate can
//(re)connect without needing it passed in again
.oq.rdb.tpAddr:`;

//Default insert handler; save.q's flush releases rows once durable elsewhere
upd:insert;

.u.t:`symbol$();

//@func   | .oq.rdb.connectToTP
//@param  | address | -11 | `:host:port of the tickerplant
//@param  | tabs    | 11  | Table(s) to subscribe to, enlist ` for all
//@return | -6 | Handle opened, or 0Ni on failure
//@desc
//Opens a handle to a tickerplant and subscribes to it
//@desc
.oq.rdb.connectToTP:{[address;tabs]
 .util.log.ex[`INFO;`.oq.rdb.connectToTP]"Connecting to ",string address;
 hnum:@[.util.ipc.hopen;(address;5000);{[a;e].util.log.ex[`ERROR;`.oq.rdb.connectToTP]"Failed to connect to ",(string a)," with: ",e;0Ni}[address]];
 `.oq.rdb.tpConns upsert (address;hnum;`;0Np;0Nj;1b;0Wp);
 if[not null hnum;
    info:@[hnum;(`.u.subInfo;first tabs,();`);{[e](();0Nj;`)}];
    .oq.rdb.registerTP[info 1;info 2;hnum]
   ];
 hnum
 };

//@func   | .oq.rdb.registerTP
//@param  | tpLogIndex | -7  | The TP's current .u.j counter at time of subscription
//@param  | tpLogFile  | -11 | The TP's currently open log file
//@param  | hnum       | -6  | Handle to the TP
//@desc
//Records TP log position on (re)connect; on first-ever connection, replays what was missed.
//NOTE: the params are deliberately not named `logFile`/`logIndex` - see the note
//on .oq.rdb.replayMissedTicks about column names shadowing same-named outer variables.
//@desc
.oq.rdb.registerTP:{[tpLogIndex;tpLogFile;hnum]
 .u.t:distinct .u.t,tables`.;
 update logFile:tpLogFile,logIndex:tpLogIndex from `.oq.rdb.tpConns where handle=hnum;
 if[first exec firstConn from .oq.rdb.tpConns where handle=hnum;
    .util.log.ex[`INFO;`.oq.rdb.registerTP]"First connection: replaying missed log segment";
    .oq.rdb.replayMissedTicks[first exec address from .oq.rdb.tpConns where handle=hnum]
   ];
 };

//@func   | .oq.rdb.replayMissedTicks
//@param  | tpAddr | -11 | Tickerplant address this RDB is (re)connecting to
//@desc
//Replays tplog entries from local disk to catch up an RDB that was down/behind.
//Local-disk replay only - a co-located or shared-filesystem tickerplant is assumed;
//a remote-log replay proxy is a natural extension but out of scope here.
//NOTE: the param is deliberately not named `address` - .oq.rdb.tpConns has an
//`address` key column, and exec/where clauses bind column names into scope,
//silently shadowing an outer variable of the same name.
//@desc
.oq.rdb.replayMissedTicks:{[tpAddr]
 tpInfo:exec from .oq.rdb.tpConns where address=tpAddr;
 if[null tpInfo`logFile;.util.log.ex[`WARN;`.oq.rdb.replayMissedTicks]"No log file known for ",string tpAddr;:(::)];
 logDir:`$"/" sv -1_"/" vs string tpInfo`logFile;
 if[not type key logDir;.util.log.ex[`WARN;`.oq.rdb.replayMissedTicks]"Log directory not visible locally: ",string logDir;:(::)];
 logs:key logDir;
 logs:logs where logs<=`$last "/" vs string tpInfo`logFile;
 logs:logs iasc logs;
 .util.log.ex[`INFO;`.oq.rdb.replayMissedTicks]"Replaying ",(string count logs)," log segment(s)";
 {@[-11!;x;{[f;e].util.log.ex[`ERROR;`.oq.rdb.replayMissedTicks]"Error replaying ",(string f)," with: ",e}[x]]} each .Q.dd[logDir] each logs;
 };

//@func   | .oq.rdb.reconnectTPs
//@desc
//Timer callback: attempts to reconnect to any tickerplant currently
//disconnected - but only while this instance is meant to be active.
//Without the .oq.rdb.active guard, this would silently undo
//.oq.rdb.standby within 30s of every deliberate stand-down (a standby's
//own hclose looks, to this timer, identical to an active instance that
//just dropped its connection and needs reconnecting).
//@desc
.oq.rdb.reconnectTPs:{[]
 if[not .oq.rdb.active;:(::)];
 {.oq.rdb.connectToTP[x;enlist `]} each exec address from .oq.rdb.tpConns where null handle;
 };

//@func   | .oq.rdb.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//Marks a tickerplant connection dead on disconnect
//@desc
.oq.rdb.ZPC:{[zpc;W]
 if[W in exec handle from .oq.rdb.tpConns;
    .util.log.ex[`WARN;`.oq.rdb.ZPC]"Lost connection to tickerplant, handle: ",string W;
    update handle:0Ni,firstConn:0b,disconnTime:.z.p from `.oq.rdb.tpConns where handle=W;
   ];
 zpc[W]
 };

//@func   | .oq.rdb.flush
//@param  | tab     | -11 | Table to flush
//@param  | maxTime | -12 | Delete all rows with timestamp<=maxTime
//@desc
//Releases rows already confirmed durable on disk (by save.q), freeing RDB memory
//@desc
.oq.rdb.flush:{[tab;maxTime]
 before:count value tab;
 delete from tab where timestamp<=maxTime;
 .util.log.ex[`INFO;`.oq.rdb.flush]"Flushed ",(string before-count value tab)," row(s) from ",(string tab)," up to ",string maxTime;
 update `g#sym from tab;
 };

.oq.rdb.info.handlers.zpc:.util.handlers.add[`.z.pc;`.oq.rdb.ZPC];
.oq.rdb.info.timer.reconnect:.util.timer.add[.z.p;0Wp;0D00:00:30;`.oq.rdb.reconnectTPs;`DEF;"rdb reconnect to tickerplants"];

//@func   | .oq.rdb.activate
//@desc
//Promotes this instance from standby to active: a plain LIVE subscribe
//to .oq.rdb.tpAddr, deliberately NOT via .oq.rdb.connectToTP - that
//path always replays every tplog segment on disk so far (right for a
//brand-new rdb's very first connection, where there really is a full
//day to catch up on), which is exactly wrong here: in the repeating
//pivot design (see this file's header), a standby always starts from a
//clean slate (core/idb.q flushed it completely the last time it was
//harvested), and everything before "now" is either already in an idb
//segment or still live on the other half of the pair - replaying it
//would duplicate it into this cycle's harvest, not catch anything up.
//Still records the connection in .oq.rdb.tpConns (firstConn:0b, so nothing
//downstream mistakes it for a connection needing replay) so the 30s
//reconnect timer can recover it the normal way after a genuine drop. A
//no-op if already active. Callable over IPC (e.g. `h(`.oq.rdb.activate;::)`)
//- core/idb.q's pivot timer is what actually calls this; there is no
//other automatic trigger.
//@desc
.oq.rdb.activate:{[]
 if[.oq.rdb.active;:(::)];
 .oq.rdb.active:1b;
 hnum:@[.util.ipc.hopen;(.oq.rdb.tpAddr;5000);{[a;e].util.log.ex[`ERROR;`.oq.rdb.activate]"Failed to connect to ",(string a)," with: ",e;0Ni}[.oq.rdb.tpAddr]];
 if[not null hnum;
    .u.t:distinct .u.t,tables`.;
    // protected, matching .oq.rdb.connectToTP's own established pattern
    // for this exact call - .util.ipc.hopen just fired its own async
    // identify message (see core/utils/ipc.q) at the tp on this same
    // handle a moment ago, and a sync call landing right behind it has
    // been observed to occasionally come back as a transport-level
    // error on this build even though the subscription itself still
    // goes through - unprotected, that would make .oq.rdb.activate
    // itself throw, which is caught by the CALLER (core/idb.q) but
    // leaves .oq.rdb.active already true regardless
    @[hnum;(`.u.subInfo;`;`);{[e].util.log.ex[`WARN;`.oq.rdb.activate]"Subscribe call returned an error (subscription may still have gone through): ",e}];
    `.oq.rdb.tpConns upsert (.oq.rdb.tpAddr;hnum;`;0Np;0Nj;0b;0Wp);
   ];
 .util.log.ex[`INFO;`.oq.rdb.activate]"Promoted to ACTIVE (live subscribe, no replay): ",string .util.start.CLP[`name][`val];
 };

//@func   | .oq.rdb.standby
//@desc
//Demotes this instance from active to standby: for each tickerplant
//handle it first calls .u.unsub SYNCHRONOUSLY (so the tp prunes this
//handle from .u.w in-band, before the socket dies - otherwise .u.pub
//keeps hitting the still-listed dead handle and logs a "handle N is not
//an ipc handle" WARN per update until the tp's own deferred .z.pc
//cleanup catches up, which on a tp/CEP busy relaying a live feed lags
//for seconds), then hclose's it. Falls back to the .z.pc path if the
//unsub call errors (older tp, transport hiccup). Marks this instance
//inactive so .oq.rdb.reconnectTPs leaves it alone. A no-op if already
//standby. Callable over IPC the same way .oq.rdb.activate is.
//@desc
.oq.rdb.standby:{[]
 if[not .oq.rdb.active;:(::)];
 .oq.rdb.active:0b;
 handles:exec handle from .oq.rdb.tpConns where not null handle;
 {@[x;(`.u.unsub;::);{[e].util.log.ex[`DEBUG;`.oq.rdb.standby]"pre-hclose .u.unsub failed (falling back to tp .z.pc cleanup): ",e}]} each handles;
 {@[hclose;x;{[e].util.log.ex[`DEBUG;`.oq.rdb.standby]"hclose failed: ",e}]} each handles;
 .util.log.ex[`INFO;`.oq.rdb.standby]"Demoted to STANDBY: ",string .util.start.CLP[`name][`val];
 };

//@func   | .oq.rdb.init
//@desc
//Full startup sequence for an rdb process: points save.q's EOD path at
//this RDB's HDB root, remembers -tpaddr for .oq.rdb.activate, then
//connects (and first-time replays) against its tickerplant - UNLESS
//-instance says this is the standby half of a dual-instance pair (see
//this file's header), in which case it comes up queryable but
//deliberately never subscribes until something calls .oq.rdb.activate.
//Reads its own params from .util.start.CLP so callers (init.q/
//initFromCfg.q) don't need to know which CLI params an rdb needs.
//@desc
.oq.rdb.init:{[]
 .oq.save.hdbRoot:.util.core.toHsym .util.start.CLP[`hdbroot][`val];
 .oq.rdb.tpAddr:`$.util.start.CLP[`tpaddr][`val];
 .oq.rdb.active:not 2=.util.start.CLP[`instance][`val];
 $[.oq.rdb.active;
   [.oq.rdb.connectToTP[.oq.rdb.tpAddr;enlist `];
    .util.log.ex[`INFO;`.oq.rdb.init]"RDB started (ACTIVE): ",string .util.start.CLP[`name][`val]];
   .util.log.ex[`INFO;`.oq.rdb.init]"RDB started (STANDBY - call .oq.rdb.activate[] to promote): ",string .util.start.CLP[`name][`val]];
 };

.oq.info.rdb.loaded:1b;
