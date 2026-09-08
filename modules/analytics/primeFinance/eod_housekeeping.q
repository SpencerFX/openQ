//====================================================================
// Directory: modules/analytics/primeFinance/eod_housekeeping.q
//
// About:
// -hkscript for the primeFinance module's housekeeping process: a
// wall-clock timer that promotes each completed UTC day's inventory/
// locate/position/borrow/recall rows into the real dated HDB partition
// (see cfg_proc/modules/primefinance/hdb.json's hdbroot) by calling
// .oq.idb.eod[dt] via IPC on the already-running primefinance idb
// (-idbaddr) - final pivot-and-harvest, promote the day's segments,
// clear -idbroot so the next day restarts at segment 0. Same mechanism
// as modules/mon/eod_housekeeping.q (mon) and
// modules/ingest/yfinance/q/eod_housekeeping.q (eq_m1_yfinance/
// fx_m1_yfinance); this is the mon-shaped, multi-table variant - it
// drives .oq.schema.tables[] rather than naming a single owned table,
// since primeFinance's schema has 5 tables (inventory/locate/position/
// borrow/recall), not the yfinance family's one-table-per-process split.
//
// Trigger time: 30 minutes AFTER eq_m1_yfinance_housekeeping's own
// -eodTriggerTime (08:30:00.000 UTC - see modules/ingest/yfinance/q/
// eod_housekeeping.q's header: 30 min past HKEX's close, tuned so both
// HKEX and Nikkei's full UTC trading day has landed). primeFinance's CEP
// (modules/analytics/primeFinance/cep.q, .primeMod.market.refresh)
// pulls real vol/ADV/close from eq_hdb - including eq_m1_yfinance's
// HKEX/Nikkei bars - to build calibration/positionRisk/crowding/
// exposure, so primeFinance's own day-close promotion is deliberately
// sequenced to run only after that upstream HKEX savedown has already
// landed in eq_hdb, not concurrently with it. Configured here as
// -eodTriggerTime 09:00:00.000 (cfg_proc/modules/primefinance/
// housekeeping.json) - update both together if eq_m1_yfinance's own
// trigger time ever moves.
//
// Trigger semantics: unlike mon's midnight-boundary trigger (which
// promotes .z.d-1, the day that just ended, on the first post-midnight
// tick), this fires mid-UTC-day - the target is .z.d + -eodDayOffset
// (default 0 = "today"), matching eq_m1_yfinance's own same-day
// promotion: by 09:00 UTC the UTC day in progress already has its full
// HKEX/Nikkei session behind it, so "today" is the day to promote, not
// yesterday. -eodDayOffset exists (optional CLP, default 0) purely so
// this same script stays reusable if a future deployment ever needs a
// different day target, mirroring the yfinance version's own knob.
//
// Idempotency is a marker FILE this script writes right after a
// successful .oq.idb.eod call - kept under a NON-date-named sibling
// directory (-hdbroot/.eod_markers/<date>) so kdb+'s partitioned-
// directory scan skips it (a plain file inside a date partition breaks
// the HDB loader outright - see eq_m1_yfinance's own eod_housekeeping.q
// header, modules/ingest/yfinance/, for the fuller writeup). A bare
// "does the partition dir exist" check isn't safe: an idb/save cycle can
// leave an empty dir behind well before a real promote.
//====================================================================
system "l ../schemas/schema_primefinance.q";

// jobStatus tracking for the scheduled EOD promote (.oq.hk.run). Same
// best-effort contract as this file's own .util.log.ex calls: a process
// with no mon tickerplant handle still runs the EOD, it just doesn't get
// a `jobStatus` row. Guarded so a missing/broken jobStatus.q can never
// stop the housekeeping script loading - .oq.hk.run checks `run in key
// `.mon.job before using it and falls back to the plain promote.
@[{system "l ../modules/mon/jobStatus.q"};`;
  {[e].util.log.ex[`WARN;`eodHousekeeping]"jobStatus.q not loaded - scheduled EODs will run untracked: ",e}];

.oq.hk.info.eodHousekeeping.loaded:0b;

.oq.hk.idbAddr:`$.util.start.CLP[`idbaddr][`val];
.oq.hk.hdbRoot:.util.core.toHsym .util.start.CLP[`hdbroot][`val];
.oq.hk.eodTriggerTime:"T"$.util.start.CLP[`eodTriggerTime][`val];
// -eodDayOffset is optional (absent from housekeeping.json today, so this
// always resolves to 0 = promote .z.d); .oq.cfg.merge lands a JSON number
// as a string, so "J"$ it back the same way the yfinance version does.
.oq.hk.dayOffset:{o:@[{"J"$.util.start.CLP[`eodDayOffset][`val]};`;0N]; $[null o;0;o]}[];
.oq.hk.idbH:0Ni;
// set fresh by .oq.hk.run right before promote (below) reads it - promote
// is a real niladic function so it can't see .oq.hk.run's own `target`
// local, only true globals (see .oq.hk.run's own comment on why)
.oq.hk.priv.target:0Nd;

//@func   | .oq.hk.eodConnect
//@desc
//Reuses .oq.hk.idbH while it's a genuinely live handle (checked against
//key .z.W, not just non-null), else reopens via .util.ipc.hopen.
//@desc
.oq.hk.eodConnect:{[]
 if[(not null .oq.hk.idbH) and .oq.hk.idbH in key .z.W;:(::)];
 .oq.hk.idbH:@[.util.ipc.hopen;.oq.hk.idbAddr;
   {[a;e].util.log.ex[`WARN;`.oq.hk.eodConnect]"Could not connect to idb ",(string a)," for scheduled EOD: ",e;0Ni}[.oq.hk.idbAddr]];
 };

//@func   | .oq.hk.markerFile
//@param  | dt | date
//@return | -11 | hsym of dt's marker file under -hdbroot/.eod_markers
//@desc
//Written right after a successful .oq.idb.eod call for dt - the sole
//idempotency signal, so a housekeeping restart can't re-fire a promote
//for an already-published date (which would collide with
//.oq.save.publish's atomic rename).
//@desc
.oq.hk.markerFile:{[dt] .Q.dd[.oq.hk.hdbRoot;] (`$".eod_markers";`$string dt)};

//@func   | .oq.hk.alreadyPromoted
//@param  | dt | date
//@return | -1 | true if .oq.hk.markerFile[dt] exists
//@desc
.oq.hk.alreadyPromoted:{[dt] not ()~key .oq.hk.markerFile[dt]};

//@func   | .oq.hk.hasForeignData
//@param  | dt | date
//@return | -1 | true if dt's partition already holds real rows for any
//                schema table from something other than this script
//@desc
//Second, independent safety check alongside .oq.hk.alreadyPromoted:
//that one catches a date THIS script promoted; this one catches a date
//something ELSE populated first (e.g. a manual EOD run, or a restored
//partition). Without it, a scheduled .oq.idb.eod call for an already-
//published date would fail .oq.save.publish's atomic rename. When it
//fires, .oq.hk.run drops a marker so the date goes quiet rather than
//being re-checked (and re-logged) every tick. Checks each table's `sym
//column file - all 5 primeFinance schema tables carry one.
//@desc
.oq.hk.hasForeignData:{[dt]
 any {[dt;t]
   p:.Q.dd[.oq.hk.hdbRoot;] (`$string dt;t);
   $[()~key p; 0b; 0<@[{count get .Q.dd[x;`sym]};p;{[e]0}]]
  }[dt] each .oq.schema.tables[]
 };

//@func   | .oq.hk.run
//@desc
//Timer callback (registered on -hkfreq by .oq.hk.init, core/housekeeping.q).
//A no-op every tick except the first, each UTC day, once time-of-day has
//passed -eodTriggerTime and the target day (.z.d + -eodDayOffset) isn't
//already promoted / already populated - then calls .oq.idb.eod[target]
//on the live primefinance idb (-idbaddr) and, only once that returns
//without error, writes target's marker file.
//@desc
.oq.hk.run:{[]
 target:.z.d+.oq.hk.dayOffset;
 if[(`time$.z.p)<.oq.hk.eodTriggerTime;:(::)];
 if[.oq.hk.alreadyPromoted[target];:(::)];
 if[.oq.hk.hasForeignData[target];
   .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD for ",(string target)," not needed: its primefinance partition already has data (e.g. a manual EOD run) - marking done, not overwriting.";
   @[{[dt] .oq.hk.markerFile[dt] set ()};target;{[e].util.log.ex[`WARN;`.oq.hk.run]"Failed to write skip-marker: ",e}];
   :(::)];
 .oq.hk.eodConnect[];
 if[null .oq.hk.idbH;:(::)];
 // the promote + marker write, as one niladic unit so .mon.job.run can
 // wrap it (RUNNING row on entry, SUCCESS/FAILED on exit -> the mon
 // `jobStatus` table -> the dashboard's JobStatus page). target reaches
 // promote via a real GLOBAL (.oq.hk.priv.target), not a closure read of
 // .oq.hk.run's own local - promote has to be genuinely niladic (passed
 // as a plain function VALUE below, no brackets) or `f[]` inside @'s
 // wrapper is no longer the only place it runs, and the eager-call bug
 // found (and fixed) in mon's own copy of this file reappears here too:
 // see modules/mon/eod_housekeeping.q's .oq.hk.run for the full writeup.
 .oq.hk.priv.target:target;
 promote:{[]
   t:.oq.hk.priv.target;
   if[`FAILED~.oq.hk.idbH (`.oq.idb.eod;t);'"idb .oq.idb.eod returned `FAILED"];
   .oq.hk.markerFile[t] set ();
   };
 ok:@[{[f] $[`run in key `.mon.job;.mon.job.run[`primefinance_eod_housekeeping;f];f[]]; 1b};promote;
   {[e].util.log.ex[`ERROR;`.oq.hk.run]"Scheduled EOD failed: ",e;0b}];
 if[not ok;:(::)];
 .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD triggered for ",string target;
 };

.oq.hk.info.eodHousekeeping.loaded:1b;
