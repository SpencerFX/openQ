//====================================================================
// Directory: modules/backtest/service.q
//
// About:
// Long-running counterpart to run.q's one-shot CLI report: loads the
// same EFX archive backtest.q needs exactly once, opens a port, and
// exposes .bt.svc.run so a remote caller (the dashboard gateway's
// /api/backtest routes) can run any pipeline combination against
// already-mapped data instead of reloading the whole archive from disk
// per request. Not a `-procType` role and not part of cfg_proc/'s
// JSON-driven bootstrap - like run.q and modules/utils/generator/
// generator.q, this is a plain script outside core/init.q's/
// core/config.q's machinery entirely (no tp/rdb/idb/cep pipeline makes
// sense for a single static, read-only archive - see run.q's own header
// for the same reasoning). STRICTLY READ-ONLY, same guarantee as
// run.q's: nothing here ever calls a save/checkpoint/EOD function
// against -efxroot.
//
// .bt.svc.run takes the exact same flat scalar arguments run.q's CLI
// flags do (see run.q's header for what each one means and its
// defaults) rather than a single nested dict, so a caller over IPC -
// the gateway - only ever has to marshal plain scalars (symbol/date/
// int/float), the same shape every other reader in this repo already
// sends (see openDash/gateway/src/candlePattern.js's signals() call for
// the pattern this follows). One unknown -strategy/-portfolio/-risk/
// -execution name throws the same descriptive error run.q's own dispatch
// does, caught by the caller same as any other bad-input error.
//
// Run from the repo root (like run.q, modules/utils/generator/
// generator.q and every other modules/*/simulator.q script):
//   q modules/backtest/service.q [-port 5097] [-efxroot C:/data/db1/efx]
// Stop with Ctrl-C, or scripts/startStop/shutdownBacktest.sh if started
// via startupBacktest.sh.
//====================================================================
system "l core/utils/log.q";
system "l core/utils/start.q";
system "l core/utils/core.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

port:    "J"$opt[args;`port;"5097"];
efxroot: opt[args;`efxroot;"C:/data/db1/efx"];

system "p ",string port;

// backtest.q (repo-root-relative, like run.q's own load of it) MUST load
// before the archive below - \l on a database directory changes the
// session's current directory to it, so any later repo-root-relative
// system"l" would resolve against C:/data/db1/efx instead of the repo
// root and fail to find the file. run.q's own load order is the same,
// for the same reason.
system "l modules/backtest/backtest.q";
system "l schemas/schema_efx.q";
.util.log.ex[`INFO;`.bt.svc.init]"Loading EFX archive (read-only): ",efxroot;
system "l ",efxroot;

.oq.info.backtestSvc.loaded:0b;

//@func   | .bt.svc.run
//@param  | symArg | -11 | the symbol to backtest, e.g. `aud_cad - NOT
//                named `sym`: a select/exec/where clause binds every
//                column name of the table it runs against into scope,
//                so a param actually named `sym` would be silently
//                shadowed by fx_m1_massive's own `sym` column inside the
//                where clause below - turning `sym=sym` into "true for
//                every row" (every symbol in the archive, not just the
//                one asked for) instead of an error, exactly the trap
//                .oq.cep.registerSource's own header warns about and
//                run.q itself already sidesteps with this same rename
//@param  | sDate | -14 | backtest window start (inclusive)
//@param  | eDate | -14 | backtest window end (inclusive)
//@param  | strategy | -11 | `sma`meanrev`momentum`candle
//@param  | strategyParams | 99 | dict of that strategy's own params only -
//                sma: `fastN`slowN (int); meanrev: `lookback(int)`zEntry
//                (float); momentum: `lookback (int); candle: `pattern
//                (symbol, a name from .candle.patternNames)
//@param  | pipelineNames | 99 | `portfolio`risk`execution!(3 symbols) -
//                portfolio: `direction`confweighted; risk: `none`maxpos
//                `maxdd; execution: `immediate`twap
//@param  | cfg | 99 | flat dict, every stage's own params - costBp, lag,
//                barsPerYear (annualization for .bt.stats' sharpe) always
//                read; maxAbsPos/ddLimit/phaseIn read only by the risk/
//                execution stage that needs them, ignored otherwise -
//                see .bt.run/.bt.stats' own headers
//@return | 99 | `stats`curve!(.bt.stats' dict; .bt.run's bar-by-bar output)
//@desc
//Same dispatch table run.q's own -strategy/-portfolio/-risk/-execution
//flags use (see that file), wrapped as one callable instead of a CLI
//parse - a bad name throws the identical descriptive 'unknown ...' error.
//Grouped into 7 params (not run.q's ~18 flat ones) because a q lambda
//caps out at 8 formal parameters.
//@desc
.bt.svc.run:{[symArg;sDate;eDate;strategy;strategyParams;pipelineNames;cfg]
  bars:0!select from fx_m1_massive where date within (sDate;eDate), sym=symArg;
  if[0=count bars;'"no data for ",(string symArg)," from ",(string sDate)," to ",string eDate];

  alphaFn:$[strategy=`sma;{[b;p] .bt.alphas.smaCrossover[b;p`fastN;p`slowN]}[;strategyParams];
    strategy=`meanrev;{[b;p] .bt.alphas.meanReversion[b;p`lookback;p`zEntry]}[;strategyParams];
    strategy=`momentum;{[b;p] .bt.alphas.momentum[b;p`lookback]}[;strategyParams];
    strategy=`candle;{[b;p] .bt.alphas.candlePattern[b;p`pattern]}[;strategyParams];
    '"unknown strategy '",(string strategy),"' - expected sma, meanrev, momentum, or candle"];

  portfolio:pipelineNames`portfolio; risk:pipelineNames`risk; execution:pipelineNames`execution;

  portfolioFn:$[portfolio=`direction;`.bt.portfolio.direction;
    portfolio=`confweighted;`.bt.portfolio.confidenceWeighted;
    '"unknown portfolio '",(string portfolio),"' - expected direction or confweighted"];

  riskFn:$[risk=`none;`.bt.risk.none;
    risk=`maxpos;`.bt.risk.maxPosition;
    risk=`maxdd;`.bt.risk.maxDrawdown;
    '"unknown risk '",(string risk),"' - expected none, maxpos, or maxdd"];

  executionFn:$[execution=`immediate;`.bt.execution.immediate;
    execution=`twap;`.bt.execution.twap;
    '"unknown execution '",(string execution),"' - expected immediate or twap"];

  pipeline:`alpha`portfolio`risk`execution!(alphaFn;portfolioFn;riskFn;executionFn);
  bt:.bt.run[bars;pipeline;cfg];
  st:.bt.stats[bt;cfg];
  `stats`curve!(st;bt)
 };

//@func   | .bt.svc.meta
//@return | 99 | symbols/date range available in the loaded archive, plus
//               every strategy/portfolio/risk/execution name and the
//               param names it reads - lets a caller build pickers
//               without hardcoding this dispatch table a second time
//@desc
//Precomputed once at startup (.bt.svc.priv.meta below), not per call -
//grouping min/max date by sym across fx_m1_massive's full 2009-2025
//history (1768 symbols) takes ~45s, comfortably past every timeout
//between here and the dashboard. -efxroot is loaded once and never
//written to for the life of this process, so nothing here can go stale.
//@desc
.bt.svc.meta:{[] .bt.svc.priv.meta};

.oq.info.backtestSvc.loaded:1b;
.util.log.ex[`INFO;`.bt.svc.init]"Computing symbol/date-range metadata (one-time, ~45s over the full archive)...";
.bt.svc.priv.meta:`syms`strategies`portfolios`risks`executions!(
  0!select sDate:min date,eDate:max date by sym from fx_m1_massive;
  `sma`meanrev`momentum`candle!(`fastN`slowN;`lookback`zEntry;enlist`lookback;enlist`pattern);
  `direction`confweighted!(();());
  `none`maxpos`maxdd!(();enlist`maxAbsPos;enlist`ddLimit);
  `immediate`twap!(();enlist`phaseIn));
.util.log.ex[`INFO;`.bt.svc.init]"Backtest service started on port ",string port;
