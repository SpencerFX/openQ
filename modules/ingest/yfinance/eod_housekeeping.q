//====================================================================
// Directory: modules/ingest/yfinance/eod_housekeeping.q
//
// About:
// -hkscript for eq_m1_yfinance's housekeeping process: a wall-clock timer
// that triggers the SAME EOD promotion .oq.idb.eod[dt] performs (final
// pivot-and-harvest, promote today's segments into the real dated HDB
// partition, clear -idbroot so tomorrow restarts at segment 0) - called
// directly via IPC on the already-running idb process (-idbaddr), NOT by
// spawning a separate standalone eod.q process. Deliberately not the
// dashboard's "Run EOD" path (core/eod.q) - that one reads -idbroot's
// segments WITHOUT clearing them afterward (see its own header - a
// read-only promote, safe to run manually/for backfill but not meant to
// be looped), so a long-running idb that keeps pivoting into the same
// numbering sequence across a day boundary would have its stale segments
// re-promoted (duplicated) into the NEXT day's partition too. .oq.idb.eod
// avoids that entirely: pivot+read+promote+clear all happen as one
// atomic step inside the process that actually owns -idbroot and the
// rdb pair, with no window for a fresh segment to land mid-promotion the
// way an external orchestrator reading-then-clearing separately would have.
//
// HKEX (16:00 HKT / 08:00 UTC) closes LATER than Tokyo/Nikkei (15:30 JST
// / 06:30 UTC) in absolute UTC terms, even though Tokyo's local close
// time-of-day reads earlier - so one trigger anchored after HKEX's close
// (-eodTriggerTime, default 08:30:00.000 UTC, a 30-minute buffer past
// HKEX's actual close) covers both exchanges' full trading day.
//
// Idempotency is checked against a small marker FILE this script writes
// itself right after a successful .oq.idb.eod call - NOT "does today's
// partition directory already exist", which sounds equivalent but isn't:
// .Q.chk (see load_eq_m1_yfinance.q/schema_eq.q's own header) stubs an
// EMPTY eq_m1_yfinance directory into every eq_d1_yfinance partition
// that's missing one, and vice versa, so a date can already have a real
// (empty, unrelated) eq_m1_yfinance directory on disk from that stubbing
// alone, well before this script ever runs - confirmed directly against
// the real HDB before relying on directory-existence, which would have
// silently and permanently skipped that date's real EOD forever. A
// dedicated marker survives a housekeeping restart the same way a
// directory check would, without that false-positive risk.
//====================================================================
system "l ../schemas/schema_eq_m1_yfinance.q";

.oq.hk.info.eodHousekeeping.loaded:0b;

.oq.hk.idbAddr:`$.util.start.CLP[`idbaddr][`val];
.oq.hk.hdbRoot:.util.core.toHsym .util.start.CLP[`hdbroot][`val];
.oq.hk.eodTriggerTime:"T"$.util.start.CLP[`eodTriggerTime][`val];
.oq.hk.idbH:0Ni;

//@func   | .oq.hk.eodConnect
//@desc
//Reuses .oq.hk.idbH if it's still a genuinely live handle (checked
//against key .z.W, not just non-null - see this session's own rdb/tp
//handle-liveness lesson), else reopens via .util.ipc.hopen.
//@desc
.oq.hk.eodConnect:{[]
 if[(not null .oq.hk.idbH) and .oq.hk.idbH in key .z.W;:(::)];
 .oq.hk.idbH:@[.util.ipc.hopen;.oq.hk.idbAddr;
   {[a;e].util.log.ex[`WARN;`.oq.hk.eodConnect]"Could not connect to idb ",(string a)," for scheduled EOD: ",e;0Ni}[.oq.hk.idbAddr]];
 };

//@func   | .oq.hk.markerFile
//@param  | dt | date
//@return | -11 | hsym of dt's marker file under -hdbroot
//@desc
//A small file this script writes itself, right after a successful
//.oq.idb.eod call for dt - the sole idempotency signal (see this file's
//header on why a bare directory-existence check isn't safe here).
//Deliberately lives under a NON-date-named sibling directory
//(-hdbroot/.eod_markers/<date>), not inside the date partition itself -
//confirmed directly that the latter breaks kdb+'s own HDB loader outright
//(it treats every entry under a date partition as a table directory and
//expects a real .d column-order file inside it; a plain marker file
//there crashes the whole HDB's \l on next load/reload with a bare OS
//"path not found"). ".eod_markers" doesn't look like a partition value
//(a date/int/etc.), so the standard partitioned-directory scan skips it.
//@desc
.oq.hk.markerFile:{[dt] .Q.dd[.oq.hk.hdbRoot;] (`$".eod_markers";`$string dt)};

//@func   | .oq.hk.alreadyPromoted
//@param  | dt | date
//@return | -1 | true if .oq.hk.markerFile[dt] exists
//@desc
//The authoritative idempotency check - reads a marker this script itself
//controls (not internal state), so a housekeeping restart mid-day can't
//cause a duplicate .oq.idb.eod call (which would collide with
//.oq.save.publish's atomic rename for an already-published date).
//@desc
.oq.hk.alreadyPromoted:{[dt] not ()~key .oq.hk.markerFile[dt]};

//@func   | .oq.hk.hasForeignData
//@param  | dt | date
//@return | -1 | true if dt's eq_m1_yfinance partition already has real
//                rows from something OTHER than this script's own
//                .oq.idb.eod calls
//@desc
//A second, independent safety check alongside .oq.hk.alreadyPromoted:
//that one only catches a date THIS script already promoted; this one
//catches a date something ELSE already populated first - concretely,
//modules/ingest/yfinance/m1_backfill.py + m1_to_kdb.py's historical
//bulk-loader, which can legitimately already cover -hdbroot's most
//recent dates (including "today", .z.d, verified directly: the real
//backfill here already extended through the current UTC date the first
//time this was tested). Without this check, a scheduled .oq.idb.eod call
//would silently overwrite a fully legitimate, already-complete trading
//day's real data with whatever this book's own live idb/rdb pipeline
//happened to accumulate for the same date - which could be far less, or
//nothing at all, if the live feed only started partway through the day
//(or hasn't started yet). No marker file means THIS script never touched
//dt; real rows already present means someone/something else did.
//@desc
.oq.hk.hasForeignData:{[dt]
 p:.Q.dd[.oq.hk.hdbRoot;] (`$string dt;`eq_m1_yfinance);
 if[()~key p;:0b];
 0<@[{count get .Q.dd[x;`sym]};p;{[e]0}]
 };

//@func   | .oq.hk.run
//@desc
//Timer callback (registered on -hkfreq by .oq.hk.init, core/housekeeping.q):
//a no-op every tick except the first one, each day, where UTC time-of-day
//has passed -eodTriggerTime and today isn't already promoted - then calls
//.oq.idb.eod[.z.d] on the live idb process (-idbaddr) and, only once that
//returns without error, writes today's marker file.
//@desc
.oq.hk.run:{[]
 today:.z.d;
 if[(`time$.z.p)<.oq.hk.eodTriggerTime;:(::)];
 if[.oq.hk.alreadyPromoted[today];:(::)];
 if[.oq.hk.hasForeignData[today];
   .util.log.ex[`WARN;`.oq.hk.run]"Skipping scheduled EOD for ",(string today),": its eq_m1_yfinance partition already has real data from something other than this script (e.g. the historical backfill loader) - not overwriting. Investigate and promote manually if this is genuinely expected.";
   :(::)];
 .oq.hk.eodConnect[];
 if[null .oq.hk.idbH;:(::)];
 r:@[.oq.hk.idbH;(`.oq.idb.eod;today);
   {[e].util.log.ex[`ERROR;`.oq.hk.run]"Scheduled EOD call failed: ",e;`FAILED}];
 if[r~`FAILED;:(::)];
 @[{[dt] .oq.hk.markerFile[dt] set ()};today;
   {[e].util.log.ex[`WARN;`.oq.hk.run]"EOD succeeded but writing the marker file failed (next tick will retry the whole promote): ",e}];
 .util.log.ex[`INFO;`.oq.hk.run]"Scheduled EOD triggered for ",string today;
 };

.oq.hk.info.eodHousekeeping.loaded:1b;
