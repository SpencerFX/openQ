//====================================================================
// openQ brokerTech - predictive analytics (predictive.q)
//
// Everything in brokerTech.q describes what already happened over the
// window (this account's measured toxicity, this book's realised
// revenue). Everything here tries to say something about what happens
// NEXT - and because this is historical archive data, not a live feed,
// each prediction is graded with an honest backtest over that same
// archive rather than just asserted:
//
//   .brk.pred.blowupRisk           trains a toxScore -> decile ->
//                                   empirical forward-drawdown-breach
//                                   rate calibration curve on the FIRST
//                                   half of the window (by calendar
//                                   time), then scores every signal's
//                                   SECOND half against that curve - a
//                                   real train/test split, not a
//                                   knob-tuned heuristic.
//   .brk.pred.equityTrend          per-signal OLS trend of the equity
//                                   curve, projected forward over
//                                   .brk.pred.cfg`forecastHorizonDays.
//   .brk.pred.toxTrend              per-signal OLS trend of toxScore
//                                   across N independent calendar sub-
//                                   windows - an early-warning flag for
//                                   an account trending toward HIGH
//                                   before .brk.tox.bucket would
//                                   actually call it that.
//   .brk.pred.revenueForecast /
//   .brk.pred.brokerRevenueForecast daily book/broker revenue trend + an
//                                   EMA level forecast, graded with a
//                                   walk-forward one-step backtest
//                                   (MAE/MAPE on genuinely out-of-sample
//                                   points) so the forecast's own
//                                   accuracy ships alongside it, not
//                                   just its output.
//   .brk.pred.summary               one row per signal - current
//                                   toxicity + its trend + its equity
//                                   trend + its predicted blowup
//                                   probability, worst-first.
//
// Same stance as brokerTech.q itself: deterministic, closed-form
// formulas (OLS, EMA - both textbook, no fitted/opaque model) with the
// knobs in .brk.pred.cfg. The "prediction" is the backtest, not a black
// box - every forecasting function returns its own accuracy alongside
// its output.
//
// Depends on brokerTech.q already being loaded (.brk.executed,
// .brk.clamp, .brk.pctile, .brk.cfg, .brk.perf.*, .brk.tox.*,
// .brk.broker.*).
//
// An honest finding from building this against the real archive, not a
// caveat added out of caution: toxScore's correlation with an actual
// forward blowup swings sign depending on the window (-0.15 over a
// 180-day split, +0.01 over the full 11-year archive; martingaleScore
// alone did a bit better, +0.19, over the long split). Two structural
// reasons, not a bug - checked by hand both ways:
//   - most providers in this MetaTrader Signals archive are only
//     briefly active, so a long calendar split (needed for enough
//     blowups to happen at all - they're rare) leaves very few
//     providers with equity samples spanning BOTH halves to calibrate
//     from (34, over the full archive); a short split has plenty of
//     providers (166, over 180 days) but too little calendar time for
//     more than a handful of blowups to occur (11).
//   - tooGoodScore, one of toxScore's five components, explicitly
//     REWARDS a low historical drawdown - so part of what makes
//     toxScore high is exactly the opposite of what a blowup predictor
//     should reward, muting the composite's usable signal.
// `curve`'s nSignals/nBlewUp columns are reported for exactly this
// reason - read the decile split as "how much data actually backs this
// number" before trusting predictedBlowupProbPct, and prefer a longer
// -lookbackDays window in run.q if this matters for a real decision.
//====================================================================
.brk.pred.info.loaded:0b;

// trainFrac/blowupDDPct are fractions (not %), matching .brk.cfg's own
// convention (e.g. alertMaxDDPct). equityFlatBandPct/backtestDays/
// forecastHorizonDays are plain counts/percentages.
.brk.pred.cfg:`trainFrac`blowupDDPct`toxWindowBuckets`nDeciles`forecastHorizonDays`emaAlpha`backtestDays`equityFlatBandPct!(0.5;0.40;4;5;30;0.25;30;2f);

//--------------------------------------------------------------------
// generic helpers
//--------------------------------------------------------------------

//@func  | .brk.pred.priv.olsFit
//@param | x | float list
//@param | y | float list
//@desc
// Closed-form OLS: slope, intercept, r2 (1 - SSres/SStot). n<2 or a
// constant x (nothing to regress against) -> null slope/r2.
//@desc
.brk.pred.priv.olsFit:{[x;y]
  n:count x;
  if[n<2; :`slope`intercept`r2!(0n;0n;0n)];
  mx:avg x; my:avg y;
  sxx:sum (x-mx)*(x-mx);
  if[sxx=0; :`slope`intercept`r2!(0n;my;0n)];
  slope:(sum (x-mx)*(y-my))%sxx;
  intercept:my-slope*mx;
  pred:intercept+slope*x;
  sstot:sum (y-my)*(y-my);
  r2:$[sstot=0; 1f; 1f-(sum (y-pred)*(y-pred))%sstot];
  `slope`intercept`r2!(slope;intercept;r2)};

.brk.pred.priv.olsSlope:{[x;y] .brk.pred.priv.olsFit[x;y]`slope};
.brk.pred.priv.olsR2:{[x;y] .brk.pred.priv.olsFit[x;y]`r2};

//@func  | .brk.pred.priv.dateBucket
//@param | d    | date list
//@param | dMin | date
//@param | dMax | date
//@param | n    | long | number of equal calendar-width buckets
//@desc
// 0-based bucket index for each date in [dMin;dMax], n equal-width
// buckets by calendar-day span. dMax itself always lands in bucket n-1.
//@desc
.brk.pred.priv.dateBucket:{[d;dMin;dMax;n]
  span:1|`long$dMax-dMin;
  b:`long$n*(`long$d-dMin)%span+1;
  0|(n-1)&b};

//@func  | .brk.pred.priv.backtestEma
//@param | y     | float list | a daily series in date order
//@param | alpha | float      | EMA smoothing factor
//@param | h     | long       | trailing window (days) to grade
//@desc
// Walk-forward one-step-ahead backtest: for each of the trailing h
// points (never the first point - it has no history to forecast from),
// forecast it from the EMA of everything strictly BEFORE it, then
// compare to what actually happened. Returns the count graded, MAE, and
// MAPE (days with a zero actual excluded from MAPE only). This grades
// the forecast; .brk.pred.revenueForecast/.brk.pred.brokerRevenueForecast
// use the EMA of the FULL series for the actual forward projection.
//@desc
.brk.pred.priv.backtestEma:{[y;alpha;h]
  n:count y;
  if[n<2; :`nBacktestPts`mae`mapePct!(0;0n;0n)];
  from0:1|n-h;
  idxs:from0+til n-from0;
  fc:{[y;alpha;i] last alpha ema i sublist y}[y;alpha] each idxs;
  act:y idxs;
  err:act-fc;
  nz:act<>0;
  `nBacktestPts`mae`mapePct!(
    count idxs;
    avg abs err;
    $[any nz; 100*avg abs (err where nz)%act where nz; 0n])};

//--------------------------------------------------------------------
// equity-curve trend & projection (.brk.pred.equityTrend)
//--------------------------------------------------------------------

//@func  | .brk.pred.equityTrend
//@param | equity | table | `equity` rows (needs a `date column - see run.q)
//@desc
// Per signal: end-of-day equity series -> OLS trend (slopePerDay, r2),
// then that trend projected forward .brk.pred.cfg`forecastHorizonDays
// days off the last observed equity (projectedEquity, projectedRetPct).
// direction is UP/DOWN/FLAT with a +-equityFlatBandPct dead-zone around
// projectedRetPct so a near-zero trend doesn't flip-flop on noise.
//@desc
.brk.pred.equityTrend:{[equity]
  e:select signalId, date, equity from equity where not null equity;
  if[not count e; :([] signalId:`long$(); nDays:`long$(); firstEq:`float$();
    lastEq:`float$(); slopePerDay:`float$(); r2:`float$();
    projectedEquity:`float$(); projectedRetPct:`float$(); direction:`symbol$())];
  eod:0!`signalId`date xasc select lastEq:last equity by signalId, date from e;
  h:`long$.brk.pred.cfg`forecastHorizonDays;
  r:0!select nDays:count i, firstEq:first lastEq, lastEq:last lastEq,
      slopePerDay:.brk.pred.priv.olsSlope[`float$date-first date;lastEq],
      r2:.brk.pred.priv.olsR2[`float$date-first date;lastEq]
    by signalId from `signalId`date xasc eod;
  r:update projectedEquity:lastEq+slopePerDay*h from r;
  r:update projectedRetPct:?[lastEq=0; 0n; 100*(projectedEquity-lastEq)%abs lastEq] from r;
  band:.brk.pred.cfg`equityFlatBandPct;
  update direction:?[projectedRetPct>band; `UP; ?[projectedRetPct<neg band; `DOWN; `FLAT]] from r};

//--------------------------------------------------------------------
// toxicity trajectory - early warning (.brk.pred.toxTrend)
//--------------------------------------------------------------------

//@func  | .brk.pred.toxTrend
//@param | trades | table
//@param | equity | table
//@desc
// Splits the window into .brk.pred.cfg`toxWindowBuckets equal calendar
// sub-windows and runs .brk.tox.score INDEPENDENTLY inside each one (not
// cumulative), then fits an OLS trend of toxScore vs bucket index per
// signal (toxTrendSlope, r2). emergingToxic flags a signal that is
// CURRENTLY below toxHigh but whose trend, extrapolated one more
// bucket, would cross it - a warning before .brk.tox.bucket itself
// would call the account HIGH.
//@desc
.brk.pred.toxTrend:{[trades;equity]
  nb:`long$.brk.pred.cfg`toxWindowBuckets;
  dMin:min (min exec date from trades; min exec date from equity);
  dMax:max (max exec date from trades; max exec date from equity);
  t:update bucket:.brk.pred.priv.dateBucket[date;dMin;dMax;nb] from trades;
  e:update bucket:.brk.pred.priv.dateBucket[date;dMin;dMax;nb] from equity;
  byB:{[t;e;b]
      r:.brk.tox.score[select from t where bucket=b; select from e where bucket=b];
      $[count r; update bucket:b from r; r]
    }[t;e] each til nb;
  bx:raze byB;
  if[not count bx; :([] signalId:`long$(); nBuckets:`long$(); curToxScore:`float$();
    curBucket:`symbol$(); toxTrendSlope:`float$(); r2:`float$(); emergingToxic:`boolean$())];
  r:0!select nBuckets:count i,
      curToxScore:last toxScore,
      toxTrendSlope:.brk.pred.priv.olsSlope[`float$bucket;toxScore],
      r2:.brk.pred.priv.olsR2[`float$bucket;toxScore]
    by signalId from `signalId`bucket xasc bx;
  r:update curBucket:.brk.tox.bucket each curToxScore from r;
  r:update projNext:.brk.clamp[curToxScore+toxTrendSlope;0f;1f] from r;
  `toxTrendSlope xdesc update emergingToxic:(curToxScore<.brk.cfg`toxHigh) and projNext>=.brk.cfg`toxHigh from r};

//--------------------------------------------------------------------
// blowup-risk calibration & scoring (.brk.pred.blowupRisk)
//--------------------------------------------------------------------

//@func  | .brk.pred.blowupRisk
//@param | trades | table
//@param | equity | table
//@desc
// A genuinely backtested prediction, not a knob-tuned heuristic. Splits
// the window at .brk.pred.cfg`trainFrac (calendar time, not row count)
// into a TRAIN half and a TEST half:
//   1. TRAIN-half toxScore is computed for every signal.
//   2. The actual TEST-half outcome is observed: blewUp=1b if that
//      signal's TEST-half max drawdown breached
//      -.brk.pred.cfg`blowupDDPct (only counted for signals with enough
//      TEST-half equity samples - .brk.cfg`alertMinEquityPts - same
//      guard brokerTech.q's own alerting uses).
//   3. TRAIN-half toxScore is cut into .brk.pred.cfg`nDeciles quantiles
//      (.brk.pctile cut points); `curve` is the empirical forward
//      blowup rate observed in TEST for each decile - the calibration,
//      shown, not asserted.
//   4. Every signal is then scored on its own most-recent (TEST-half)
//      toxScore, mapped through those same cut points, and looked up in
//      `curve` -> predictedBlowupProbPct: "if the recent past repeats,
//      this is how often a signal this toxic, right now, blows up
//      next."
// Returns a dict `curve`scores!(curve;scores).
//@desc
.brk.pred.blowupRisk:{[trades;equity]
  dMin:min (min exec date from trades; min exec date from equity);
  dMax:max (max exec date from trades; max exec date from equity);
  splitD:dMin+`long$.brk.pred.cfg[`trainFrac]*`long$dMax-dMin;
  trT:select from trades where date<=splitD;
  trE:select from equity where date<=splitD;
  teT:select from trades where date>splitD;
  teE:select from equity where date>splitD;

  trainTox:select signalId, toxScore from .brk.tox.score[trT;trE];
  testDD:select signalId, maxDDPct, nPts from .brk.perf.drawdown teE;
  testTox:select signalId, toxScore from .brk.tox.score[teT;teE];

  ddLim:neg 100*.brk.pred.cfg`blowupDDPct;
  minPts:.brk.cfg`alertMinEquityPts;
  lab:update blewUp:maxDDPct<ddLim from select from testDD where nPts>=minPts;
  cal:(`signalId xkey trainTox) lj `signalId xkey select signalId,blewUp from lab;
  cal:select from 0!cal where not null blewUp;

  nd:`long$.brk.pred.cfg`nDeciles;
  emptyCurve:([] decile:`long$(); loTox:`float$(); hiTox:`float$(); nSignals:`long$();
    nBlewUp:`long$(); blowupRatePct:`float$());
  emptyScores:([] signalId:`long$(); toxScore:`float$(); decile:`long$(); predictedBlowupProbPct:`float$());
  if[not count cal; :(`curve`scores)!(emptyCurve;emptyScores)];

  cuts:asc distinct .brk.pctile[;cal`toxScore] each (til nd)%nd;
  decileOf:{[cuts;x] sum x>=cuts};

  cal:update decile:decileOf[cuts] each toxScore from cal;
  // 0! immediately: a "by" select is keyed, and `curve`col` on a keyed
  // table is a KEY lookup, not column access (the same gotcha noted
  // throughout brokerTech.q) - curve is returned to the caller, so this
  // isn't just an internal convenience, it's load-bearing for anyone
  // reading `curve`blowupRatePct` off the result.
  curve:`decile xasc 0!select nSignals:count i, loTox:min toxScore, hiTox:max toxScore,
      nBlewUp:sum blewUp, blowupRatePct:100*avg blewUp
    by decile from 0!cal;

  sc:$[count testTox; testTox; trainTox];   / no TEST-half trades at all -> fall back to TRAIN
  if[not count sc; :(`curve`scores)!(curve;emptyScores)];
  sc:update decile:decileOf[cuts] each toxScore from sc;
  sc:sc lj `decile xkey select decile, blowupRatePct from curve;
  sc:update predictedBlowupProbPct:0^blowupRatePct from sc;
  sc:`predictedBlowupProbPct xdesc select signalId, toxScore, decile, predictedBlowupProbPct from sc;
  (`curve`scores)!(curve;sc)};

//--------------------------------------------------------------------
// revenue trend, EMA forecast & backtest (.brk.pred.revenueForecast)
//--------------------------------------------------------------------

//@func  | .brk.pred.priv.dailyRevenue
//@param | trades | table
//@desc
// Internal: one row per date - book-level B-book PnL + commission +
// swap revenue for that day (same components as .brk.rev.summary,
// bucketed by date instead of summed over the whole window).
//@desc
.brk.pred.priv.dailyRevenue:{[trades]
  t:.brk.executed trades;
  r:select bBookPnl:neg sum profit, commissionRev:neg sum commission,
      swapRev:neg sum swap, nTrades:count i
    by date from t;
  `date xasc update totalRev:bBookPnl+commissionRev+swapRev from 0!r};

//@func  | .brk.pred.revenueForecast
//@param | trades | table
//@desc
// Book-level daily revenue: OLS trend (slopePerDay, r2), an EMA level
// forecast (emaLevel), that same EMA graded with a walk-forward
// backtest over the trailing .brk.pred.cfg`backtestDays
// (.brk.pred.priv.backtestEma - MAE/MAPE on genuinely out-of-sample
// one-step forecasts, not fitted-in-sample error), and
// projectedRevenueNextHorizon: the trend slope extended
// .brk.pred.cfg`forecastHorizonDays days forward from today's EMA level
// (sum of an arithmetic run emaLevel+slope*1 .. emaLevel+slope*h).
//
// backtestMapePct can look enormous (thousands of %) even when
// backtestMae is a modest dollar figure - book-level daily revenue
// legitimately crosses zero (a day with one big client win nets the
// book negative), and MAPE's denominator is that day's actual value, so
// a near-zero day inflates the % error on its own. Read backtestMae as
// the primary accuracy figure; backtestMapePct alongside it, not instead.
//@desc
.brk.pred.revenueForecast:{[trades]
  d:.brk.pred.priv.dailyRevenue trades;
  n:count d;
  if[n=0; :`nDays`totalRevSoFar`slopePerDay`r2`emaLevel`nBacktestPts`backtestMae`backtestMapePct`projectedRevenueNextHorizon!(0;0f;0n;0n;0n;0;0n;0n;0n)];
  x:`float$d[`date]-first d`date;
  y:d`totalRev;
  fit:.brk.pred.priv.olsFit[x;y];
  a:.brk.pred.cfg`emaAlpha;
  emaLevel:last a ema y;
  bt:.brk.pred.priv.backtestEma[y;a;`long$.brk.pred.cfg`backtestDays];
  h:`long$.brk.pred.cfg`forecastHorizonDays;
  proj:(h*emaLevel)+fit[`slope]*h*(h+1)%2;
  `nDays`totalRevSoFar`slopePerDay`r2`emaLevel`nBacktestPts`backtestMae`backtestMapePct`projectedRevenueNextHorizon!(
    n; sum y; fit`slope; fit`r2; emaLevel; bt`nBacktestPts; bt`mae; bt`mapePct; proj)};

//@func  | .brk.pred.priv.dailyRevenueByBroker
//@param | trades | table
//@param | sig    | table
//@desc
// Internal: like .brk.pred.priv.dailyRevenue but broken out per broker
// tag (parsed from sig.name via .brk.broker.tag) as well as date.
//@desc
.brk.pred.priv.dailyRevenueByBroker:{[trades;sig]
  t:.brk.broker.priv.join[.brk.executed trades; sig];
  r:select bBookPnl:neg sum profit, commissionRev:neg sum commission,
      swapRev:neg sum swap, nTrades:count i
    by brokerTag, date from t;
  `brokerTag`date xasc update totalRev:bBookPnl+commissionRev+swapRev from 0!r};

//@func  | .brk.pred.brokerRevenueForecast
//@param | trades | table
//@param | sig    | table
//@desc
// .brk.pred.revenueForecast rolled up per broker tag - same trend/EMA/
// backtest/projection, one row per brokerTag, sorted by projected
// revenue over the horizon.
//@desc
.brk.pred.brokerRevenueForecast:{[trades;sig]
  d:.brk.pred.priv.dailyRevenueByBroker[trades;sig];
  if[not count d; :([] brokerTag:`symbol$(); nDays:`long$(); totalRevSoFar:`float$();
    slopePerDay:`float$(); r2:`float$(); emaLevel:`float$(); nBacktestPts:`long$();
    backtestMae:`float$(); backtestMapePct:`float$(); projectedRevenueNextHorizon:`float$())];
  a:.brk.pred.cfg`emaAlpha;
  h:`long$.brk.pred.cfg`forecastHorizonDays;
  bt:`long$.brk.pred.cfg`backtestDays;
  r:0!select nDays:count i, totalRevSoFar:sum totalRev,
      fit:.brk.pred.priv.olsFit[`float$date-first date;totalRev],
      emaLevel:last a ema totalRev,
      bktst:.brk.pred.priv.backtestEma[totalRev;a;bt]
    by brokerTag from `brokerTag`date xasc d;
  r:update slopePerDay:{x`slope} each fit, r2:{x`r2} each fit,
      nBacktestPts:{x`nBacktestPts} each bktst, backtestMae:{x`mae} each bktst,
      backtestMapePct:{x`mapePct} each bktst from r;
  r:update projectedRevenueNextHorizon:(h*emaLevel)+slopePerDay*h*(h+1)%2 from r;
  `projectedRevenueNextHorizon xdesc select brokerTag, nDays, totalRevSoFar, slopePerDay, r2,
      emaLevel, nBacktestPts, backtestMae, backtestMapePct, projectedRevenueNextHorizon
    from r};

//--------------------------------------------------------------------
// consolidated per-signal scorecard (.brk.pred.summary)
//--------------------------------------------------------------------

//@func  | .brk.pred.summary
//@param | trades | table
//@param | equity | table
//@desc
// One row per signal, the "who to watch next" scorecard: current
// toxScore/bucket + its trend + emergingToxic (.brk.pred.toxTrend), the
// current equity trend/direction (.brk.pred.equityTrend), and this
// signal's predictedBlowupProbPct from .brk.pred.blowupRisk's `scores`.
// Sorted worst-first (highest predicted blowup probability).
//@desc
.brk.pred.summary:{[trades;equity]
  tt:.brk.pred.toxTrend[trades;equity];
  et:.brk.pred.equityTrend equity;
  br:.brk.pred.blowupRisk[trades;equity]`scores;
  ids:distinct raze (exec signalId from tt; exec signalId from et; exec signalId from br);
  r:([] signalId:ids);
  r:r lj `signalId xkey select signalId, curToxScore, curBucket, toxTrendSlope, emergingToxic from tt;
  r:r lj `signalId xkey select signalId, lastEq, slopePerDay, projectedRetPct, direction from et;
  r:r lj `signalId xkey select signalId, predictedBlowupProbPct from br;
  r:update predictedBlowupProbPct:0^predictedBlowupProbPct, emergingToxic:0b^emergingToxic from r;
  `predictedBlowupProbPct xdesc r};

.brk.pred.info.loaded:1b;
