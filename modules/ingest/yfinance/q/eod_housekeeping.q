//====================================================================
// Directory: modules/ingest/yfinance/q/eod_housekeeping.q
//
// About:
// -hkscript for a yfinance m1 module's housekeeping process: a wall-clock
// timer that triggers the SAME EOD promotion .oq.idb.eod[dt] performs
// (final pivot-and-harvest, promote a day's segments into the real dated
// HDB partition, clear -idbroot so the next day restarts at segment 0) -
// called directly via IPC on the already-running idb process (-idbaddr),
// NOT by spawning a separate standalone eod.q process.
//
// ONE script, both pipelines - eq_m1_yfinance AND fx_m1_yfinance (and any
// future yfinance m1 table) point their housekeeping.json -hkscript here.
// It never names a table: .oq.hk.table is .oq.schema.tables[] (exactly
// the one table this process's -name <table>_housekeeping resolves to -
// same procType/-name mechanism schema_yfinance.q's header documents), so
// nothing below is eq- or fx-specific beyond the two -params that differ:
//
//   -eodDayOffset  which UTC day to promote, relative to .z.d at trigger:
//                  0  (default, absent from JSON) = "today" - correct when
//                       every bar for the day is already in by the trigger
//                       time. eq_m1_yfinance: HKEX (16:00 HKT / 08:00 UTC)
//                       closes LATER in absolute UTC than Tokyo/Nikkei
//                       (15:30 JST / 06:30 UTC), so one trigger 30 min past
//                       HKEX's close (-eodTriggerTime 08:30 UTC) sees both
//                       venues' full day and nothing more will arrive.
//                  -1 fx_m1_yfinance: FX trades ~24x5, so there is NO
//                       time-of-day before 24:00 UTC when "today" is done -
//                       promoting .z.d would always truncate the tail.
//                       Instead promote the day that just CLOSED, on the
//                       first tick past -eodTriggerTime (00:00:00 UTC - the
//                       FX day ends exactly at the UTC boundary, so no
//                       buffer; same "EOD at 00:00:00 UTC" setting as
//                       modules/mon/) the next morning. By then .z.d has
//                       already rolled, so the target is .z.d - 1.
//   -eodTriggerTime earliest UTC time-of-day the promote may fire (see above).
//
// Deliberately NOT the dashboard's "Run EOD" path (core/eod.q): that one
// reads -idbroot's segments WITHOUT clearing them afterward (see its own
// header - a read-only promote, safe to run manually / for backfill but
// not meant to be looped), so a long-running idb that keeps pivoting into
// the same numbering sequence across a day boundary would have its stale
// segments re-promoted (duplicated) into the next day's partition too.
// .oq.idb.eod avoids that entirely: pivot+read+promote+clear happen as
// one atomic step inside the process that owns -idbroot and the rdb pair,
// with no window for a fresh segment to land mid-promotion the way an
// external orchestrator reading-then-clearing separately would have.
//
// Idempotency is checked against a small marker FILE this script writes
// itself right after a successful .oq.idb.eod call - NOT "does the target
// partition directory already exist", which sounds equivalent but isn't:
// .Q.chk (see load_yfinance.q / schema_yfinance.q headers) stubs an EMPTY
// <table> directory into every sibling table's partitions that lack one,
// so a date can already have a real (empty, unrelated) <table> directory
// on disk from that stubbing alone, well before this script ever runs -
// confirmed directly against the real HDB before relying on directory-
// existence, which would have silently and permanently skipped that
// date's real EOD forever. A dedicated marker (under -hdbroot/.eod_markers/
// <date>, a NON-date-named sibling dir kdb+'s partition scan skips - a
// plain file inside a date partition breaks the HDB loader outright)
// survives a housekeeping restart the same way a directory check would,
// without that false-positive risk.
//====================================================================
system "l ../schemas/schema_yfinance.q";

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
// -eodDayOffset is optional (gen_cfg.py only emits it when non-zero, e.g.
// fx's -1); absent / unparseable => 0 = promote .z.d. .oq.cfg.merge lands
// the JSON number as a string, so "J"$ it back.
.oq.hk.dayOffset:{o:@[{"J"$.util.start.CLP[`eodDayOffset][`val]};`;0N]; $[null o;0;o]}[];

// the one table this <table>_housekeeping process owns, via the same
// -name resolution schema_yfinance.q uses (.oq.schema.tables[] -> exactly
// one entry for a *_housekeeping -name). Refuse to load rather than guess
// if that isn't true.
.oq.hk.owned:.oq.schema.tables[];
if[1<>count .oq.hk.owned;
  '"eod_housekeeping: -name must be <table>_housekeeping resolving to exactly one schema table, got: ",", " sv string .oq.hk.owned];
.oq.hk.table:first .oq.hk.owned;
.oq.hk.jobName:`$string[.oq.hk.table],"_eod_housekeeping";

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
//.oq.save.publish's atomic rename). Lives under a NON-date-named sibling
//directory so the standard partitioned-directory scan skips it (see this
//file's header).
//@desc
.oq.hk.markerFile:{[dt] .Q.dd[.oq.hk.hdbRoot;] (`$".eod_markers";`$string dt)};

//@func   | .oq.hk.alreadyPromoted
//@param  | dt | date
//@return | -1 | true if .oq.hk.markerFile[dt] exists
//@desc
//The authoritative idempotency check - reads a marker this script itself
//controls (not internal state), so a housekeeping restart mid-day can't
//cause a duplicate .oq.idb.eod call.
//@desc
.oq.hk.alreadyPromoted:{[dt] not ()~key .oq.hk.markerFile[dt]};

//@func   | .oq.hk.hasForeignData
//@param  | dt | date
//@return | -1 | true if dt's .oq.hk.table partition already has real rows
//                from something OTHER than this script's own .oq.idb.eod
//@desc
//A second, independent safety check alongside .oq.hk.alreadyPromoted:
//that one only catches a date THIS script already promoted; this one
//catches a date something ELSE already populated first - concretely,
//modules/ingest/yfinance/ backfill.py + to_kdb.py (--cadence m1) as a
//historical bulk-loader, which can legitimately already cover -hdbroot's
//most recent dates (including "today"). Without this check, a scheduled
//.oq.idb.eod call would silently overwrite a fully legitimate, already-
//complete trading day's real data with whatever this book's own live
//idb/rdb pipeline happened to accumulate for the same date - which could
//be far less, or nothing at all, if the live feed only started partway
//through the day (or hasn't started yet). No marker file means THIS
//script never touched dt; real rows already present means someone/
//something else did.
//@desc
.oq.hk.hasForeignData:{[dt]
 p:.Q.dd[.oq.hk.hdbRoot;] (`$string dt;.oq.hk.table);
 if[()~key p;:0b];
 0<@[{count get .Q.dd[x;`sym]};p;{[e]0}]
 };

//@func   | .oq.hk.run
//@desc
//Timer callback (registered on -hkfreq by .oq.hk.init, core/housekeeping.q):
//a no-op every tick except the first one, each day, where UTC time-of-day
//has passed -eodTriggerTime and the target day (.z.d + -eodDayOffset)
//isn't already promoted / already populated - then calls .oq.idb.eod on
//the live idb process (-idbaddr) and, only once that returns without
//error, writes the target day's marker file.
//@desc
.oq.hk.run:{[]
 target:.z.d+.oq.hk.dayOffset;
 if[(`time$.z.p)<.oq.hk.eodTriggerTime;:(::)];
 if[.oq.hk.alreadyPromoted[target];:(::)];
 if[.oq.hk.hasForeignData[target];
   .util.log.ex[`WARN;`.oq.hk.run]"Skipping scheduled EOD for ",(string target),": its ",(string .oq.hk.table)," partition already has real data from something other than this script (e.g. the historical backfill loader) - not overwriting. Marking done. Investigate and promote manually if this is genuinely expected.";
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
 //
 // target has to reach promote via a real GLOBAL (.oq.hk.priv.target),
 // not a closure read of .oq.hk.run's own local - confirmed the hard way
 // in the mon copy of this script: `promote[target]` intending a
 // deferred, bound projection actually made a full, IMMEDIATE call (one
 // param, one arg), so promote ran - and could throw - while still
 // constructing @'s own argument, before @'s trap even existed, turning
 // the intended `@[f;x;errFn]` protected call into plain 2-arg indexing
 // with no protection. promote is genuinely niladic now, passed as a
 // plain function VALUE (no brackets), so `f[]` inside the wrapper is the
 // only place it runs, safely inside @'s protection.
 .oq.hk.priv.target:target;
 promote:{[]
   t:.oq.hk.priv.target;
   if[`FAILED~.oq.hk.idbH (`.oq.idb.eod;t);'"idb .oq.idb.eod returned `FAILED"];
   .oq.hk.markerFile[t] set ();
   };
 ok:@[{[f] $[`run in key `.mon.job;.mon.job.run[.oq.hk.jobName;f];f[]]; 1b};promote;
   {[e].util.log.ex[`ERROR;`.oq.hk.run]"Scheduled EOD failed: ",e;0b}];
 if[not ok;:(::)];
 .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD triggered for ",(string .oq.hk.table)," ",string target;
 };

.oq.hk.info.eodHousekeeping.loaded:1b;
