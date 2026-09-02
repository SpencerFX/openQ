//====================================================================
// Directory: core/cep.q
//
// About:
// Generic CEP (complex event processing) process: subscribes to one or more
// upstream sources (a tickerplant, or another CEP - anything speaking the
// .u.sub protocol tp.q defines) and dispatches every incoming update to
// however many handler functions are registered for that table, each
// independently error-trapped so one handler failing doesn't take down the
// others or the process. A handler is free to do anything - alert, log,
// aggregate, detect patterns - and, since tp.q is loaded alongside this for
// its own downstream .u.sub/.u.pub machinery, can publish derived events of
// its own for further RDBs/CEPs/gateways to subscribe to, making CEPs
// chainable. No specific handler logic or schema lives here - deployments
// supply that (see config.q's -cepscript).
//
// Namespaces:
//   .oq.cep.*   - handler registry/dispatch, source connect/replay/
//                 reconnect, mode selection, and .init - the full startup
//                 sequence
//====================================================================
.oq.info.cep.loaded:0b;

//Upstream sources this CEP is subscribed to
.oq.cep.sources:([address:`symbol$()] handle:`int$(); logFile:`symbol$(); logIndex:`long$(); firstConn:`boolean$(); disconnTime:`timestamp$());

//Registered handlers: any number per table, run in registration order
.oq.cep.handlers:([id:`long$()] tab:`symbol$(); fn:(); info:`$());
.oq.cep.handlerID:0;

//@func   | .oq.cep.addHandler
//@param  | tab  | -11 | Table this handler runs on
//@param  | fn   | 100 | Function taking (tab;data), called on every update for tab
//@param  | info | -11 | Short label for logging
//@return | -7   | Handler ID, usable with .oq.cep.removeHandler
//@desc
//Registers a handler function to run whenever an update for tab arrives
//@desc
.oq.cep.addHandler:{[tab;fn;info]
 .oq.cep.handlerID+:1;
 `.oq.cep.handlers upsert (.oq.cep.handlerID;tab;fn;info);
 .util.log.ex[`INFO;`.oq.cep.addHandler]"Registered handler \"",(string info),"\" for table ",string tab;
 .oq.cep.handlerID
 };

//@func   | .oq.cep.removeHandler
//@param  | handlerID | -7 | ID returned by .oq.cep.addHandler
//@desc
//Deregisters a handler
//@desc
.oq.cep.removeHandler:{[handlerID]
 delete from `.oq.cep.handlers where id=handlerID;
 };

//@func   | .oq.cep.dispatch
//@param  | t | -11 | Table name
//@param  | x | 98 0 | Data
//@desc
//Runs every handler registered for t, trapping and logging each independently
//@desc
.oq.cep.dispatch:{[t;x]
 fns:exec fn from .oq.cep.handlers where tab=t;
 {[t;x;fn] .[fn;(t;x);{[t;e].util.log.ex[`ERROR;`.oq.cep.dispatch]"Handler failed for ",(string t),": ",e}[t]]}[t;x] each fns;
 };

//Root-level upd: every message from an upstream source (or a directly
//connected feed handler) is dispatched to whichever handlers are registered
//for that table. Deliberately does NOT alias to .u.upd the way tp.q's
//.oq.tp.modeSet does - see .oq.cep.modeSet.
upd:{[t;x] .oq.cep.dispatch[t;x]};

//@func   | .oq.cep.modeSet
//@param  | bmode | -7 | 0 for no-latency, 1 for batch - governs .u.upd, used by
//                       handlers that want to publish derived output downstream
//@desc
//Sets up this CEP's own .u.upd (for handlers to publish through) without
//touching the root-level `upd` alias, which stays .oq.cep.dispatch
//@desc
.oq.cep.modeSet:{[bmode]
 .oq.tp.modeSet[bmode];
 upd::{[t;x] .oq.cep.dispatch[t;x]};
 };

//@func   | .oq.cep.connectSource
//@param  | address | -11 | `:host:port of the upstream source
//@param  | tabs    | 11  | Table(s) to subscribe to, enlist ` for all
//@return | -6 | Handle opened, or 0Ni on failure
//@desc
//Opens a handle to an upstream source and subscribes to it
//@desc
.oq.cep.connectSource:{[address;tabs]
 .util.log.ex[`INFO;`.oq.cep.connectSource]"Connecting to source ",string address;
 hnum:@[.util.ipc.hopen;(address;5000);{[a;e].util.log.ex[`ERROR;`.oq.cep.connectSource]"Failed to connect to ",(string a)," with: ",e;0Ni}[address]];
 `.oq.cep.sources upsert (address;hnum;`;0Nj;1b;0Wp);
 if[not null hnum;
    info:@[hnum;(`.u.subInfo;first tabs,();`);{[e](();0Nj;`)}];
    .oq.cep.registerSource[info 1;info 2;hnum]
   ];
 hnum
 };

//@func   | .oq.cep.registerSource
//@param  | srcLogIndex | -7  | The source's current .u.j counter at time of subscription
//@param  | srcLogFile  | -11 | The source's currently open log file
//@param  | hnum        | -6  | Handle to the source
//@desc
//Records source log position on (re)connect; on first-ever connection, replays what was missed.
//NOTE: the params are deliberately not named `logFile`/`logIndex` - .oq.cep.sources
//has columns of those names, and exec/where clauses bind column names into scope,
//silently shadowing an outer variable of the same name.
//@desc
.oq.cep.registerSource:{[srcLogIndex;srcLogFile;hnum]
 update logFile:srcLogFile,logIndex:srcLogIndex from `.oq.cep.sources where handle=hnum;
 if[first exec firstConn from .oq.cep.sources where handle=hnum;
    .util.log.ex[`INFO;`.oq.cep.registerSource]"First connection: replaying missed log segment";
    .oq.cep.replayMissedTicks[first exec address from .oq.cep.sources where handle=hnum]
   ];
 };

//@func   | .oq.cep.replayMissedTicks
//@param  | srcAddr | -11 | Source address this CEP is (re)connecting to
//@desc
//Replays tplog entries from local disk to catch up on ticks missed while disconnected.
//Local-disk replay only - a co-located or shared-filesystem source is assumed.
//NOTE: param deliberately not named `address` - see .oq.cep.registerSource's note.
//@desc
.oq.cep.replayMissedTicks:{[srcAddr]
 srcInfo:exec from .oq.cep.sources where address=srcAddr;
 if[null srcInfo`logFile;.util.log.ex[`WARN;`.oq.cep.replayMissedTicks]"No log file known for ",string srcAddr;:(::)];
 logDir:`$"/" sv -1_"/" vs string srcInfo`logFile;
 if[not type key logDir;.util.log.ex[`WARN;`.oq.cep.replayMissedTicks]"Log directory not visible locally: ",string logDir;:(::)];
 logs:key logDir;
 logs:logs where logs<=`$last "/" vs string srcInfo`logFile;
 logs:logs iasc logs;
 .util.log.ex[`INFO;`.oq.cep.replayMissedTicks]"Replaying ",(string count logs)," log segment(s)";
 {@[-11!;x;{[f;e].util.log.ex[`ERROR;`.oq.cep.replayMissedTicks]"Error replaying ",(string f)," with: ",e}[x]]} each .Q.dd[logDir] each logs;
 };

//@func   | .oq.cep.reconnectSources
//@desc
//Timer callback: attempts to reconnect to any source currently disconnected
//@desc
.oq.cep.reconnectSources:{[]
 {.oq.cep.connectSource[x;enlist `]} each exec address from .oq.cep.sources where null handle;
 };

//@func   | .oq.cep.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//Marks a source connection dead on disconnect
//@desc
.oq.cep.ZPC:{[zpc;W]
 if[W in exec handle from .oq.cep.sources;
    .util.log.ex[`WARN;`.oq.cep.ZPC]"Lost connection to source, handle: ",string W;
    update handle:0Ni,firstConn:0b,disconnTime:.z.p from `.oq.cep.sources where handle=W;
   ];
 zpc[W]
 };

.oq.cep.info.handlers.zpc:.util.handlers.add[`.z.pc;`.oq.cep.ZPC];
.oq.cep.info.timer.reconnect:.util.timer.add[.z.p;0Wp;0D00:00:30;`.oq.cep.reconnectSources;`DEF;"cep reconnect to sources"];

//@func   | .oq.cep.init
//@desc
//Full startup sequence for a cep process: loads the deployment-supplied
//-cepscript (if any), validates the schema and opens the tplog for this
//CEP's own derived output (.u.tick), selects the update mode, and
//connects to its upstream source. Reads its own params from
//.util.start.CLP so callers (init.q/initFromCfg.q) don't need to know
//which CLI params a cep needs.
//@desc
.oq.cep.init:{[]
 cepscript:.util.start.CLP[`cepscript][`val];
 if[count cepscript;.util.core.loadScript[cepscript]];
 logdir:.util.start.CLP[`tplogdir][`val];
 .u.tick["cep";logdir];
 .oq.cep.modeSet .util.start.CLP[`bmode][`val];
 if[count logdir;.oq.cep.info.timer.rotate:.util.timer.add[.z.p;0Wp;0D00:10:00;`.oq.tp.rotateLogs;`REL;"cep log rotation"]];
 .oq.cep.connectSource[`$.util.start.CLP[`srcaddr][`val];enlist `];
 .util.log.ex[`INFO;`.oq.cep.init]"CEP started: ",string .util.start.CLP[`name][`val];
 };

.oq.info.cep.loaded:1b;
