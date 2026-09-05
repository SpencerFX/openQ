//====================================================================
// Directory: modules/mon/jobStatus.q
//
// About:
// Plain utility library, the same shape as modules/utils/generator/
// generator.q - not a process role, no cfg_proc/modules/jobStatus/,
// meant to be loaded ad hoc by whatever batch/one-shot script wants its
// start/end/success tracked (core/eod.q, a module's eod_housekeeping.q,
// or any -hkscript/cron-style job).
//
// Tracks, per named job: when it started, when it ended, how long it
// took, and whether it succeeded - kept locally in .mon.job.tab (one row
// per job, last run wins), written out via .util.log.ex[level;code;msg]
// (the exact same call core/eod.q and this module's own
// eod_housekeeping.q already make for their own INFO/WARN/ERROR notes -
// so a start/end/status line lands in the mon `logs` table too, on any
// process that has called .util.logToTab.connect), AND published as its
// own row into schemas/schema_mon.q's `jobStatus` table - one row on
// start (status RUNNING) and one on end (SUCCESS/FAILED) - the same
// tp/rdb/idb/hdb/EOD pipeline as `logs`/`pidstats`, since it's just
// another entry in .oq.schema.tables[]. The publish reuses the mon
// connection core/utils/logToTab.q already opens (.util.logToTab.
// monHandle) rather than opening a second one - a process that never
// connects to a mon tp still gets .mon.job.tab and the log lines, just
// no `jobStatus` rows.
//
// Namespaces:
//   .mon.job.*      - start/end tracking, the run[] wrapper, and
//                      read-only status lookups
//   .mon.job.priv.* - the `jobStatus` row publish, not for outside use
//====================================================================
.mon.job.info.loaded:0b;

// One row per job name, last run's start/end/duration/status - RUNNING
// while in flight, SUCCESS or FAILED once .mon.job.end has been called
.mon.job.tab:([jobName:`symbol$()] startTime:`timestamp$(); endTime:`timestamp$(); duration:`timespan$(); status:`symbol$());

//@func   | .mon.job.priv.procSym
//@return | -11 | This process's -name via .util.logToTab, or `unknown if that library isn't loaded
//@desc
//Safe accessor so this file doesn't hard-require core/utils/logToTab.q to be loaded
//@desc
.mon.job.priv.procSym:{[] @[{.util.logToTab.procName[]};`;{`unknown}]};

//@func   | .mon.job.priv.publish
//@param  | row | 99 | sym/jobName/startTime/endTime/duration/status tuple, schema column order
//@desc
//Best-effort SYNC publish of one `jobStatus row via the mon tickerplant
//handle core/utils/logToTab.q already holds (.util.logToTab.monHandle) -
//a no-op, not an error, when that library isn't loaded or never connected.
//Two things had to be fixed here empirically, not assumed, to make this
//reliable for a one-shot batch script (run.q's own use case) rather than
//just a long-running process:
//  - async (.util.ipc.async, the same call .util.logToTab.forward uses
//    for `logs`) can lose the message entirely if the caller hclose's/
//    exit's right after - fire-and-forget has no guarantee the OS has
//    actually flushed it. Fixed by using .util.ipc.sync instead.
//  - even sync alone wasn't enough: .util.logToTab.connect opens its
//    handle via the timeout form of hopen (see core/utils/ipc.q's
//    .util.ipc.hopen), and on this build a sync reply from mon's
//    tickerplant can come back to the caller before the TP's OWN
//    downstream relay to mon_cep/mon_rdb (itself async under the hood,
//    -25! in core/tp.q's .u.pub) has actually flushed - so a script that
//    gets its reply and exits immediately can still race past it.
//    Confirmed a second round-trip on the same handle reliably gives
//    that relay enough time; the harmless follow-up call below is that
//    second round-trip, not needless chatter.
// A long-running process publishing `logs` never hits either problem (it
// stays up long after sending), which is why that path looked fine while
// this one, called from a short-lived script, didn't.
//@desc
.mon.job.priv.publish:{[row]
 h:@[{.util.logToTab.monHandle};`;{0Ni}];
 if[null h;:(::)];
 @[.util.ipc.sync[h];(`upd;`jobStatus;row);{[e].util.log.ex[`WARN;`.mon.job.priv.publish]"Failed to publish jobStatus row to mon tickerplant: ",e}];
 @[h;"1+1";{[e](::)}];
 };

//@func   | .mon.job.start
//@param  | jobName | symbol | Name identifying this job (table key, and the log message's subject)
//@desc
//Records jobName's start time (.z.p) and marks it RUNNING in
//.mon.job.tab, overwriting any previous run's row; logs it (INFO,
//forwarded into the mon `logs table like any other log line) and
//publishes a RUNNING row into the mon `jobStatus table
//@desc
.mon.job.start:{[jobName]
 st:.z.p;
 `.mon.job.tab upsert (jobName;st;0Np;0Nn;`RUNNING);
 .util.log.ex[`INFO;`.mon.job.start]"Job started: ",string jobName;
 .mon.job.priv.publish[(.mon.job.priv.procSym[];jobName;st;0Np;0Nn;`RUNNING)];
 };

//@func   | .mon.job.end
//@param  | jobName | symbol  | Name previously passed to .mon.job.start
//@param  | success | boolean | Whether the job completed successfully
//@desc
//Records jobName's end time, its duration since .mon.job.start (null if
//it was never started), and SUCCESS/FAILED; logs it (INFO on success,
//ERROR on failure) and publishes the final row into the mon `jobStatus
//table. Safe to call without a matching start (logs a WARN and records a
//null duration) rather than erroring.
//@desc
.mon.job.end:{[jobName;success]
 if[not jobName in key .mon.job.tab;
    .util.log.ex[`WARN;`.mon.job.end]"Job ended with no matching start: ",string jobName];
 st:$[jobName in key .mon.job.tab;.mon.job.tab[jobName;`startTime];0Np];
 et:.z.p;
 dur:$[null st;0Nn;et-st];
 status:$[success;`SUCCESS;`FAILED];
 `.mon.job.tab upsert (jobName;st;et;dur;status);
 .util.log.ex[$[success;`INFO;`ERROR];`.mon.job.end]"Job ",(string jobName)," ended: ",(string status),", duration ",string dur;
 .mon.job.priv.publish[(.mon.job.priv.procSym[];jobName;st;et;dur;status)];
 };

//@func   | .mon.job.run
//@param  | jobName | symbol  | Name to track this call under
//@param  | f       | 100     | Niladic function to run: {[] ...}
//@return | *       | f's own result
//@desc
//Convenience wrapper: start[jobName], run f[] protected, end[jobName;
//success] either way, then return f's result on success or re-signal its
//original error on failure - so a caller sees the exact same behavior as
//calling f[] directly, plus a tracked start/end/status row and log lines
//@desc
.mon.job.run:{[jobName;f]
 .mon.job.start[jobName];
 outcome:@[{[f](1b;f[])};f;{[e](0b;e)}];
 .mon.job.end[jobName;outcome 0];
 if[not outcome 0;'outcome 1];
 outcome 1
 };

//@func   | .mon.job.status
//@param  | jobName | symbol | Name to look up
//@return | 99      | startTime/endTime/duration/status dict, status `UNKNOWN if jobName was never started
//@desc
.mon.job.status:{[jobName]
 $[jobName in key .mon.job.tab;.mon.job.tab jobName;`startTime`endTime`duration`status!(0Np;0Np;0Nn;`UNKNOWN)]
 };

//@func   | .mon.job.running
//@return | 11 | Names of every job currently in RUNNING status
//@desc
.mon.job.running:{[] exec jobName from .mon.job.tab where status=`RUNNING};

.mon.job.info.loaded:1b;
