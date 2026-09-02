//====================================================================
// Directory: core/tp.q
//
// About:
// Tickerplant: the .u namespace is the standard kdb+ tick pub/sub mechanism -
// subscribers register interest per table/sym, every update is appended to a
// rolling on-disk log before being broadcast, and log rotation/replay lets a
// restarted RDB catch up on exactly what it missed.
//
// Namespaces:
//   .u.*        - tickerplant pub/sub protocol: subscribe/unsubscribe,
//                 publish, log write/rotate/replay
//   .oq.tp.*    - mode selection (no-latency/batch), log rotation timer,
//                 disconnect cleanup, and .init - the full startup sequence
//====================================================================
.oq.info.tp.loaded:0b;

\d .u

//@func  | .u.init
//@desc
//Inits the subscriber tables from the tables currently in the root namespace
//@desc
init:{w25bang::w::t!(count t::tables`.)#()}

//@func  | .u.del
//@param | tab | -11 | Table name
//@param | h   | -6  | Handle to remove
//@desc
//Removes handle h's subscription to table tab, from BOTH the master
//subscriber table `w` and the per-handle publish cache `w25bang` that
//.u.pub actually iterates. `w25bang[tab]:w[tab]` (indexed, so it hits the
//GLOBAL) mirrors what .u.add does - a bare `w25bang:...` here would only
//bind a function-local and leave the pruned handle live in the publish
//path until the next .u.add rebuilt it, which is exactly how a
//stood-down active/standby rdb kept drawing "handle N is not an ipc
//handle" WARNs from .u.pub for a whole pivot cycle.
//@desc
del:{[tab;h]
 if[0=h;:()];
 w[tab]:w[tab] where w[tab;;0]<>h;
 w25bang[tab]:w[tab];
 }

//@func  | .u.sel
//@param | tab | 98   | Table
//@param | s   | -11 11h | Syms to filter to, ` for all
//@return | 98 | Filtered table
//@desc
//Returns tab filtered to rows matching sym in s (or unfiltered if s is a null sym)
//@desc
sel:{[tab;s]
 $[`~s;tab;select from tab where sym in s]
 }

//@func  | .u.pub
//@param | t | -11 | Table name
//@param | x | 98 0 | Data
//@desc
//Publishes data x for table t to every subscribed handle, filtered per-subscription by sym.
//Each send is individually protected (logs a WARN and moves on) rather than
//left to fail the whole each-loop - confirmed by instrumented testing that
//a churning subscriber (see core/rdb.q's active/standby pivot) can leave a
//handle in w25bang whose underlying socket the OS has ALREADY torn down,
//moments before .z.pc's own cleanup (.oq.tp.ZPC -> .u.del, below) gets
//around to removing it: q's .z.pc callback is a queued dispatch, not
//synchronous with the OS-level disconnect, so there's a real (if narrow)
//window where -25! to that one dead handle throws "X is not an ipc handle"
//- and an unprotected throw here aborts this each-loop entirely, silently
//dropping delivery to every OTHER, perfectly healthy subscriber still left
//to iterate (e.g. the very instance that was just promoted active). This
//was the actual mechanism behind the "sometimes a pivot cycle loses data"
//symptom - not a corrupted subscriber list (verified clean via dispatch-
//order tracing), but one dead entry taking the rest of the batch down with it.
//@desc
pub:{[t;x]
 {[t;x;w]
  if[count y:sel[x;w 1];@[-25!;(enlist w 0;(`upd;t;y));{[h;e].util.log.ex[`WARN;`.u.pub]"Publish to handle ",(string h)," failed (likely a subscriber mid-disconnect) with: ",e}[w 0]]]
  }[t;x] each w25bang t;
 }

//@func  | .u.wupd
//@desc
//Reforms .u.w[tab] (a list of (handle;syms)) into a grouped-by-handle form for pub's each-loop
//@desc
wupd:{[tab] w[tab]}

//@func  | .u.add
//@param | tab | -11 | Table name
//@param | s   | 11  | Sym list to subscribe to
//@desc
//Adds/updates a subscription for the calling handle (.z.w) to table tab for syms s
//@desc
add:{[tab;s]
 i:w[tab;;0]?.z.w;
 $[(count w tab)>i;w[tab;i]:(.z.w;s);w[tab],:enlist (.z.w;s)];
 w25bang[tab]:w[tab];
 (tab;sel[value tab;s])
 }

//@func  | .u.sub
//@param | tab | -11 | Table name, ` for all tables
//@param | s   | 11  | Sym list to subscribe to
//@desc
//Subscribes the calling handle to tab (or all tables if tab is `), removing any prior subscription first
//@desc
sub:{[tab;s]
 if[tab~`;:sub[;s] each t];
 if[not tab in t;.util.log.exSig[`ERROR;`.u.sub]"Attempted subscription for table not present in .u.t"];
 del[tab;.z.w];
 add[tab;s]
 }

//@func  | .u.subInfo
//@param | tab | -11 | Table name, ` for all tables
//@param | s   | 11  | Sym list to subscribe to
//@return | 99 | (subResult;currentLogIndex;currentLogFile)
//@desc
//Subscribes and, in the same round trip, returns the TP's current log position -
//what an RDB needs to know where to resume replay from on (re)connect
//@desc
subInfo:{[tab;s] (sub[tab;s];j;L)}

//@func  | .u.unsub
//@desc
//Unsubscribes the calling handle from every table, in-band. A subscriber
//about to hclose (core/rdb.q's .oq.rdb.standby on an active/standby pivot)
//calls this SYNCHRONOUSLY first so its entries are pruned from .u.w before
//the socket goes away - closing the window in which .u.pub, iterating a
//still-listed but now-dead handle, logs a "handle N is not an ipc handle"
//WARN per update until .z.pc's own deferred cleanup catches up (which, on
//a tp/CEP busy relaying a live feed, can lag for seconds). Idempotent, and
//harmless for a handle that was never subscribed.
//@desc
unsub:{[] del[;.z.w] each t}

//@func  | .u.wap
//@param | dTime | -15 | Now datetime
//@desc
//Intraday callback, called on every log rotation before the log file is swapped
//@desc
wap:{[dTime]}

//@func  | .u.wl
//@param | f | -11 | Function to signal to subscribers
//@param | p | -15 | Param to pass
//@desc
//Notifies subscribers via f, then closes and reopens the tplog file
//@desc
wl:{[f;p]
 wap[p];
 if[l;@[hclose;l;{[h;e].util.log.ex[`WARN;`.u.wl]"Failed to close log handle ",(string h)," with: ",e}[l]]];
 l::ld `datetime$.z.Z;
 }

//@func  | .u.ts
//@param | x | -15 | Now datetime
//@desc
//Timer callback: rotates the tplog
//@desc
ts:{wl[`.u.ups;x]}

//@func  | .u.ld
//@param | dTime | -15 | .z.Z, now datetime
//@return | -6 | Handle to the (re)opened log file
//@desc
//Opens (creating if needed) the tplog file for the current 10-minute bucket, resetting .u.i/.u.j
//@desc
ld:{[dTime]
 bucket:0D00:10:00 xbar `timestamp$dTime;
 safe:{x where x in .Q.n} string bucket;
 //safe is always 23 digits (8 date + 15 time-of-day); L's placeholder/prior suffix must match that length
 L::`$(-23_string L),safe;
 if[not type key L;L set ()];
 i::j::-11!(-2;L);
 hopen L
 }

//@func  | .u.updNL
//@param | t | -11 | Table name
//@param | x | 98 0 | Data
//@desc
//No-latency mode: stamps time if missing, appends to the log, publishes immediately
//@desc
updNL:{[t;x]
 if[not -12=type first first x;
  a:.z.p;
  x:$[98=type x;`timestamp xcols![;();0b;(enlist`timestamp)!enlist a] x;$[0>type first x;a,x;(enlist (count first x)#a),x]]
  ];
 if[l;l enlist (`upd;t;x);i+:1];
 x:$[98=type x;x;[f:key flip value t;$[0>type first x;enlist f!x;flip f!x]]];
 pub[t;x];
 j+:1;
 }

//@func  | .u.updB
//@param | t | -11 | Table name
//@param | x | 98 0 | Data
//@desc
//Batch mode: stamps time if missing and inserts into the local in-memory table; publishing happens on the 1s timer via pubB
//@desc
updB:{[t;x]
 if[not -12=type first first x;
  a:.z.p;
  x:$[98=type x;`timestamp xcols![;();0b;(enlist`timestamp)!enlist a] x;$[0>type first x;a,x;(enlist (count first x)#a),x]]
  ];
 t insert x;
 }

//@func  | .u.pubB
//@desc
//Batch mode timer callback (every 1s): logs+publishes each table's buffered rows, then empties the buffers
//@desc
pubB:{[]
 if[l;{d:x cols x;if[count first d;l enlist (`upd;x;d);j+:1]} each t];
 if[0<count union/[w[;;0]]];
  pub'[t;value each t];
 i::j;
 @[`.;t;@[;`sym;`g#] 0#];
 }

//@func  | .u.tick
//@param | s      | 10 | Log-file name prefix, "" for none
//@param | logdir | 10 | Path to log directory, "" for none
//@desc
//Validates every table has timestamp,sym first, applies grouped sym attribute, opens the tplog
//@desc
tick:{[s;logdir]
 init[];
 //zero output tables is valid (e.g. a CEP with nothing to publish downstream) -
 //min/not over an empty list yields a generic null, not a boolean, which `if`
 //treats as true, so the check only runs when there's actually something to check
 if[count t;
    if[not min(`timestamp`sym~2#key flip value@) each t;
       .util.log.exSig[`ERROR;`.u.tick]"Table schema does not contain timestamp and sym as first 2 columns"
      ]
   ];
 @[;`sym;`g#] each t;
 //i/j/L must exist even with no on-disk log - .u.subInfo returns them
 //unconditionally, and a subscriber (e.g. a CEP relaying live with no
 //tplog of its own) must still be able to complete that round trip so its
 //`sub` call actually registers the handle; ld[] overwrites these below
 //when a real log is opened
 i::j::0Nj;
 L::`;
 if[l::count logdir;
    L::`$":",logdir,"/",s,23#".";
    l::ld `datetime$.z.Z
   ];
 }

\d .

//@func  | .oq.tp.modeSet
//@param | bmode | -7 | 0 for no-latency, 1 for batch
//@desc
//Selects the update mode and, in batch mode, starts the 1s publish timer
//@desc
.oq.tp.modeSet:{[bmode]
 if[0=bmode;.util.log.ex[`INFO;`.oq.tp.modeSet]"Tickerplant running in no-latency mode";.u.upd:.u.updNL];
 if[1=bmode;
    .util.log.ex[`INFO;`.oq.tp.modeSet]"Tickerplant running in batch mode";
    .u.upd:.u.updB;
    .util.timer.add[0Np;0Wp;0D00:00:01;`.u.pubB;`REL;"tp batch publish"];
   ];
 //root-level alias so feed handlers can publish via the classic `upd call, same as RDBs expose
 upd::.u.upd;
 };

//@func  | .oq.tp.rotateLogs
//@desc
//Timer callback: rotates the tplog (called every 10 minutes)
//@desc
.oq.tp.rotateLogs:{[] .u.wl[`.u.ups;.z.Z]};

//@func  | .oq.tp.init
//@desc
//Full startup sequence for a tp process: validates the schema and opens
//the tplog (.u.tick), selects the update mode, and - only if an on-disk
//log is configured - registers the 10-minute rotation timer. Reads its
//own params from .util.start.CLP so callers (init.q/initFromCfg.q) don't
//need to know which CLI params a tp needs.
//@desc
.oq.tp.init:{[]
 logdir:.util.start.CLP[`tplogdir][`val];
 .u.tick["tp";logdir];
 .oq.tp.modeSet .util.start.CLP[`bmode][`val];
 if[count logdir;.oq.tp.info.timer.rotate:.util.timer.add[.z.p;0Wp;0D00:10:00;`.oq.tp.rotateLogs;`REL;"tp log rotation"]];
 .util.log.ex[`INFO;`.oq.tp.init]"Tickerplant started: ",string .util.start.CLP[`name][`val];
 };

//@func  | .oq.tp.ZPC
//@param | zpc | 100 | Base .z.pc
//@param | W   | -6  | Handle being closed
//@desc
//Removes a disconnected handle from all subscription tables
//@desc
.oq.tp.ZPC:{[zpc;W]
 if[W in union/[.u.w[;;0]]];
  .u.del[;W] each .u.t;
 zpc[W]
 };

.oq.tp.info.handlers.zpc:.util.handlers.add[`.z.pc;`.oq.tp.ZPC];

//@func  | .z.exit
//@desc
//Closes the tplog handle cleanly on shutdown
//@desc
.z.exit:{[x]
 if[@[get;`.u.l;0]>0;@[hclose;.u.l;{[e].util.log.ex[`WARN;`.z.exit]"Failed to close log handle with: ",e}]];
 };

.oq.info.tp.loaded:1b;
