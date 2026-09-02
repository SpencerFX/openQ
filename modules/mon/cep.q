//====================================================================
// Directory: modules/mon/cep.q
//
// About:
// -cepscript for the mon module's CEP (cfg_proc/modules/mon/cep.json).
// Everything else in this module - tp, rdb, idb, hdb - is the exact same
// core/ code the default pipeline uses; nothing about ingesting the `logs`
// stream itself needed custom code, since tp.q/rdb.q/idb.q/hdb.q are
// already schema-agnostic (they validate timestamp+sym first and operate
// on whatever .oq.schema.tables[] says - here schemas/schema_mon.q's
// `logs` table instead of the default schema.q's quote/trade). This file
// is the one place that's genuinely custom: what a mon CEP actually DOES
// with incoming log rows.
//
// Tracks running WARN/ERROR/FATAL counts per publishing process (per
// `logs`' sym column) as they arrive, and on a timer logs a summary of
// which processes have had any ERROR/FATAL in the current window, then
// resets - the "custom timer" half of this module. rdb (an active/
// standby pair - see core/rdb.q's header) points its -tpaddr at this CEP
// rather than at the tp directly (the default process flow: fh -> tp ->
// cep -> rdb -> eod -> hdb, plus idb pivoting the rdb pair on its own
// timer rather than subscribing anywhere - see core/idb.q's header - see
// the README's "Modules" section), so alongside the counter
// this file also relays every row of every table unchanged via .u.upd -
// otherwise nothing downstream of the CEP would ever see any data, since
// .oq.cep.dispatch only does whatever handlers are actually registered
// for a table.
//
// Namespaces:
//   .mon.* - per-process error/warn/fatal counters, incoming-row
//            handler, periodic summary/reset timer, and the relay
//====================================================================

//Running per-process counts since the last summary
.mon.errorCounts:([sym:`symbol$()] warn:`long$(); error:`long$(); fatal:`long$());

//How often .mon.logSummary fires and resets .mon.errorCounts
.mon.summaryFreq:0D00:05:00;

//@func   | .mon.onLog
//@param  | t | -11 | Table name (always `logs)
//@param  | x | 98  | Incoming batch of `logs rows
//@desc
//Bumps .mon.errorCounts for every WARN/ERROR/FATAL row in this batch,
//grouped by sym first so a multi-row batch only touches each process
//once rather than once per row
//@desc
.mon.onLog:{[t;x]
 hot:select from x where level in `WARN`ERROR`FATAL;
 if[0=count hot;:(::)];
 delta:0!select warn:sum level=`WARN,error:sum level=`ERROR,fatal:sum level=`FATAL by sym from hot;
 {[row]
   if[not row[`sym] in key .mon.errorCounts;`.mon.errorCounts upsert (row[`sym];0;0;0)];
   .mon.errorCounts[row`sym]+:row`warn`error`fatal;
  } each delta;
 };

//@func   | .mon.logSummary
//@desc
//Timer callback: logs which processes had any ERROR/FATAL this window,
//then resets the counters for the next one. Registered on .mon.summaryFreq
//by .mon.init below.
//@desc
.mon.logSummary:{[]
 hot:select from .mon.errorCounts where 0<error+fatal;
 if[count hot;
    .util.log.ex[`WARN;`.mon.logSummary]"Processes with error/fatal logs in the last ",(string .mon.summaryFreq),": ",", " sv string exec sym from hot
   ];
 delete from `.mon.errorCounts;
 };

//@func   | .mon.relay
//@param  | t | -11 | Table name (`logs or `pidstats)
//@param  | x | 98  | Incoming batch of rows for t
//@desc
//Republishes an incoming batch unchanged - logs it to this CEP's own
//tplog and publishes it to its subscribers (rdb - idb doesn't subscribe to
//anything, see core/idb.q's header),
//same as a real tp would. Registered on every schema table, alongside
//(not instead of) .mon.onLog's analytics on `logs.
//@desc
.mon.relay:{[t;x]
 .u.upd[t;x];
 };

.oq.cep.addHandler[`logs;.mon.onLog;`monErrorCounter];
{.oq.cep.addHandler[x;.mon.relay;`$"monRelay",string x]} each .oq.schema.tables[];
.mon.info.timer.summary:.util.timer.add[.z.p+.mon.summaryFreq;0Wp;.mon.summaryFreq;`.mon.logSummary;`REL;"mon error/warn/fatal summary"];
