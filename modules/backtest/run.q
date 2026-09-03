//====================================================================
// Directory: modules/backtest/run.q
//
// About:
// Runs a strategy pipeline from backtest.q (its own sibling file)
// against real 1-minute FX bars from the EFX historical archive
// (schemas/schema_efx.q's fx_m1_massive - see the README's "Integrating
// an existing HDB" and "Backtesting" sections) and prints a performance
// report. Not a tp/rdb/idb/hdb/cep pipeline and not a `-procType` role -
// like modules/utils/generator/generator.q, this is a plain script outside
// core/init.q's/core/config.q's machinery entirely, since there's
// nothing live to subscribe to (the archive is static, on disk). Loads
// the archive directly in-process the same way core/hdb.q's own
// .oq.hdb.loadHDB does (schema stub first, then `system"l"` against the
// real root, which transparently replaces the stub) - strictly
// READ-ONLY, exactly like tests/sh/run_efx_test.sh's own guarantee:
// nothing here ever calls a save/checkpoint/EOD function against
// -efxroot.
//
// backtest.q's engine is a four-stage pipeline (alpha ->
// portfolio construction -> risk management -> execution, modeled on
// QuantConnect LEAN's Algorithm Framework - see that file's own header)
// - this script is the demonstration that the four stages are actually
// independently swappable from the outside, with zero code changes:
// -strategy picks the alpha, -portfolio/-risk/-execution pick the other
// three (each defaulting to the pipeline's own built-in default if
// omitted), and any combination composes.
//
// Run from the repo root (like every other modules/*/simulator.q script -
// its own relative loads below are repo-root-relative, not core-relative):
//   q modules/backtest/run.q [-efxroot <path>] [-sym <sym>]
//     [-sDate <date>] [-eDate <date>]
//     [-strategy sma|meanrev|momentum|candle] [-fastN <n>] [-slowN <n>]
//       [-lookback <n>] [-zEntry <f>] [-pattern <name>]
//     [-portfolio direction|confweighted]
//     [-risk none|maxpos|maxdd] [-maxAbsPos <f>] [-ddLimit <f>]
//     [-execution immediate|twap] [-phaseIn <n>]
//     [-costBp <f>] [-lag <n>] [-barsPerYear <f>]
// -efxroot defaults to C:/data/db1/efx, matching run_efx_test.sh's own
// EFX_ROOT default. -sym/-sDate/-eDate default to a symbol/window
// already confirmed to have real 1-minute bar data (aud_cad, all of
// January 2020) - point them at any other real symbol/date range in the
// archive. -lookback is shared by meanrev and momentum (each reads it
// independently - they're never selected together). -pattern is only
// read when -strategy candle is chosen - any name from
// modules/analytics/candle/candle.q's .candle.patternNames (default hammer).
//
// Example - swap in a risk overlay and a slower execution style with no
// code changes:
//   q modules/backtest/run.q -strategy momentum -portfolio confweighted \
//     -risk maxdd -ddLimit 0.05 -execution twap -phaseIn 5
//====================================================================

system "l modules/backtest/backtest.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

efxroot: opt[args;`efxroot;"C:/data/db1/efx"];
symArg:   `$opt[args;`sym;"aud_cad"];
sDate:  "D"$opt[args;`sDate;"2020.01.01"];
eDate:  "D"$opt[args;`eDate;"2020.01.31"];
strategy:   opt[args;`strategy;"sma"];
portfolio:  opt[args;`portfolio;"direction"];
risk:       opt[args;`risk;"none"];
execution:  opt[args;`execution;"immediate"];
fastN:    "J"$opt[args;`fastN;"5"];
slowN:    "J"$opt[args;`slowN;"20"];
lookback: "J"$opt[args;`lookback;"20"];
zEntry:   "F"$opt[args;`zEntry;"1.5"];
pattern:  `$opt[args;`pattern;"hammer"];
maxAbsPos:"F"$opt[args;`maxAbsPos;"0.5"];
ddLimit:  "F"$opt[args;`ddLimit;"0.05"];
phaseIn:  "J"$opt[args;`phaseIn;"5"];
costBp:   "F"$opt[args;`costBp;"1"];
lag:      "J"$opt[args;`lag;"1"];
barsPerYear: "F"$opt[args;`barsPerYear;"132480"]; / 252 trading days * 24h * 60min - see README "Backtesting"

//---------------------------------------------------------------
// Load the archive - schema stub first (so .oq.schema.tables[] and
// each table's shape are defined even if a date/sym has no data),
// then the real on-disk root, which system"l" transparently overlays
// onto the stub. Never written to.
//---------------------------------------------------------------
system "l schemas/schema_efx.q";
-1 "Loading EFX archive (read-only): ",efxroot;
system "l ",efxroot;

bars:0!select from fx_m1_massive where date within (sDate;eDate), sym=symArg;
-1 "Loaded ",(string count bars)," bar(s) for ",(string symArg)," from ",(string sDate)," to ",string eDate;
if[0=count bars;
  -1 "No data for this symbol/date range - try a different -sym/-sDate/-eDate.";
  exit 1
  ];

cfg:`costBp`lag`maxAbsPos`ddLimit`phaseIn!(costBp;lag;maxAbsPos;ddLimit;phaseIn);
statsCfg:enlist[`barsPerYear]!enlist barsPerYear;

alphaFn:$[strategy~"sma";
  {[b] .bt.alphas.smaCrossover[b;fastN;slowN]};
 strategy~"meanrev";
  {[b] .bt.alphas.meanReversion[b;lookback;zEntry]};
 strategy~"momentum";
  {[b] .bt.alphas.momentum[b;lookback]};
 strategy~"candle";
  {[b;pattern] .bt.alphas.candlePattern[b;pattern]}[;pattern];
 '"unknown -strategy '",strategy,"' - expected sma, meanrev, momentum, or candle"
 ];

portfolioFn:$[portfolio~"direction";`.bt.portfolio.direction;
 portfolio~"confweighted";`.bt.portfolio.confidenceWeighted;
 '"unknown -portfolio '",portfolio,"' - expected direction or confweighted"
 ];

riskFn:$[risk~"none";`.bt.risk.none;
 risk~"maxpos";`.bt.risk.maxPosition;
 risk~"maxdd";`.bt.risk.maxDrawdown;
 '"unknown -risk '",risk,"' - expected none, maxpos, or maxdd"
 ];

executionFn:$[execution~"immediate";`.bt.execution.immediate;
 execution~"twap";`.bt.execution.twap;
 '"unknown -execution '",execution,"' - expected immediate or twap"
 ];

pipeline:`alpha`portfolio`risk`execution!(alphaFn;portfolioFn;riskFn;executionFn);

bt:.bt.run[bars;pipeline;cfg];
st:.bt.stats[bt;statsCfg];

-1 "";
-1 "=== Backtest: ",strategy,$[strategy~"candle";" (",string[pattern],")";""]," / ",portfolio," / ",risk," / ",execution," on ",(string symArg)," (",(string sDate)," - ",(string eDate),") ===";
-1 "bars: ",string count bars;
-1 "costBp: ",(string costBp),"  lag: ",(string lag)," bar(s)";
show st;
-1 "";
-1 "=== last 5 bars ===";
show -5#bt;

exit 0
