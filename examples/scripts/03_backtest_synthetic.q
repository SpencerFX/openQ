//====================================================================
// 03_backtest_synthetic.q
//
// modules/backtest/backtest.q's four-stage pipeline (alpha -> portfolio
// construction -> risk management -> execution - see the README's
// "Backtesting" section) against a small hand-built OHLC bar series,
// so anyone can try it without the real EFX historical archive
// modules/backtest/run.q normally uses. Runs the same strategy twice -
// once with every stage left at its pipeline default, once with every
// stage overridden - to show the composition actually changes
// behavior, not just that both run without error.
//
// No prerequisites. Run from the repo root:
//   q examples/scripts/03_backtest_synthetic.q
//====================================================================

system "l modules/backtest/backtest.q";

//---------------------------------------------------------------
// A synthetic 30-bar series: an uptrend, then a downtrend, then a
// slow crawl back up - enough shape for a moving-average crossover
// alpha to actually generate more than one signal flip.
//---------------------------------------------------------------
n:30;
close:100+sums (10#0.5f),(10#-0.3f),(10#0.4f);
bars:([]
  timestamp:.z.p+`timespan$1e9*til n;
  sym:n#`SYNTH;
  open:close; high:close+0.1; low:close-0.1; close:close);

cfg:`costBp`lag`maxAbsPos`ddLimit`phaseIn!(1f;1;0.5f;0.05f;3);

//---------------------------------------------------------------
// Run 1: only `alpha` supplied - portfolio/risk/execution all fall
// back to .bt.pipelineDefaults (full +-1 sizing, no risk overlay,
// immediate one-bar-lag execution). This is the simplest possible
// way to run a strategy through the engine.
//---------------------------------------------------------------
defaultPipeline:enlist[`alpha]!enlist {[b] .bt.alphas.smaCrossover[b;3;7]};
btDefault:.bt.run[bars;defaultPipeline;cfg];
stDefault:.bt.stats[btDefault;enlist[`barsPerYear]!enlist 252f];

-1 "=== default pipeline (alpha only: smaCrossover) ===";
show stDefault;

//---------------------------------------------------------------
// Run 2: every stage overridden - same alpha, but sized by confidence
// (via the momentum alpha instead, which is the one that actually
// emits confidence), clipped by a max-position risk overlay, and
// phased in over several bars instead of jumping straight to target.
// No changes to .bt.run itself - just a different pipeline dict.
//---------------------------------------------------------------
customPipeline:`alpha`portfolio`risk`execution!(
  {[b] .bt.alphas.momentum[b;5]};
  `.bt.portfolio.confidenceWeighted;
  `.bt.risk.maxPosition;
  `.bt.execution.twap);
btCustom:.bt.run[bars;customPipeline;cfg];
stCustom:.bt.stats[btCustom;enlist[`barsPerYear]!enlist 252f];

-1 "";
-1 "=== custom pipeline (momentum / confidenceWeighted / maxPosition / twap) ===";
show stCustom;

-1 "";
-1 "=== last 10 bars of the custom run, every stage's column visible ===";
show -10#select timestamp,close,direction,confidence,rawPos,riskedPos,pos,netRet,equity from btCustom;

exit 0
