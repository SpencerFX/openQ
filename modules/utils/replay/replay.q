//====================================================================
// Directory: modules/utils/replay/replay.q
//
// About:
// Paced tickerplant-log replay. Reads one or more openQ tp logs (the
// flat  (`upd;table;rows)  files core/tp.q writes under -tplogdir), then
// re-publishes every message into a LIVE tickerplant, paced against a
// simulated clock - so the markout / market-impact / spread module CEPs,
// and the dashboards reading them, see a realistic moving feed driven by
// real captured data instead of the synthetic node feeders.
//
// Unlike modules/utils/hdb2tplog/hdb2tplog.q (HDB table -> log file) and
// examples/scripts/06_replay_tplog.q (log -> in-memory tables, full
// speed, own port), this one drives a real pipeline in wall-clock time:
//
//   load phase - -11! each log with a capturing `upd` that keeps every
//     message's raw payload; after all files, assemble one table per
//     logged table in a single columnar pass (reshaping per-message is
//     O(n) allocations and far too slow for a multi-hour log)
//
//   play phase - a 100ms timer publishes, in source order, every
//     buffered row whose source timestamp is <= the sim clock
//         simClock = t0 + speed * (now - wall0)
//     to -tp. With -stamp now (the default) each row's `timestamp` (and
//     `time`, if present) is rewritten to the wall instant it now
//     represents - (wall0 + (srcTs - t0) % speed) - so intra/inter-row
//     spacing is preserved (just compressed by `speed`) AND the data
//     never looks stale to a CEP's "last N minutes" window.
//
// Plain script, not a -procType role (nothing live to subscribe to on
// load) - same shape as modules/utils/generator/generator.q. Opens -port so it
// is queryable and its .rp.* control verbs are callable over IPC; the
// openDash gateway's ReplayManager (openDash/gateway/src/replay.js)
// drives it exactly that way.
//
// Run from the repo root:
//   q modules/utils/replay/replay.q -src <dir|file> -tp :host:port \
//       -schema schemas/schema_markout.q -speed 10 -stamp now \
//       -port 5098 -lastn 6 [-loop] [-paused]
//
//   -src     a tp log file, or a directory of them (every file is read
//            in name order - openQ's 10-minute-bucket names sort right).
//            8-byte empty rotated logs are skipped.
//   -tp      :host:port of a running tickerplant started on -schema.
//            Publishing goes in via the classic `upd - same entry point
//            the node feeders and modules/utils/generator/generator.q use.
//   -schema  schema stub declaring the logged tables (empty tables, so a
//            logged column-list message can be reshaped to a table).
//   -speed   playback multiplier, realtime = 1 (default 10).
//   -stamp   now  -> rewrite timestamp/time to the wall instant each row
//                    now represents (default; keeps CEP windows happy)
//            keep -> publish original timestamps unchanged (only useful
//                    replaying a log from earlier the same day)
//   -port    this process's own listen port (default 5098).
//   -lastn   keep only the last N non-empty source files (default 6 ~=
//            one hour of a module feed); 0 = keep all. Bounds load time
//            and memory, and makes a -loop cycle a sane length.
//   -loop    when the buffer is exhausted, re-base the clock and replay
//            again from the start.
//   -paused  start paused - call .rp.resume[] to begin.
//
// Namespaces:
//   .rp.*  - arg parse, log load + columnar assemble, the paced-publish
//            timer, and the control verbs (.rp.pause / .rp.resume /
//            .rp.setSpeed / .rp.restart / .rp.status). Private helpers
//            live under .rp.priv.*
//====================================================================
.rp.info.loaded:0b;

.rp.priv.args:.Q.opt .z.x;
.rp.priv.opt:{[k;d] $[k in key .rp.priv.args; first .rp.priv.args k; d]};

.rp.cfg.src    :.rp.priv.opt[`src;""];
.rp.cfg.tp     :`$.rp.priv.opt[`tp;""];
.rp.cfg.schema :.rp.priv.opt[`schema;""];
.rp.cfg.speed  :"F"$.rp.priv.opt[`speed;"10"];
.rp.cfg.stamp  :`$.rp.priv.opt[`stamp;"now"];
.rp.cfg.port   :"J"$.rp.priv.opt[`port;"5098"];
.rp.cfg.lastn  :"J"$.rp.priv.opt[`lastn;"6"];
.rp.cfg.loop   :`loop in key .rp.priv.args;
.rp.cfg.paused :`paused in key .rp.priv.args;

if[0=count .rp.cfg.src;    '"usage: -src <dir|file> required"];
if[null .rp.cfg.tp;        '"usage: -tp :host:port required"];
if[0=count .rp.cfg.schema; '"usage: -schema <file> required"];
if[not .rp.cfg.speed>0;    '"-speed must be > 0"];
if[not .rp.cfg.stamp in `now`keep; '"-stamp must be now|keep"];

// minimal CLP stand-in so anything that introspects a running openQ
// process's own -name / -procType (openDash's /api/tables survey) gets a
// sane answer, without pulling in core/config.q for this small tool
.util.start.CLP:([name:`name`procType] val:(`$"replay_",string[.rp.cfg.port]; `rdb));

system "l ",.rp.cfg.schema;
.rp.priv.tabs:.oq.schema.tables[];
-1 "replay: schema ",.rp.cfg.schema," declares ",", " sv string .rp.priv.tabs;

//--------------------------------------------------------------------
// load phase
//--------------------------------------------------------------------

.rp.priv.raw:(`$())!();          // tab -> list of raw logged payloads

//@func | .rp.priv.capture
//@desc | -11! resolves each logged (`upd;t;x) message to this. Keep the
//        raw x (a list of column vectors in no-latency mode, or a table)
//        - assembling per-message is far too slow over a multi-hour log.
.rp.priv.capture:{[t;x]
 if[not t in .rp.priv.tabs; :()];
 .rp.priv.raw[t]:$[t in key .rp.priv.raw; .rp.priv.raw[t],enlist x; enlist x];
 };

//@func | .rp.priv.listFiles
//@desc | -src as a sorted hsym list. A single file -> itself. A
//        directory -> its non-empty entries in name order, MINUS the
//        newest one: on a running module that newest file is the
//        tickerplant's currently-open log, and replaying a log you are
//        also publishing into is a feedback loop (and it can throw mid
//        rotation). Point -src at a specific closed file to replay it.
.rp.priv.listFiles:{[src]
 s:ssr[src;"\\";"/"];
 p:hsym `$s;
 if[not 11h=type k:key p; :$[16<hcount p; enlist p; ()]];
 fs:asc hsym each `$(s,"/"),/:string k;
 fs:fs where 16 < hcount each fs;
 $[1<count fs; -1_fs; ()]
 };

//@func | .rp.priv.loadFile
//@desc | Replay one closed log's messages into .rp.priv.capture, and
//        return the count. NOTE -11! must run unprotected on this build:
//        wrapped in @[] / .Q.trp[] it raises an untrappable '- . That is
//        why .rp.priv.listFiles drops the newest (still-open) log and
//        filters empties up front - a closed, rotated openQ log never
//        has a torn tail, so a bare -11! is safe here.
.rp.priv.loadFile:{[f]
 if[not 16<hcount f; :0];
 upd::.rp.priv.capture;
 -11! f
 };

//@func | .rp.priv.assemble
//@desc | One logged table's messages -> one table, in a single columnar
//        pass: normalise each message to a list of column vectors, drop
//        any with the wrong column count, transpose so each column's
//        pieces are together, raze each, reflip to a table.
.rp.priv.assemble:{[t]
 cn:cols value t;
 ms:{$[98h=type x; value flip x; x]} each .rp.priv.raw t;
 ms:ms where (count cn) = count each ms;
 if[0=count ms; :0#value t];
 flip cn! raze each flip ms
 };

//@func | .rp.priv.load
//@desc | Full load: list files, honour -lastn, replay them, assemble
//        per-table, then build .rp.plan - one (t;tab;ix) row per source
//        row, sorted by source timestamp: the merged replay timeline.
.rp.priv.load:{[]
 fs:.rp.priv.listFiles .rp.cfg.src;
 if[0=count fs; '"replay: no usable log files under ",.rp.cfg.src];
 if[.rp.cfg.lastn>0; fs:neg[.rp.cfg.lastn] sublist fs];
 -1 "replay: loading ",string[count fs]," log file(s)";
 .rp.priv.loadFile each fs;
 seen:key .rp.priv.raw;
 if[0=count seen; '"replay: no messages for any ",.rp.cfg.schema," table in ",.rp.cfg.src];
 .rp.acc:seen! .rp.priv.assemble each seen;
 .rp.priv.raw:(`$())!();                                   // free the raw buffer
 .rp.plan:`t xasc raze {[tb] ([] t:.rp.acc[tb]`timestamp; tab:tb; ix:til count .rp.acc tb)} each seen;
 .rp.total:count .rp.plan;
 if[0=.rp.total; '"replay: loaded 0 rows"];
 .rp.t0:first .rp.plan`t;
 .rp.tN:last .rp.plan`t;
 -1 "replay: ",string[.rp.total]," row(s) across ",("," sv string seen),
    " spanning ",string[.rp.tN - .rp.t0]," (",string[`time$.rp.t0],"..",string[`time$.rp.tN],")";
 };

//--------------------------------------------------------------------
// play phase
//--------------------------------------------------------------------

.rp.h:0;                 // handle to -tp (0 = not connected)
.rp.cursor:0;            // next unsent index into .rp.plan
.rp.sent:0;             // rows published so far (cumulative, survives -loop)
.rp.loops:0;
.rp.wall0:0Np;          // wall time the current pass was re-based to
.rp.playing:0b;

//@func | .rp.priv.connect
//@desc | NB inline error-handler lambdas raise an untrappable '- on this
//        build - every @[] here uses a plain fallback value, never a
//        {handler}, and logs the failure by checking the result after.
.rp.priv.connect:{[]
 if[.rp.h>0; :.rp.h];
 .rp.h:@[hopen;(.rp.cfg.tp;5000);0];
 $[.rp.h>0;
  -1 "replay: connected to tp ",string .rp.cfg.tp;
  -2 "replay: cannot reach tp ",string .rp.cfg.tp];
 .rp.h
 };

//@func | .rp.priv.mapTs
//@desc | source timestamp -> the wall instant it now represents
.rp.priv.mapTs:{[v] .rp.wall0 + `timespan$floor ("j"$v - "j"$.rp.t0) % .rp.cfg.speed};

//@func | .rp.priv.rebase
//@desc | Set wall0 so simClock == the source time at the cursor right
//        now - i.e. resume / speed-change picks up smoothly, no jump.
.rp.priv.rebase:{[]
 tc:$[.rp.cursor<.rp.total; .rp.plan[.rp.cursor;`t]; .rp.tN];
 .rp.wall0:.z.p - `timespan$floor ("j"$tc - "j"$.rp.t0) % .rp.cfg.speed;
 };

//@func | .rp.priv.stamp
.rp.priv.stamp:{[d]
 if[not .rp.cfg.stamp=`now; :d];
 d:@[d;`timestamp;.rp.priv.mapTs];
 if[`time in cols d; d:@[d;`time;.rp.priv.mapTs]];
 d
 };

//@func | .rp.priv.pub
//@desc | Timer body: publish everything now due, grouped by table.
.rp.priv.pub:{[]
 if[not .rp.playing; :()];
 if[.rp.cursor>=.rp.total;
  $[.rp.cfg.loop;
   [.rp.loops+:1; .rp.cursor:0; .rp.priv.rebase[]; -1 "replay: loop ",string .rp.loops];
   [.rp.playing:0b; -1 "replay: finished - ",string[.rp.sent]," row(s) sent"; :()]]];
 if[.rp.h<=0; if[0>=.rp.priv.connect[]; :()]];
 simNow:.rp.t0 + `timespan$floor .rp.cfg.speed * "j"$ .z.p - .rp.wall0;
 k:(.rp.plan`t) bin simNow;                       // last index with t <= simNow
 if[k<.rp.cursor; :()];
 sub:.rp.plan .rp.cursor + til 1 + k - .rp.cursor;
 g:group sub`tab;
 {[sub;tb;pos]
  d:.rp.priv.stamp .rp.acc[tb] sub[pos;`ix];
  r:@[{neg[.rp.h](`upd;x;y); 1b}[tb];d;0b];
  if[not r; .rp.h:0; -2 "replay: publish failed - will reconnect"];
  }[sub]'[key g;value g];
 .rp.cursor+:1 + k - .rp.cursor;
 .rp.sent+:count sub;
 };

//--------------------------------------------------------------------
// control verbs (callable over IPC by the openDash ReplayManager)
//--------------------------------------------------------------------

//@func | .rp.resume
.rp.resume:{[]
 .rp.priv.connect[];
 .rp.priv.rebase[];
 .rp.playing:1b;
 -1 "replay: resume @ ",string[.rp.cfg.speed],"x";
 .rp.status[]
 };

//@func | .rp.pause
.rp.pause:{[] .rp.playing:0b; -1 "replay: pause"; .rp.status[]};

//@func | .rp.setSpeed
.rp.setSpeed:{[s]
 if[not s>0; '"speed must be > 0"];
 .rp.cfg.speed:"f"$s;
 if[.rp.playing; .rp.priv.rebase[]];
 -1 "replay: speed ",string .rp.cfg.speed;
 .rp.status[]
 };

//@func | .rp.restart
.rp.restart:{[]
 .rp.cursor:0; .rp.loops:0;
 .rp.priv.rebase[];
 -1 "replay: restart from top";
 .rp.status[]
 };

//@func | .rp.status
//@return | 99 | dict - the whole replay state, polled by the gateway
.rp.status:{[]
 (`src`tp`schema`tables`speed`stamp`loop`lastn`playing`connected,
  `total`cursor`sent`loops`pct`t0`tN`simClock`spanSec) ! (
  .rp.cfg.src; string .rp.cfg.tp; .rp.cfg.schema; string key .rp.acc;
  .rp.cfg.speed; .rp.cfg.stamp; .rp.cfg.loop; .rp.cfg.lastn;
  .rp.playing; .rp.h>0;
  .rp.total; .rp.cursor; .rp.sent; .rp.loops;
  $[.rp.total>0; `float$.rp.cursor%.rp.total; 0f];
  .rp.t0; .rp.tN;
  $[.rp.playing;
    .rp.t0 + `timespan$floor .rp.cfg.speed * "j"$ .z.p - .rp.wall0;
    $[.rp.cursor<.rp.total; .rp.plan[.rp.cursor;`t]; .rp.tN]];
  `float$("j"$.rp.tN - .rp.t0)%1e9)
 };

//--------------------------------------------------------------------
// boot
//--------------------------------------------------------------------

.rp.priv.load[];

system "p ",string .rp.cfg.port;
-1 "replay: serving on :",string[.rp.cfg.port]," - ",$[.rp.cfg.paused;"paused";"playing"],
   " @ ",string[.rp.cfg.speed],"x -> tp ",string .rp.cfg.tp;

.z.ts:{.rp.priv.pub[]};
system "t 100";

if[not .rp.cfg.paused; .rp.resume[]];

.rp.info.loaded:1b;
