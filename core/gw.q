//====================================================================
// Directory: core/gw.q
//
// About:
// Gateway routing: decides whether a query needs to fan out to the RDB
// (today's in-memory data), the HDB (prior days' on-disk data), or both,
// based purely on whether the requested time range crosses the start of
// today - then hands off to utils/gateway.q's generic fan-out engine.
//
// Namespaces:
//   .oq.gw.*    - RDB/HDB routing decision, client query entry point, and
//                 .init - the full startup sequence
//====================================================================
.oq.info.gw.loaded:0b;

//@func   | .oq.gw.todayStart
//@return | -12 | UTC timestamp for the start of today
//@desc
//The RDB/HDB boundary: data from today lives in the RDB, prior days on the HDB
//@desc
.oq.gw.todayStart:{[] `timestamp$`date$.z.p};

//@func   | .oq.gw.chooseServers
//@param  | sTime | -12 | Start time, ` for open-ended
//@param  | eTime | -12 | End time, ` for open-ended
//@return | 11 | Server type(s) to route to
//@desc
//RDB if the range reaches into today, HDB if it reaches before today, both if it spans the boundary
//@desc
.oq.gw.chooseServers:{[sTime;eTime]
 boundary:.oq.gw.todayStart[];
 needsRDB:$[eTime~`;1b;eTime>=boundary];
 needsHDB:$[sTime~`;1b;sTime<boundary];
 raze (needsHDB#enlist `hdb),needsRDB#enlist `rdb
 };

//@func   | .oq.gw.query
//@param  | table  | -11 | Table to query
//@param  | sCols  | 0   | Columns to return, ` for all
//@param  | sTime  | -12 | Start time (UTC), ` for open-ended
//@param  | eTime  | -12 | End time (UTC), ` for open-ended
//@param  | symb   | 0   | Sym or sym-pattern filter, ` for all
//@param  | whereC | 0   | Extra where-clause list, ` for none
//@desc
//Client entry point (called as an async message on the gateway): routes and queues the query
//@desc
.oq.gw.query:{[table;sCols;sTime;eTime;symb;whereC]
 serverType:.oq.gw.chooseServers[sTime;eTime];
 call:(`.oq.query.query;table;sCols;sTime;eTime;symb;whereC);
 .util.gw.asyncExec[call;serverType];
 };

//@func   | .oq.gw.init
//@desc
//Full startup sequence for a gw process: registers the RDB and HDB
//backends utils/gateway.q's fan-out engine routes to. Reads its own
//params from .util.start.CLP so callers (init.q/initFromCfg.q) don't need
//to know which CLI params a gw needs.
//@desc
.oq.gw.init:{[]
 .util.servers.add `$.util.start.CLP[`rdbaddr][`val];
 .util.servers.add `$.util.start.CLP[`hdbaddr][`val];
 .util.log.ex[`INFO;`.oq.gw.init]"Gateway started: ",string .util.start.CLP[`name][`val];
 };

.oq.info.gw.loaded:1b;
