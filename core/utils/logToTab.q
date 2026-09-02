//====================================================================
// Directory: core/utils/logToTab.q
//
// About:
// Sends every log message not just to stdout/stderr and the local
// in-memory ring buffer (core/utils/log.q's job) but to a `logs` table -
// either a dedicated "mon" tickerplant's table, reached over IPC the same
// way any feed handler publishes ticks into a TP, or (if never connected)
// nowhere, in which case this behaves exactly like plain .util.log.ex
// always has. Table shape: schemas/schema_mon.q. (Named `logs`, not
// `log` - `log` is a reserved q keyword, the natural logarithm function.)
//
// Guiding principles (see the KX "Logging Best Practices in kdb+" blog):
// every row carries a full banner - timestamp, process name, level, host,
// PID, handle, user, memory usage, and message - so a central `logs` table
// can be grepped/queried the same way a single process's log file can,
// across every process publishing into it.
//
// Usage - load after utils/log.q (reuses its level thresholds and
// timestamp/memory formatting) and utils/start.q (reads the process's
// -name for the sym column):
//   system "l utils/logToTab.q";
//   .util.logToTab.connect[`:host:port];      / a mon tickerplant's address
//   .util.logToTab.log[`WARN;`MY_W001;"message text"];
//
// Namespaces:
//   .util.logToTab.* - local write + ring buffer, mon connect/reconnect,
//                       row-shape builder, forwarding log call
//====================================================================
.util.logToTab.info.loaded:0b;

//Handle to the mon tickerplant this process forwards `logs rows to, 0Ni if not connected
.util.logToTab.monHandle:0Ni;

//Address of the mon tickerplant, ` if .connect was never called
.util.logToTab.monAddr:`;

//@func   | .util.logToTab.procName
//@return | -11 | This process's -name, or `unknown if start.q isn't loaded/configured
//@desc
//Safe accessor so this library doesn't hard-require utils/start.q to have run
//@desc
.util.logToTab.procName:{[] @[{.util.start.CLP[`name][`val]};`;{`unknown}]};

//@func   | .util.logToTab.connect
//@param  | address | -11 | `:host:port of the mon tickerplant hosting the `logs table
//@return | -6 | Handle opened, or 0Ni on failure
//@desc
//Opens (or reopens) the connection to the mon tickerplant
//@desc
.util.logToTab.connect:{[address]
 .util.logToTab.monAddr:address;
 // DEBUG, not WARN: this runs on a 30s retry timer, and a process with no
 // mon stack (a bare `q init.q` with the default -logtabaddr) would
 // otherwise spam stderr forever. .oq.*.init logs an INFO breadcrumb once.
 .util.logToTab.monHandle:@[.util.ipc.hopen;(address;5000);{[a;e].util.log.ex[`DEBUG;`.util.logToTab.connect]"mon tickerplant ",(string a)," not reachable yet: ",e;0Ni}[address]];
 };

//@func   | .util.logToTab.reconnect
//@desc
//Timer callback: retries the mon tickerplant connection if it's currently down
//@desc
.util.logToTab.reconnect:{[]
 if[and[not .util.logToTab.monAddr~`;null .util.logToTab.monHandle];.util.logToTab.connect[.util.logToTab.monAddr]];
 };

//@func   | .util.logToTab.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//Marks the mon connection dead on disconnect, so the reconnect timer picks it back up
//@desc
.util.logToTab.ZPC:{[zpc;W]
 if[W=.util.logToTab.monHandle;.util.logToTab.monHandle:0Ni];
 zpc[W]
 };
// Registered once (see the write-wrap guard at the end of this file for why
// - a second `system "l" of this file must not double-register the .z.pc
// handler or the reconnect timer).
if[not `baseWrite in key `.util.logToTab;
   .util.logToTab.info.handlers.zpc:.util.handlers.add[`.z.pc;`.util.logToTab.ZPC];
   .util.logToTab.info.timer.reconnect:.util.timer.add[.z.p;0Wp;0D00:00:30;`.util.logToTab.reconnect;`DEF;"logToTab reconnect to mon tickerplant"]
  ];

//@func   | .util.logToTab.row
//@param  | logMsg | 99 | The dict returned by .util.log.ex/.util.log.memEx (time/PID/level/mem/code/msg)
//@return | 99 | One schemas/schema_mon.q `logs-shaped row, as a dict (column order matters - see .util.logToTab.log)
//@desc
//Builds one row for the mon `logs table from an already-written local log
//message, adding the process/host/handle/user context the banner needs
//that a single process's own log line doesn't otherwise carry
//@desc
.util.logToTab.row:{[logMsg]
 `timestamp`sym`level`host`pid`handle`user`mem`code`message!(
   logMsg`time;
   .util.logToTab.procName[];
   logMsg`level;
   `$string .z.h;
   logMsg`PID;
   .z.w;
   `$string .z.u;
   logMsg`mem;
   logMsg`code;
   logMsg`msg)
 };

//@func   | .util.logToTab.log
//@param  | level | -11 | symbol log level (FATAL/ERROR/WARN/INFO/DEBUG)
//@param  | code  | -11 | symbol code
//@param  | msg   | 10  | string log message
//@desc
//Writes locally via .util.log.memEx (stdout/stderr + the in-memory ring
//buffer, unchanged) and, if connected to a mon tickerplant, async-publishes
//the same message as one row into its `logs table. A process that never
//calls .connect behaves exactly as if this file wasn't loaded.
//
//Published as a flat value tuple in schema column order (the classic
//single-row tick.q feed handler convention - e.g. neg[h](`upd;`trade;data)),
//not a dict: .u.updNL only recognizes a single-row publish when the first
//element's type is a negative (atom) type, which a dict's first-value
//would only accidentally satisfy, so the flat tuple is the reliable shape.
//@desc
.util.logToTab.log:{[level;code;msg]
 logMsg:.util.log.memEx[level;code;msg];
 if[not null .util.logToTab.monHandle;
    row:value .util.logToTab.row[logMsg];
    @[.util.ipc.async[.util.logToTab.monHandle];(`upd;`logs;row);{[e].util.log.ex[`WARN;`.util.logToTab.log]"Failed to publish log row to mon tickerplant: ",e}]
   ];
 logMsg
 };

//Max `logs rows this process will forward to the mon tp in any one wall
//second. A safety valve, NOT a normal-operation limit: a process that
//genuinely logs faster than this is either malfunctioning or caught in a
//feedback loop (e.g. a per-publish-attempt `.u.pub WARN on a flapping
//subscriber, forwarded into the very `logs stream a mon CEP then relays -
//how a runaway to ~1e6 rows/minute was first hit). Excess rows are dropped
//and the drop count noted to stderr once per second.
.util.logToTab.maxPerSec:50;
.util.logToTab.priv.sec:0Nj;
.util.logToTab.priv.n:0;
.util.logToTab.priv.dropped:0;

//@func   | .util.logToTab.priv.allow
//@return | -1 | 1b if this forward is within .util.logToTab.maxPerSec for the current second
//@desc
//Per-second token check. Rolls the window on a new second, flushing any
//accumulated drop count to stderr (never through .util.log.*).
//@desc
.util.logToTab.priv.allow:{[]
 s:`long$`second$.z.p;
 if[not s=.util.logToTab.priv.sec;
    if[.util.logToTab.priv.dropped>0;
       -2 "logToTab: rate limit hit - dropped ",(string .util.logToTab.priv.dropped)," log row(s) that second"];
    .util.logToTab.priv.sec:s; .util.logToTab.priv.n:0; .util.logToTab.priv.dropped:0];
 $[.util.logToTab.priv.n<.util.logToTab.maxPerSec;
   [.util.logToTab.priv.n+:1; 1b];
   [.util.logToTab.priv.dropped+:1; 0b]] };

//@func   | .util.logToTab.forward
//@param  | logMsg | 99 | a .util.log.write return dict (time/PID/level/mem/code/msg)
//@desc
//Best-effort async publish of one already-written log message into the
//connected mon tickerplant's `logs table. No-op when not connected, when
//the message is below this process's own log-level threshold (so a raised
//-logLevel doesn't flood the central table with DEBUG chatter), or when
//.util.logToTab.maxPerSec has been exceeded this second.
//
//Publishes the 9 columns AFTER `timestamp (sym..message) - core/tp.q's
//.u.upd (both modes) prepends .z.p as the arrival stamp for a flat
//single-row list publish, exactly as every other feed handler relies on,
//so sending the full 10-wide row would push an extra value.
//
//Its failure handler goes straight to stderr, never back through
//.util.log.* - that path is the one being wrapped, and routing a forward
//failure through it would recurse.
//@desc
.util.logToTab.forward:{[logMsg]
 if[null .util.logToTab.monHandle;:(::)];
 if[.util.log.level < .util.log.levels logMsg`level;:(::)];
 if[not .util.logToTab.priv.allow[];:(::)];
 @[.util.ipc.async[.util.logToTab.monHandle];
   (`upd;`logs;1_value .util.logToTab.row[logMsg]);
   {[e] -2 "logToTab: failed to forward a log row to the mon tickerplant: ",e}];
 };

// Splice .util.logToTab.forward into the single sink EVERY log call funnels
// through: .util.log.ex / .util.log.memEx / .util.log.exSig all bottom out
// in .util.log.write. Loading this file (+ a live .connect) is therefore
// the whole mechanism - no call site anywhere changes, and a process that
// never connects behaves exactly as if this file wasn't loaded. Guarded so
// a second `system "l utils/logToTab.q"` can't double-wrap (baseWrite would
// otherwise become the already-wrapped writer).
if[not `baseWrite in key `.util.logToTab;
   .util.logToTab.baseWrite:.util.log.write;
   .util.log.write:{[level;code;msg]
     logMsg:.util.logToTab.baseWrite[level;code;msg];
     .util.logToTab.forward[logMsg];
     logMsg }
  ];

.util.logToTab.info.loaded:1b;
