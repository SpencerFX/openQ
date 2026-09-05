//====================================================================
// Directory: modules/mon/eod_housekeeping.q
//
// About:
// -hkscript for the mon module's housekeeping process: a wall-clock
// timer that promotes each completed UTC day's `logs`/`pidstats` into
// the real dated HDB partition (C:/data/db1/mon) by calling
// .oq.idb.eod[dt] via IPC on the already-running mon idb (-idbaddr) -
// final pivot-and-harvest, promote the day's segments, clear -idbroot so
// the next day restarts at segment 0. Same mechanism eq_m1_yfinance's
// housekeeping uses (modules/ingest/yfinance/q/eod_housekeeping.q); this is
// the generic, table-agnostic version - it drives .oq.schema.tables[]
// rather than naming a table, so nothing here is mon-specific beyond the
// schema it loads.
//
// Deliberately NOT the dashboard's "Run EOD" path (core/eod.q): that one
// reads -idbroot's segments WITHOUT clearing them, so a long-running idb
// that keeps pivoting into the same numbering sequence across a day
// boundary would re-promote (duplicate) stale segments into the next
// day's partition. .oq.idb.eod does pivot+read+promote+clear as one
// atomic step inside the process that owns -idbroot and the rdb pair.
//
// Trigger semantics: the timer promotes the day that has just ENDED
// (.z.d - 1), because by the time a post-midnight tick runs .z.d has
// already rolled to the new day. -eodTriggerTime (default 00:00:00.000
// UTC) is the earliest wall-clock time-of-day, on the day after the one
// being promoted, at which the promote is allowed to fire - the default
// means "first tick of each new UTC day promotes the day that closed".
// Raise it only if you want to defer the roll to later in the morning;
// do NOT set it near the end of the day or you would promote a day
// that isn't over yet.
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
system "l ../schemas/schema_mon.q";

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
.oq.hk.idbH:0Ni;

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
//something ELSE populated first (e.g. a manual mon_eod run, or a
//restored partition). Without it, a scheduled .oq.idb.eod call for an
//already-published date would fail .oq.save.publish's atomic rename.
//When it fires, .oq.hk.run drops a marker so the date goes quiet rather
//than being re-checked (and re-logged) every tick. Checks each table's
//`sym column file - both mon schema tables carry one.
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
//passed -eodTriggerTime and the day that just ended (.z.d - 1) isn't
//already promoted / already populated - then calls .oq.idb.eod[target]
//on the live mon idb (-idbaddr) and, only once that returns without
//error, writes target's marker file.
//@desc
.oq.hk.run:{[]
 target:.z.d-1;
 if[(`time$.z.p)<.oq.hk.eodTriggerTime;:(::)];
 if[.oq.hk.alreadyPromoted[target];:(::)];
 if[.oq.hk.hasForeignData[target];
   .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD for ",(string target)," not needed: its mon partition already has data (e.g. a manual mon_eod run) - marking done, not overwriting.";
   @[{[dt] .oq.hk.markerFile[dt] set ()};target;{[e].util.log.ex[`WARN;`.oq.hk.run]"Failed to write skip-marker: ",e}];
   :(::)];
 .oq.hk.eodConnect[];
 if[null .oq.hk.idbH;:(::)];
 // the promote + marker write, as one niladic unit so .mon.job.run can
 // wrap it (RUNNING row on entry, SUCCESS/FAILED on exit -> the mon
 // `jobStatus` table -> the dashboard's JobStatus page). A signal from
 // here (idb returned `FAILED, or the marker write threw) leaves no
 // marker file, so the next tick retries the whole promote - unchanged
 // from before jobStatus tracking. jobStatus.q absent => run it plain.
 // target (a bound projection below, not the bare function) - a nested
 // lambda here can't see .oq.hk.run's own locals, only true globals and
 // its own params/closure, so target must be bound in before it's handed
 // off rather than referenced free inside promote's body.
 promote:{[target]
   if[`FAILED~.oq.hk.idbH (`.oq.idb.eod;target);'"idb .oq.idb.eod returned `FAILED"];
   .oq.hk.markerFile[target] set ();
   };
 ok:@[{[f] $[`run in key `.mon.job;.mon.job.run[`mon_eod_housekeeping;f];f[]]; 1b}[promote[target]];
   {[e].util.log.ex[`ERROR;`.oq.hk.run]"Scheduled EOD failed: ",e;0b}];
 if[not ok;:(::)];
 .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD triggered for ",string target;
 };

.oq.hk.info.eodHousekeeping.loaded:1b;
