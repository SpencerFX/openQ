//====================================================================
// Directory: modules/analytics/candle/efficacy.q
//
// About:
// Standalone process: answers "did the patterns actually work?" - the
// natural next step after modules/analytics/candle/run.q (which only
// answers "did a pattern fire"). For every (pattern,timeframe) in the
// already-backfilled candlePattern (C:/data/db1/ta, one call per real
// eq_m1_yfinance trading date via scripts/other/backfillCandlePattern.sh),
// measures the REAL forward return from eq_m1_yfinance after each fired
// signal - 1 bar and 5 bars ahead, same timeframe as the signal itself -
// and reports hit rate / average return per pattern. A pattern whose
// signal is genuinely predictive should show a hit rate meaningfully
// above 50% and a positive average directional return; one that's just
// firing on noise (see candle.q's own header for two real examples of
// that already found and fixed: longLine/shortLine, hangingMan/
// shootingStar) should show ~50% and ~0.
//
// Not a tp/rdb/idb/hdb/cep pipeline and not a `-procType` role - like
// run.q, this is a plain script reaching eq_m1_yfinance purely over IPC
// (the gateway) and reading candlePattern's own dated HDB root directly
// in-process (same way core/hdb.q's own .oq.hdb.loadHDB works: a bare
// `system "l" against the real root`).
//
// Direction per fired row: candlePattern's own `signal` column is either
// a signed +-100 (patterns whose shape already implies bullish/bearish,
// e.g. engulfing/morningStar - direction comes from the SIGN, not the
// static category) or a bare 1 (shape-only patterns with no signal-level
// direction, e.g. doji/marubozu/longLine - direction, if any, comes from
// .candle.meta's static category instead). Patterns whose meta direction
// is `both` AND whose signal is the bare-1 kind (marubozu, closingMarubozu,
// longLine, shortLine) carry no directional expectation at all - scored
// separately, by average |forward return| only (do they precede bigger
// moves, regardless of which way), never folded into hit rate.
//
// Run from the repo root:
//   q modules/analytics/candle/efficacy.q [-gwaddr :host:port]
//     [-taroot <path>] [-sDate <date>] [-eDate <date>] [-horizons 1,5]
// -taroot defaults to C:/data/db1/ta (candlePattern's own root - see
// modules/analytics/candle/run.q). -sDate/-eDate default to the full
// range candlePattern was backfilled over. -horizons is a comma list of
// "how many bars ahead" to measure, same timeframe as the signal.
//====================================================================

system "l modules/analytics/candle/candle.q";
system "l core/utils/log.q";
system "l core/utils/core.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

gwAddr:  `$opt[args;`gwaddr;":localhost:5119"];
taRoot:  opt[args;`taroot;"C:/data/db1/ta"];
sDate:   "D"$opt[args;`sDate;"2000.01.01"];
eDate:   "D"$opt[args;`eDate;string .z.d-1];
horizons:`long$"J"$","vs opt[args;`horizons;"1,5"];

tframes:`1m`5m`10m`15m`30m`1h`2h`4h`8h`1d;
tfSizes:0D00:01:00.000000000 0D00:05:00.000000000 0D00:10:00.000000000 0D00:15:00.000000000 0D00:30:00.000000000 0D01:00:00.000000000 0D02:00:00.000000000 0D04:00:00.000000000 0D08:00:00.000000000 1D00:00:00.000000000;
tfNs:`long$tfSizes;

//@func   | .ef.aggregate
//@param  | bars  | table | raw 1-minute bars
//@param  | binNs | long  | bucket size in nanoseconds
//@return | 98 | one row per (sym,timestamp bucket): OHLC/volume/exchange
//@desc
//Same OHLC rollup run.q uses - identical bucket alignment is what lets
//the result's timestamp column match candlePattern's own row-for-row
//@desc
.ef.aggregate:{[bars;binNs]
 0!select open:first open, high:max high, low:min low, close:last close, volume:sum volume, exchange:first exchange
   by sym, timestamp:`timestamp$binNs*(`long$timestamp) div binNs from bars
 };

//@func   | .ef.fwdReturns
//@param  | bars     | table | raw 1-minute bars, any number of symbols/dates
//@param  | binNs    | long  | this timeframe's bucket size in nanoseconds
//@param  | horizons | long  | bars-ahead list, e.g. 1 5
//@return | 98 | sym,timestamp,fwdRet<N> per horizon, per (sym,timeframe) bar
//@desc
//Aggregates to one timeframe, splits by symbol (group, not a where-scan
//per symbol), and for each symbol's own close series computes the
//forward return N bars ahead via reverse N xprev reverse (kdb+'s
//standard "look ahead N steps" idiom - confirmed empirically, not
//assumed) - null-padded at each symbol's own tail, never bleeding into
//the next symbol's bars
//@desc
.ef.fwdReturns:{[bars;binNs;horizons]
 agg:`sym`timestamp xasc .ef.aggregate[bars;binNs];
 g:group agg`sym;
 perSym:{[agg;horizons;i]
   st:agg i;
   c:st`close;
   fwdRets:{[c;n] fwd:reverse n xprev reverse c; (fwd%c)-1}[c] each horizons;
   r:flip (`$"fwdRet",/:string horizons)!fwdRets;
   (([]sym:st`sym;timestamp:st`timestamp)),'r
  }[agg;horizons] each value g;
 raze perSym
 };

//@func   | .ef.dirOf
//@param  | direction | symbol | .candle.meta's static category for this pattern
//@param  | signal    | float  | the fired row's own signal value
//@return | -7 | -1/0/1 expected direction: signal's own sign when |signal|=100, else the static category (bullish 1/bearish -1/neutral,both 0)
//@desc
.ef.dirOf:{[direction;signal]
 dirNum:`bullish`bearish`neutral`both!1 -1 0 0;
 ?[abs[signal]=100f;signum signal;dirNum direction]
 };

//--------------------------------------------------------------------
// 1) Load every raw 1-minute bar once, for the whole date range - each
//    timeframe below aggregates from this same in-memory set rather than
//    re-querying the gateway 10 times
//--------------------------------------------------------------------
-1 "Connecting to eq_m1_yfinance gateway: ",string gwAddr;
h:hopen gwAddr;
t0:.z.p;
neg[h] (`.oq.gw.query;`eq_m1_yfinance;`;`timestamp$sDate;`timestamp$eDate+1D;`;`);
r:h[];
hclose h;
if[not r[`error]~0b;'"gateway query failed: ",.Q.s1 r`error];
bars:r`data;
loadElapsed:.z.p-t0;
-1 "Loaded ",(string count bars)," bar(s) across ",(string count distinct bars`sym)," symbol(s), ",(string sDate)," to ",(string eDate)," in ",string loadElapsed;
if[0=count bars;'"no eq_m1_yfinance bars in that range"];

-1 "Loading candlePattern from ",taRoot," ...";
system "l ",taRoot;
-1 "candlePattern rows: ",string count candlePattern;

//--------------------------------------------------------------------
// 2) Per timeframe: forward returns + join against the fired signals +
//    aggregate hit rate / average return per pattern
//--------------------------------------------------------------------
metaDir:0!select pattern,direction from .candle.meta;
patternEfficacy:();
perf:([] timeframe:`symbol$(); aggBars:`long$(); fired:`long$(); joined:`long$(); elapsed:`timespan$());

{[bars;metaDir;horizons;i]
 tf:tframes i; ns:tfNs i;
 t0:.z.p;
 -1 "Scanning ",string[tf]," ...";
 fwd:.ef.fwdReturns[bars;ns;horizons];
 fired:select timestamp,sym,pattern,direction,signal from candlePattern where date within (sDate;eDate), timeframe=tf;
 joined:fired lj `sym`timestamp xkey fwd;
 joined:update expectedDir:.ef.dirOf[direction;signal] from joined;
 hCols:`$"fwdRet",/:string horizons;
 dirCols:{[joined;expectedDir;h] joined[h]*expectedDir}[joined;joined`expectedDir] each hCols;
 joined:joined,'flip (`$"dirRet",/:string horizons)!dirCols;
 directional:select from joined where expectedDir<>0, not null fwdRet1;
 nonDirectional:select from joined where expectedDir=0, not null fwdRet1;
 dStats:0!select
   n:count i,
   direction:first direction,
   directional:1b,
   hitRate1:avg 0<dirRet1,
   avgRet1Bp:10000*avg dirRet1,
   hitRate5:avg 0<dirRet5,
   avgRet5Bp:10000*avg dirRet5,
   avgAbsRet1Bp:10000*avg abs fwdRet1,
   avgAbsRet5Bp:10000*avg abs fwdRet5
   by pattern from directional where not null dirRet5;
 nStats:0!select
   n:count i,
   direction:first direction,
   directional:0b,
   hitRate1:0Nf,
   avgRet1Bp:0Nf,
   hitRate5:0Nf,
   avgRet5Bp:0Nf,
   avgAbsRet1Bp:10000*avg abs fwdRet1,
   avgAbsRet5Bp:10000*avg abs fwdRet5
   by pattern from nonDirectional where not null fwdRet5;
 tfResult:update timeframe:tf from dStats,nStats;
 `patternEfficacy set patternEfficacy,enlist tfResult;
 `perf upsert (tf;count fwd;count fired;count joined;.z.p-t0);
 -1 "  ",(string count fwd)," fwd-return bar(s), ",(string count fired)," fired signal(s), ",string .z.p-t0;
 }[bars;metaDir;horizons] each til count tframes;

patternEfficacy:raze patternEfficacy;
patternEfficacy:`pattern`timeframe`direction`directional`n`hitRate1`avgRet1Bp`hitRate5`avgRet5Bp`avgAbsRet1Bp`avgAbsRet5Bp xcols patternEfficacy;

//--------------------------------------------------------------------
// 3) Persist (a plain, non-partitioned splay - this is a summary table,
//    not a per-event log, so it doesn't belong in a dated partition the
//    way candlePattern does)
//--------------------------------------------------------------------
outDir:`$":",taRoot,"/patternEfficacy/";
.util.core.ensureDir `$":",taRoot;
outDir set .Q.en[`$":",taRoot;patternEfficacy];

//--------------------------------------------------------------------
// 4) Report
//--------------------------------------------------------------------
totalElapsed:.z.p-t0;
-1 "";
-1 "=== Performance ===";
show perf;
-1 "";
-1 "Load: ",(string loadElapsed)," | Scan+join+save: ",(string totalElapsed-loadElapsed)," | Total: ",string totalElapsed;
-1 "patternEfficacy rows: ",string count patternEfficacy;

-1 "";
-1 "=== Best hit rates (directional, n>=100, 1-bar-ahead) ===";
show 15 sublist `hitRate1 xdesc select from patternEfficacy where directional, n>=100;
-1 "";
-1 "=== Worst hit rates (directional, n>=100, 1-bar-ahead) ===";
show 15 sublist `hitRate1 xasc select from patternEfficacy where directional, n>=100;
-1 "";
-1 "=== Non-directional patterns (avg |move|, not hit rate) ===";
show `avgAbsRet1Bp xdesc select from patternEfficacy where not directional;

exit 0;
