//====================================================================
// openQ Backtesting engine
//
// Pure batch functions over an already-fetched OHLC bar table - no IPC,
// no live state, the same shape every other domain analytics library in
// this repo (modules/analytics/*/*.q) uses.
// Needs only timestamp,sym,open,high,low,close columns, so it works
// against any bar table shaped that way - modules/backtest/run.q, the
// only thing that knows where real bar data actually lives, feeds it
// schema_efx.q's fx_m1_massive (see the README's "Backtesting" section).
//
// Modeled on QuantConnect's LEAN Algorithm Framework (see ./Lean,
// Algorithm/{Alphas,Portfolio,Risk,Execution}/I*Model.cs): a strategy is
// decomposed into four independently-swappable stages - alpha (signal),
// portfolio construction (sizing), risk management (an overlay), and
// execution (how a target position is actually realized) - each with a
// shipped default, so a user can override just one stage without
// touching the rest. LEAN's stages are event-driven callbacks
// (Update(algorithm,data), fired per tick, against Insight objects with
// a decay Period) over live/paper/backtest data; this engine is
// vectorized/batch instead (one call over a whole historical bars table
// at once, no per-tick event loop) - so a stage here is a plain
// column-in/column-out q function, not an object with an Update method,
// and an "insight" is just a dict of parallel columns, not an object
// with its own lifetime. LEAN's fifth stage, universe/security
// selection, has no analogue here - this engine backtests one symbol at
// a time.
//
// Every stage is causal by construction as long as it's built from q's
// own rolling-window functions (mavg/mdev/etc, which only ever look
// backward) - .bt.run's own execution-stage lag on top of that is what
// keeps the *engine* honest even if a stage is trivial (a constant
// signal, say), by making sure nothing trades on the same bar's close
// it was computed from.
//====================================================================
// modules/backtest/run.q loads this file repo-root-relative
// (`system "l modules/backtest/backtest.q"`, run from the repo root, not
// core-relative like every other module's cep.q) - so candle.q's own
// load path here (its own folder under modules/analytics/, no longer a
// sibling file) has to match that same repo-root-relative convention.
system "l modules/analytics/candle/candle.q";

.oq.info.backtest.loaded:0b;

//--------------------------------------------------------------------
// Pipeline composition
//--------------------------------------------------------------------

//@func  | .bt.normInsight
//@param  | insight | float or dict
//@desc
// an alpha's raw output, normalized into the full insight dict every
// .bt.portfolio.* function expects. Alphas that only care about
// direction (.bt.alphas.smaCrossover/.bt.alphas.meanReversion below)
// can return a bare direction column instead of a dict - that column
// gets wrapped as `direction`confidence!(col;1f's) here, with
// confidence defaulted to 1f throughout. An alpha that already returns
// a `direction`confidence dict (.bt.alphas.momentum) passes through
// unchanged aside from the same confidence default if it left the key
// out. This is what lets a minimal alpha work with the pipeline with no
// changes.
//@desc
.bt.normInsight:{[insight]
  d:$[99h=type insight;insight;(enlist `direction)!enlist insight];
  d,(enlist `confidence)!enlist $[`confidence in key d;d`confidence;count[d`direction]#1f]
 };

// default portfolio/risk/execution stages used whenever .bt.run's own
// `pipeline` argument doesn't override them - see .bt.run
.bt.pipelineDefaults:`portfolio`risk`execution!(`.bt.portfolio.direction;`.bt.risk.none;`.bt.execution.immediate);

//@func  | .bt.run
//@param  | bars | table
//@param  | pipeline | dict
//@param  | cfg | dict
//@desc
//   bars: OHLC bar table (timestamp,sym,open,high,low,close,...), one
//         symbol, in time order
//   pipeline: `alpha` (required, {[bars]->insight}) plus optional
//         `portfolio`/`risk`/`execution` overrides - see
//         .bt.pipelineDefaults for what's used when one is omitted
//   cfg: every stage's own params in one flat dict - costBp, lag, plus
//         whatever the chosen portfolio/risk/execution functions read
//         (maxAbsPos, ddLimit, phaseIn, ...); a stage simply ignores
//         keys it doesn't read
// Runs alpha -> portfolio construction -> risk management -> execution,
// each stage's output feeding the next, mirroring LEAN's Algorithm
// Framework pipeline (see the file header). ret is bar t's simple
// return off close; netRet is pos*ret minus a turnover-proportional
// cost (turnover:abs deltas pos, cfg`costBp); equity is the cumulative
// product of 1+netRet, starting at 1 (compounding, not additive).
// Returns bars, augmented with direction,confidence,rawPos,riskedPos,
// pos,ret,netRet,equity - every stage's contribution, not just the
// final position.
//@desc
.bt.run:{[bars;pipeline;cfg]
  p:.bt.pipelineDefaults,pipeline;
  insight:.bt.normInsight p[`alpha] bars;
  rawPos:p[`portfolio][bars;insight;cfg];
  riskedPos:p[`risk][bars;rawPos;cfg];
  pos:p[`execution][bars;riskedPos;cfg];
  ret:0f,1_(bars[`close]%prev bars`close)-1;
  turnover:abs deltas pos;
  cost:turnover*(cfg`costBp)%1e4;
  netRet:(pos*ret)-cost;
  equity:{x*1+y}\[1f;netRet];
  bars,'([]
    direction:insight`direction; confidence:insight`confidence;
    rawPos; riskedPos; pos; ret; netRet; equity)
 };

//@func  | .bt.stats
//@param  | bt | table
//@param  | cfg | dict
//@desc
//   bt: .bt.run's output
//   cfg: reads `barsPerYear` (annualization factor for sharpe - e.g.
//        252*24*60 for 1-minute FX bars trading ~24h/weekday - sizes
//        this very differently than daily equity bars, so it's a
//        parameter, not a constant)
// Returns a dict: totalReturn,sharpe,maxDrawdown,hitRate (fraction of
// active-position bars that were profitable),numTrades,avgTurnover.
//@desc
.bt.stats:{[bt;cfg]
  netRet:bt`netRet;
  equity:bt`equity;
  pos:bt`pos;
  turnover:abs deltas pos;
  active:pos<>0;
  sharpe:$[0f=dev netRet;0f;(avg netRet)%dev[netRet]*sqrt cfg`barsPerYear];
  dd:equity%(maxs equity);
  `totalReturn`sharpe`maxDrawdown`hitRate`numTrades`avgTurnover!(
    (last equity)-1;
    sharpe;
    (min dd)-1;
    $[0=sum active;0n;(sum active and netRet>0)%sum active];
    sum turnover>0;
    avg turnover)
 };

//--------------------------------------------------------------------
// Alpha models - {[bars] -> direction column, or `direction`confidence
// dict} - signal only, no sizing opinion (LEAN's IAlphaModel)
//--------------------------------------------------------------------

//@func  | .bt.alphas.smaCrossover
//@param  | bars | table
//@param  | fastN | int
//@param  | slowN | int
//@desc
//   bars: OHLC bar table
//   fastN: fast moving-average window, in bars
//   slowN: slow moving-average window, in bars
// Classic trend-following: long when the short-term average is above
// the long-term one, short otherwise. mavg's own first slowN-1 values
// are computed from a short (not-yet-full) window rather than null, so
// there's no separate warm-up case to handle here. Returns direction:
// 1 where fast mavg > slow mavg, else -1.
//@desc
.bt.alphas.smaCrossover:{[bars;fastN;slowN]
  fast:fastN mavg bars`close;
  slow:slowN mavg bars`close;
  ?[fast>slow;1f;-1f]
 };

//@func  | .bt.alphas.meanReversion
//@param  | bars | table
//@param  | lookback | int
//@param  | zEntry | float
//@desc
//   bars: OHLC bar table
//   lookback: rolling window, in bars, for the mean/std
//   zEntry: |z-score| threshold to take a position
// Classic mean-reversion: fades extremes of a rolling z-score of close.
// Bars before the window is even partially meaningful (dev of a 1-2
// point sample is 0 or tiny) naturally score z near 0, landing inside
// the band - flat, not a spurious signal. Returns direction: -1 (fade
// high), 1 (fade low), 0 (inside band).
//@desc
.bt.alphas.meanReversion:{[bars;lookback;zEntry]
  m:lookback mavg bars`close;
  s:lookback mdev bars`close;
  z:(bars[`close]-m)%1f^s;  / x^y fills y's NULLS with x - 1f^s, not s^1f
  ?[z>zEntry;-1f;?[z<neg zEntry;1f;0f]]
 };

//@func  | .bt.alphas.momentum
//@param  | bars | table
//@param  | lookback | int
//@desc
//   bars: OHLC bar table
//   lookback: rolling window, in bars, for the rate of change
// The one example alpha that emits confidence, not just direction -
// pairs with .bt.portfolio.confidenceWeighted below. Rate of change
// over the first lookback-1 bars is computed against a short
// (not-yet-full) window rather than null, the same warm-up convention
// mavg uses. Returns a `direction`confidence dict: direction is the
// sign of the lookback-bar rate of change; confidence is that rate's
// magnitude, capped at 1.
//@desc
.bt.alphas.momentum:{[bars;lookback]
  close:bars`close;
  n:lookback-1;  / bars before the window is full compare against bar 0
  refClose:(n#first close),(neg n)_close;
  roc:(close-refClose)%refClose;
  `direction`confidence!((signum roc);1f&abs roc)
 };

//@func  | .bt.alphas.candlePattern
//@param  | bars | table
//@param  | pat | symbol
//@desc
//   bars: OHLC bar table (timestamp,sym,open,high,low,close,...)
//   pat: a name from .candle.patternNames (e.g. `hammer`, `engulfing`,
//        `morningStar`) - see modules/analytics/candle/candle.q
// Wraps candle.q's pattern library as an alpha: runs the
// named pattern over bars and normalizes its result into a signed
// direction column regardless of which of the library's two native
// return shapes it uses - a boolean "present" vector for a pattern with
// no inherent direction of its own (.candle.meta`direction is `bullish/
// `bearish/`neutral - hammer, marubozu, doji, ...) or an already-signed
// -100/0/+100 vector for a pattern whose shape implies one (`direction
// is `both - engulfing, harami, morningStar, ...), looked up from
// .candle.meta rather than assumed from the pattern name. A `neutral`
// pattern (pure indecision, e.g. doji) has no direction to give an
// alpha and always returns 0 - it's in the library for completeness/
// scanning, not because it makes a sensible standalone alpha.
// Like .bt.alphas.smaCrossover/meanReversion, returns a bare direction
// column (no confidence opinion - .bt.normInsight defaults it to 1f).
// A fired pattern signals for exactly the one bar it's detected on, not
// held afterward - there's no Insight-style decay Period in this
// vectorized/batch engine (see this file's header) - so a candle-based
// strategy pairs naturally with .bt.execution.twap to phase a position
// in/out around the signal instead of snapping to it for a single bar.
//@desc
.bt.alphas.candlePattern:{[bars;pat]
  t:.candle.prepare `sym`timestamp`open`high`low`close#bars;
  raw:.candle.functions[pat] t;
  dirCat:first exec direction from .candle.meta where pattern=pat;
  $[dirCat=`both; raw%100f;
    dirCat=`bullish; 1f*0<>raw;
    dirCat=`bearish; -1f*0<>raw;
    0f*raw]
 };

//--------------------------------------------------------------------
// Portfolio construction models - {[bars;insight;cfg] -> target
// position} - turns an insight into a sized position (LEAN's
// IPortfolioConstructionModel)
//--------------------------------------------------------------------

//@func  | .bt.portfolio.direction
//@param  | bars | table
//@param  | insight | dict
//@param  | cfg | dict
//@desc
// Default portfolio construction model: direction as-is, full +-1
// sizing - ignores confidence entirely.
//@desc
.bt.portfolio.direction:{[bars;insight;cfg] insight`direction};

//@func  | .bt.portfolio.confidenceWeighted
//@param  | bars | table
//@param  | insight | dict
//@param  | cfg | dict
//@desc
// Scales size by conviction: direction*confidence. Alphas that don't
// emit a real confidence get 1f from .bt.normInsight, so this degrades
// to .bt.portfolio.direction for them.
//@desc
.bt.portfolio.confidenceWeighted:{[bars;insight;cfg] insight[`direction]*insight`confidence};

//--------------------------------------------------------------------
// Risk management models - {[bars;pos;cfg] -> risk-adjusted position} -
// an overlay applied after sizing, before execution, independent of how
// the position was built (LEAN's IRiskManagementModel)
//--------------------------------------------------------------------

//@func  | .bt.risk.none
//@param  | bars | table
//@param  | pos | float
//@param  | cfg | dict
//@desc
// Default risk model: pass-through, no overlay.
//@desc
.bt.risk.none:{[bars;pos;cfg] pos};

//@func  | .bt.risk.maxPosition
//@param  | bars | table
//@param  | pos | float
//@param  | cfg | dict
//@desc
//   cfg: reads `maxAbsPos`
// Simple vectorized clip to +-maxAbsPos.
//@desc
.bt.risk.maxPosition:{[bars;pos;cfg] (neg cfg`maxAbsPos)|(cfg`maxAbsPos)&pos};

//@func  | .bt.risk.maxDrawdown
//@param  | bars | table
//@param  | pos | float
//@param  | cfg | dict
//@desc
//   cfg: reads `ddLimit` (positive fraction, e.g. 0.05)
// Tracks pos's own (pre-cost) hypothetical equity curve and forces flat
// once its trailing drawdown from the running peak breaches ddLimit,
// resuming once that equity makes a new high again - mirrors
// MaximumDrawdownPercentPerSecurity's "de-risk on breach, no discretion
// to re-enter early" rule, as a single vectorized scan rather than a
// live per-tick check. Uses close-to-close returns, matching .bt.run's
// own ret calc, so the breach condition lines up with what .bt.run will
// actually realize. Returns pos, forced flat while in breach.
//@desc
.bt.risk.maxDrawdown:{[bars;pos;cfg]
  ret:0f,1_(bars[`close]%prev bars`close)-1;
  / nested lambdas in q see globals and their own params only - NOT the
  / enclosing function's locals - so ddLimit must be curried in
  / explicitly rather than left as a free variable inside step.
  step:{[ddLimit;state;x]
    pos:x 0; ret:x 1;
    peak:state 0; breached:state 1;
    equity:state[2]*1+$[breached;0f;pos]*ret;
    peak:peak|equity;
    dd:(equity%peak)-1;
    breached:breached or dd<neg ddLimit;
    breached:breached and equity<peak;  / resume once equity makes a new high
    (peak;breached;equity)
   }[cfg`ddLimit];
  states:step\[(1f;0b;1f);flip (pos;ret)];
  breachedFlags:states[;1];
  ?[breachedFlags;0f;pos]
 };

//--------------------------------------------------------------------
// Execution models - {[bars;targetPos;cfg] -> actual position} - how a
// target position is actually realized bar by bar (LEAN's
// IExecutionModel)
//--------------------------------------------------------------------

//@func  | .bt.execution.immediate
//@param  | bars | table
//@param  | targetPos | float
//@param  | cfg | dict
//@desc
//   cfg: reads `lag` (bars of execution delay)
// Default execution model: delays the target by cfg`lag bars (0-filled
// at the start, since there's no earlier target yet), then holds it
// fully - the position held INTO bar t was decided using information
// available through bar t-lag, not bar t itself.
//@desc
.bt.execution.immediate:{[bars;targetPos;cfg]
  lag:cfg`lag;
  (lag#0f),(neg lag)_targetPos
 };

//@func  | .bt.execution.twap
//@param  | bars | table
//@param  | targetPos | float
//@param  | cfg | dict
//@desc
//   cfg: reads `lag` and `phaseIn` (bars to phase the position change
//        in over)
// Lags first (same no-lookahead rule as .bt.execution.immediate), then
// phases toward the target via a phaseIn-bar moving average of the
// lagged target - a moving average of a step function is a linear ramp
// toward the new level over the window, a clean vectorized stand-in for
// working a larger order over several bars instead of jumping to it
// immediately (the same idea VolumeWeightedAveragePriceExecutionModel
// embodies). Smooths turnover, not just delays it.
//@desc
.bt.execution.twap:{[bars;targetPos;cfg]
  lag:cfg`lag;
  lagged:(lag#0f),(neg lag)_targetPos;
  (cfg`phaseIn) mavg lagged
 };

.oq.info.backtest.loaded:1b;
