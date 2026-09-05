//====================================================================
// Directory: modules/analytics/candle/run.q
//
// About:
// Standalone process: pulls one real trading day of eq_m1_yfinance
// 1-minute bars over the eq_m1_yfinance gateway, aggregates it into 10
// timeframes (1m/5m/10m/15m/30m/1h/2h/4h/8h/1d), runs candle.q's (its own
// sibling file) full 32-pattern library against every symbol at every
// timeframe, and assembles the results into candlePattern
// (schemas/schema_candlepattern.q) - then persists that table into its
// own dated HDB root via the same .oq.save.saveTable/.oq.save.eod
// pipeline every other module's EOD path uses. Not a tp/rdb/idb/hdb/cep
// pipeline and not a `-procType` role - like modules/backtest/run.q, this
// is a plain script outside core/init.q's/core/config.q's machinery,
// reaching eq_m1_yfinance purely over IPC (the gateway), the same way any
// external client would.
//
// Per-symbol scanning, not one big multi-symbol table: candle.q's pattern
// functions lean on prev/mavg (position-based over the whole column, not
// grouped by sym - confirmed by reading candle.q directly, not assumed),
// so feeding a multi-symbol table straight into .candle.signals would
// leak the tail of one symbol's window into the next symbol's leading
// bars. Confirmed safe (and the documented, tested shape - see
// backtest.q's own "this engine backtests one symbol at a time") by
// splitting each timeframe's aggregated bars via `group sym` (one fast
// vectorized split, not a where-clause scan per symbol) and running
// .candle.signals on each symbol's own sub-table.
//
// Run from the repo root (like every other modules/*/simulator.q or
// modules/backtest/run.q script - its own relative loads below are
// repo-root-relative, not core-relative):
//   q modules/analytics/candle/run.q [-gwaddr :host:port] [-date <date>]
//     [-exchange <hkex|nikkei|nyse|nasdaq>] [-hdbroot <path>]
// -gwaddr defaults to cfg_proc/modules/yfinance/eq_m1_yfinance/gw.json's own port
// (5119). -date defaults to yesterday (today's own session is still live/
// partial, not a real "whole day" to scan). -exchange defaults to every
// exchange the gateway has for that date. -hdbroot is where the resulting
// candlePattern partition is written (default C:/data/db1/ta - a
// technical-analysis-derived-data root, separate from eq_m1_yfinance's own
// C:/data/db1/eq so this never risks colliding with real ingested data).
// One call covers one date; a full backfill is one call per real trading
// date - see scripts/other/backfillCandlePattern.sh. -monaddr (default
// :localhost:5020, mon's own tp) is who the run gets reported to as a
// `candlePattern_daily` job in the mon module's `jobStatus` table (see
// modules/mon/jobStatus.q) - start on launch, end with success/failure on
// exit; best-effort, same as jobStatus.q's own design - a process that
// can't reach mon still runs the scan, it just doesn't get a jobStatus
// row for it. scripts/other/scheduleCandlePatternDaily.ps1 registers this as an
// actual Windows daily task (no -date given each run, so it always
// naturally covers "yesterday", same as the default above).
//====================================================================

system "l modules/analytics/candle/candle.q";
system "l schemas/schema_candlepattern.q";
system "l core/utils/log.q";
system "l core/utils/timer.q";
system "l core/utils/handlers.q";
system "l core/utils/start.q";
system "l core/utils/core.q";
system "l core/utils/conn.q";
system "l core/utils/ipc.q";
system "l core/save.q";
system "l core/utils/logToTab.q";
system "l modules/mon/jobStatus.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

gwAddr:  `$opt[args;`gwaddr;":localhost:5119"];
dt:      "D"$opt[args;`date;string .z.d-1];
exchArg: opt[args;`exchange;""];
hdbRoot: .util.core.toHsym opt[args;`hdbroot;"C:/data/db1/ta"];
monAddr: `$opt[args;`monaddr;":localhost:5020"];
// Tried giving this script a fake .util.start.CLP so jobStatus rows would
// carry a real `sym instead of `unknown (a real -procType process gets
// CLP populated by .util.start.refresh[], which this standalone script
// never calls) - reverted: confirmed empirically it made publishing
// unreliable (rows silently stopped reaching jobStatus at all, in both a
// name-only and a name+procType version) for a reason not fully run down
// - not worth trading working tracking for a cosmetic `sym value.
.util.logToTab.connect[monAddr];

//--------------------------------------------------------------------
// Timeframes: name -> bucket size, in nanoseconds (`long$ of a timespan) -
// bucketing a timestamp column is `timestamp$binNs*(`long$timestamp) div
// binNs, confirmed empirically on this build (xbar's usual numeric-only
// form doesn't take a temporal bucket size directly here). 1d needs no
// special case: bars for a single -date already all fall in one bucket.
//--------------------------------------------------------------------
tframes:`1m`5m`10m`15m`30m`1h`2h`4h`8h`1d;
tfSizes:0D00:01:00.000000000 0D00:05:00.000000000 0D00:10:00.000000000 0D00:15:00.000000000 0D00:30:00.000000000 0D01:00:00.000000000 0D02:00:00.000000000 0D04:00:00.000000000 0D08:00:00.000000000 1D00:00:00.000000000;
tfNs:`long$tfSizes;

patterns:.candle.patternNames;

//@func   | .cr.aggregate
//@param  | bars | table | raw 1-minute bars (timestamp,sym,exchange,open,high,low,close,volume)
//@param  | binNs | long | bucket size in nanoseconds
//@return | 98 | one row per (sym,timestamp bucket): open/high/low/close/volume/exchange
//@desc
//Standard OHLC rollup: open=first, high=max, low=min, close=last,
//volume=sum, grouped by sym and the bucket-floored timestamp
//@desc
.cr.aggregate:{[bars;binNs]
 0!select open:first open, high:max high, low:min low, close:last close, volume:sum volume, exchange:first exchange
   by sym, timestamp:`timestamp$binNs*(`long$timestamp) div binNs from bars
 };

//@func   | .cr.scanTimeframe
//@param  | bars     | table  | raw 1-minute bars
//@param  | patterns | symbol | pattern names to scan
//@param  | tf       | symbol | this timeframe's own name, e.g. `1h
//@param  | binNs    | long   | this timeframe's bucket size in nanoseconds
//@return | 99 | (elapsed;aggBarCount;symCount;signalTable)
//@desc
//Aggregates bars to tf, splits into one sub-table per symbol (group, not
//a where-clause scan per symbol - see the file header), runs
//.candle.signals on each symbol independently, and tags every fired
//signal with its exchange and timeframe
//@desc
.cr.scanTimeframe:{[bars;patterns;tf;binNs]
 t0:.z.p;
 agg:.cr.aggregate[bars;binNs];
 g:group agg`sym;
 perSym:{[agg;patterns;tf;i]
   st:agg i;
   sig:.candle.signals[st;patterns];
   $[0=count sig;
     0#([]timestamp:`timestamp$();sym:`symbol$();pattern:`symbol$();signal:`float$();exchange:`symbol$();timeframe:`symbol$());
     update exchange:first st`exchange,timeframe:tf,signal:`float$signal from sig]
  }[agg;patterns;tf] each value g;
 sigTab:raze perSym;
 (.z.p-t0;count agg;count g;sigTab)
 };

// perf/allSignals are mutated from inside the per-timeframe each-loop
// below via the explicit `perf upsert .../`allSignals set ... global-set
// form (same reason .candle.signals' own header documents: a nested
// lambda passed to each sees globals and its own params only, never an
// enclosing function's locals) - so both have to be real script-level
// globals, declared here rather than inside .cr.runDaily, or that
// each-loop would silently create/mutate an unrelated pair of globals
// while .cr.runDaily's own copies stayed empty forever.
perf:([] timeframe:`symbol$(); aggBars:`long$(); symCount:`long$(); signals:`long$(); elapsed:`timespan$());
allSignals:();

//@func   | .cr.runDaily
//@return | -7 | candlePattern's own row count
//@desc
//The full load -> scan every timeframe -> save -> report cycle for `dt` -
//wrapped as one niladic function so .mon.job.run (below) can track its
//start/end/success as a `candlePattern_daily` job the same way any other
//module's EOD job gets tracked, instead of this being a bare top-level
//script with no record of whether today's run actually happened or
//actually succeeded
//@desc
.cr.runDaily:{[]
 `perf set 0#perf;
 `allSignals set ();
 -1 "Connecting to eq_m1_yfinance gateway: ",string gwAddr;
 h:hopen gwAddr;
 t0:.z.p;
 whereC:$[count exchArg;enlist(=;`exchange;enlist `$exchArg);`];
 neg[h] (`.oq.gw.query;`eq_m1_yfinance;`;`timestamp$dt;`timestamp$dt+1D;`;whereC);
 r:h[];
 hclose h;
 if[not r[`error]~0b;'"gateway query failed: ",.Q.s1 r`error];
 bars:r`data;
 loadElapsed:.z.p-t0;
 syms:distinct bars`sym;
 -1 "Loaded ",(string count bars)," bar(s) across ",(string count syms)," symbol(s) for ",(string dt)," in ",string loadElapsed;
 if[0=count bars;'"no eq_m1_yfinance bars for ",(string dt)," - pick a real trading date with -date"];

 {[bars;patterns;i]
   tf:tframes i; ns:tfNs i;
   -1 "Scanning ",string[tf]," ...";
   res:.cr.scanTimeframe[bars;patterns;tf;ns];
   `perf upsert (tf;res[1];res[2];count res[3];res[0]);
   `allSignals set allSignals,enlist res[3];
   -1 "  ",(string res[1])," bar(s), ",(string res[2])," symbol(s), ",(string count res[3])," signal(s), ",string res[0];
  }[bars;patterns] each til count tframes;

 // .oq.save.saveTable reads `value tabName` off the table's own GLOBAL
 // (see core/eod.q's own header: "tabName IS the table's global
 // variable") - candlePattern has to be set as a real global here, not a
 // local of this function, or .oq.save.eod silently saves whatever the
 // schema-declared EMPTY global candlePattern still holds instead of the
 // rows just computed (confirmed the hard way: an earlier version of
 // this fix used a plain local assignment and it saved 0 rows).
 `candlePattern set 0!select timestamp,sym,exchange,timeframe,pattern,signal from raze allSignals;
 `candlePattern set candlePattern lj `pattern xkey select pattern,direction from .candle.meta;
 `candlePattern set `timestamp`sym`exchange`timeframe`pattern`direction`signal xcols candlePattern;

 .oq.save.eod[enlist `candlePattern;dt;hdbRoot];

 totalElapsed:.z.p-t0;
 -1 "";
 -1 "=== Performance: ",(string dt)," across eq_m1_yfinance ===";
 show perf;
 -1 "";
 -1 "Total candlePattern rows: ",string count candlePattern;
 -1 "Load: ",(string loadElapsed)," | Scan+save: ",(string totalElapsed-loadElapsed)," | Total: ",string totalElapsed;

 -1 "";
 -1 "=== Sample results ===";
 sampleTfs:`1m`15m`1h`4h`1d;
 sample:raze {[t;tf] 3 sublist select from t where timeframe=tf}[candlePattern] each sampleTfs;
 show sample;

 count candlePattern
 };

//--------------------------------------------------------------------
// Run it, tracked: .mon.job.run handles the start/end/status publish to
// jobStatus itself (see modules/mon/jobStatus.q) and re-signals the
// original error on failure after recording it - caught here (not left
// to escape the script silently) specifically so a real failure exits
// non-zero: q doesn't kill a script on an uncaught top-level error, it
// just prints and moves on to the next statement, which would otherwise
// leave a scheduled run reporting a misleading success exit code.
//--------------------------------------------------------------------
.[.mon.job.run;(`candlePattern_daily;.cr.runDaily);{[e] -2 "candlePattern_daily failed: ",e; exit 1}];

exit 0;
