// schema_mon.q
// Monitoring schema: the `logs table every process's core/utils/logToTab.q
// library publishes into, the `pidstats table modules/mon/
// pidstat_poller.py publishes into, and the `jobStatus table modules/mon/
// jobStatus.q's .mon.job.start/.mon.job.end publish into (one row per
// event, RUNNING at start, SUCCESS/FAILED at end). Same (timestamp, sym) convention as
// schema.q, so a "mon" stack is just another tp/rdb/hdb quartet pointed at
// this schema (-schema ../schemas/schema_mon.q) instead of the default one
// - a process calling .util.logToTab.log, or pidstat_poller.py, is a feed
// handler publishing rows into it exactly the way tests/publish.q publishes
// quote/trade rows into the default schema's tickerplant. sym holds the
// row's associated openQ process's -name where there is one (the log-writer
// for `logs`, the monitored process for `pidstats`, blank for a `pidstats`
// row about a non-openQ process on the host) - so per-process history
// partitions/filters the same way per-sym tick history does.
// Named `logs`, not `log`: `log` is a reserved q keyword (natural
// logarithm) - `log:([]...)` fails to parse as a top-level assignment.
.oq.schema.info.loaded:0b;

logs:([] timestamp:`timestamp$(); sym:`symbol$(); level:`symbol$(); host:`symbol$(); pid:`int$(); handle:`int$(); user:`symbol$(); mem:`long$(); code:`symbol$(); message:());

// One row per (host,pid) per poll, combining `pidstat -u` (CPU) and
// `pidstat -r` (memory) - see modules/mon/pidstat_poller.py. pidstatTime is
// pidstat's own sample timestamp (distinct from `timestamp, the TP's
// receipt time - the same "who stamped it, the feed or the tp" distinction
// any qpython feed handler's own timestamp column makes). procType/port
// are populated only when the
// process's command line carries openQ's own -procType/-port flags (a
// direct `init.q` invocation); an `initFromCfg.q -config <path>` invocation
// doesn't put those on the command line at all, so they're left null for
// it - `command` (the raw command line) always has the full picture either
// way, poller-parsed identity or not.
pidstats:([] timestamp:`timestamp$(); sym:`symbol$(); pidstatTime:`timestamp$(); host:`symbol$(); pid:`int$(); uid:`int$(); procType:`symbol$(); port:`int$(); userPct:`float$(); sysPct:`float$(); guestPct:`float$(); waitPct:`float$(); cpuPct:`float$(); cpuId:`int$(); minflt:`float$(); majflt:`float$(); vsz:`long$(); rss:`long$(); memPct:`float$(); threads:`int$(); fdnr:`int$(); command:());

// One row per job start/end event (modules/mon/jobStatus.q). sym is the
// publishing process's own -name, same convention as `logs/`pidstats;
// jobName is the job being tracked, distinct from sym since one process
// can run several named jobs. duration/endTime are null on the RUNNING
// row a start[] publishes; status is RUNNING, SUCCESS or FAILED.
jobStatus:([] timestamp:`timestamp$(); sym:`symbol$(); jobName:`symbol$(); startTime:`timestamp$(); endTime:`timestamp$(); duration:`timespan$(); status:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//The set of tables the mon tickerplant/RDB/HDB operate on
//(tp.q's .u.tick separately validates timestamp,sym as its first 2 columns)
//@desc
.oq.schema.tables:{[] `logs`pidstats`jobStatus};

.oq.schema.info.loaded:1b;
