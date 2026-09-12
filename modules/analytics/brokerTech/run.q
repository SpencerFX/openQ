//====================================================================
// Directory: modules/analytics/brokerTech/run.q
//
// About:
// Loads the retail-brokerage HDB (C:/data/retail, schemas/schema_retail.q)
// read-only, runs brokerTech.q's (its own sibling file) full analytics
// suite over a date window, and prints a brokerage & risk report. Not a
// tp/rdb/idb/hdb/cep pipeline and not a `-procType` role - like
// modules/backtest/run.q and modules/analytics/candle/run.q, this is a
// plain script outside core/init.q's/core/config.q's machinery, since
// the archive is static on disk with nothing live to subscribe to. It
// loads the archive directly the same way core/hdb.q's own
// .oq.hdb.loadHDB does (schema stub first, then `system"l"` against the
// real root, which transparently replaces the stub) - strictly
// READ-ONLY: nothing here writes to -hdbroot.
//
// The report sections mirror what a real FX/CFD broker risk desk watches
// (platforms like tapaas.com): book revenue summary, revenue by
// instrument, exposure concentration and peak concurrent exposure, a
// per-provider profitability leaderboard, drawdown risk, monthly-return
// stats, a toxicity ranking, A-book/B-book routing recommendations with
// the book-level optimisation headline, and risk-threshold breach alerts.
//
// Run from the repo root (like every other modules/*/run.q or
// simulator.q - relative loads below are repo-root-relative):
//   q modules/analytics/brokerTech/run.q [-hdbroot <path>]
//     [-sDate <date>] [-eDate <date>] [-lookbackDays <n>]
//     [-top <n>] [-minTrades <n>] [-signal <signalId>] [-csvDir <path>]
// -hdbroot defaults to C:/data/retail. The window defaults to the last
// -lookbackDays (default 180) of partitions ending at the newest one;
// -sDate/-eDate override either end explicitly. -top (default 15) caps
// each leaderboard. -minTrades (default 10) filters thin accounts out of
// the profitability / toxicity tables. -signal restricts the whole run
// to one provider. -csvDir, if given, also writes each section as a CSV
// there (nothing is written otherwise).
//
// Sections 1-10 are the book-wide / per-provider analytics; 11-17 roll
// the same up per brokerage, where the broker is parsed from sig.name
// (.brk.broker.* - providers that don't name a broker land in `UNKNOWN).
// 18-21 are predictive.q's forward-looking analytics: an equity-curve
// trend projection, a toxicity-trajectory early warning, a genuinely
// backtested blowup-risk calibration (trained on the window's first
// half, scored on its second), and a book/broker revenue forecast
// graded with its own walk-forward accuracy - see predictive.q's header
// for what "backtested" means here and its honest limitations.
//====================================================================

system "l schemas/schema_retail.q";
system "l modules/analytics/brokerTech/brokerTech.q";
system "l modules/analytics/brokerTech/predictive.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

hdbroot:      opt[args;`hdbroot;"C:/data/retail"];
lookbackDays: "J"$opt[args;`lookbackDays;"180"];
topN:         "J"$opt[args;`top;"15"];
minTrades:    "J"$opt[args;`minTrades;"10"];
csvDir:       opt[args;`csvDir;""];

-1 "brokerTech - loading HDB read-only from ",hdbroot," ...";
system "l ",hdbroot;

if[0=count .Q.PV;'"no partitions found under ",hdbroot];
maxD:last .Q.PV;
eDate:$[`eDate in key args;"D"$first args`eDate;maxD];
sDate:$[`sDate in key args;"D"$first args`sDate;eDate-lookbackDays];
sDate:sDate|first .Q.PV;
-1 "window: ",(string sDate)," .. ",string eDate;

// --- pull the window once ---
w:select date, tradeKey, signalId, kind, action, orderType, symbol,
    openTime, closeTime, openPrice, closePrice, sl, tp, volume,
    commission, swap, profit, cancelled
  from trade where date within (sDate;eDate);
eq:select date, signalId, ts, balance, equity
  from equity where date within (sDate;eDate);
mn:select from monthly;
s:0!select signalId, name, authorName, mtVersion, firstSeen, lastSeen from sig;

if[`signal in key args;
  sid:"J"$first args`signal;
  w:select from w where signalId=sid;
  eq:select from eq where signalId=sid;
  mn:select from mn where signalId=sid];

// Scope equity / monthly to the providers that actually traded in the
// window - the scraped `equity` table carries thousands of dormant
// accounts, and a broker risk report is about the *active* book. The
// brokerTech.q functions themselves stay general (they'll analyse
// whatever they're handed); this narrowing is a run.q reporting choice.
activeIds:exec distinct signalId from w;
eq:select from eq where signalId in activeIds;
mn:select from mn where signalId in activeIds;

-1 "rows: trade ",(string count w)," | equity ",(string count eq)," | monthly ",(string count mn)," | signals ",string count s;
if[0=count w;'"no trade rows in window - widen -lookbackDays or check -hdbroot"];

nm:`signalId xkey s;
addName:{[nm;t] $[`signalId in cols t; (0!t) lj nm; t]};
lim:{[n;t] $[n<count t;n sublist t;t]};
dictTab:{[d] ([] metric:key d; val:value d)};
hdr:{[s] -1 ""; -1 "=================================================================="; -1 s; -1 "=================================================================="};

// ------------------------------------------------------------------
hdr "1. BOOK REVENUE SUMMARY (window totals)";
show dictTab .brk.rev.summary w;

hdr "2. REVENUE BY INSTRUMENT";
revI:.brk.rev.byInstrument w;
-1 "-- best ",(string topN)," by total revenue --";
show lim[topN;revI];
-1 "-- worst ",(string topN)," (revenue leak) --";
show lim[topN;`totalRev xasc revI];

hdr "3. EXPOSURE CONCENTRATION (book-level)";
show dictTab .brk.expo.bookConcentration w;
-1 "";
-1 "-- peak concurrent open lots by symbol (top ",(string topN),") --";
show lim[topN;.brk.expo.peakConcurrent w];

hdr "4. PROFITABILITY LEADERBOARD (per provider, minTrades>=",(string minTrades),")";
perf:select from .brk.perf.bySignal w where nTrades>=minTrades;
perfN:addName[nm;perf];
-1 "-- top ",(string topN)," by net client profit (= worst for a B-book) --";
show lim[topN;`netProfit xdesc select signalId, name, nTrades, winRatePct, profitFactor, expectancy, netProfit, totalLots, avgHoldMin, tradesPerDay from perfN];
-1 "-- top ",(string topN)," client losers (best for a B-book) --";
show lim[topN;`netProfit xasc select signalId, name, nTrades, winRatePct, profitFactor, expectancy, netProfit, totalLots, avgHoldMin, tradesPerDay from perfN];

hdr "5. DRAWDOWN RISK (per provider, from intraday equity curve; nPts>=30)";
ddN:addName[nm;select from .brk.perf.drawdown eq where nPts>=30];
show lim[topN;`maxDDPct xasc select signalId, name, nPts, netReturnPct, maxDDPct, curDDPct, underwaterSamplePct, ddDaysApprox, recoveryFactor from ddN];

hdr "6. MONTHLY-RETURN STATS (per provider, reported per-month returns)";
-1 "(NB: `monthly` is provider-reported and unvalidated - extreme figures are in the source, not a calc error)";
msN:addName[nm;.brk.perf.monthlyStats mn];
show lim[topN;`annualisedRetPct xdesc select signalId, name, nMonths, avgMonthlyRetPct, monthlyVolPct, posMonthPct, annualisedRetPct, monthlySharpe from msN];

hdr "7. TOXICITY RANKING (per provider, minTrades>=",(string minTrades),")";
tox:select from .brk.tox.score[w;eq] where nTrades>=minTrades;
toxN:addName[nm;tox];
show lim[topN;select signalId, name, nTrades, winRatePct, maxDDPct, scalpScore, martingaleScore, oneSidedScore, burstScore, tooGoodScore, toxScore, bucket from toxN];
-1 ""; -1 "bucket counts:";
show select nProviders:count i by bucket from tox;

hdr "8. A-BOOK / B-BOOK ROUTING RECOMMENDATIONS";
rec:.brk.book.recommend[w;eq];
recN:addName[nm;rec];
show select nProviders:count i, sumExpectedRev:sum expectedRev, rationale:first rationale by route from rec;
-1 "";
{[recN;rt] r:`expectedRev xdesc select from recN where route=rt;
  if[count r;
    -1 " -- route ",(string rt)," (top 3 by expected revenue) --";
    show 3 sublist select signalId, name, clientNetProfit, totalLots, toxScore, bBookTotalRev, aBookRev, expectedRev from r]}[recN;] each `A`B`SPLIT;

hdr "9. ROUTING OPTIMISATION HEADLINE";
show dictTab .brk.book.optimise[w;eq];

hdr "10. RISK-THRESHOLD BREACH ALERTS";
al:.brk.alert.breaches[w;eq];
alN:addName[nm;al];
-1 (string count al)," breach(es) across the active book",$[(3*topN)<count al;" (showing first ",string[3*topN],")";""],":";
show lim[3*topN;alN];
-1 ""; -1 "by kind:";
show select nBreaches:count i by kind, severity from al;

// ------------------------------------------------------------------
// Per-brokerage cut (broker parsed from sig.name - see .brk.broker.*).
// Providers whose name discloses no broker land in `UNKNOWN.
brokSpine:0!select signalId, name from s where signalId in activeIds;
brokDist:select nProviders:count i by brokerTag from .brk.broker.tag brokSpine;

hdr "11. BROKER ROSTER (parsed from sig.name)";
-1 (string count select from brokDist where brokerTag<>`UNKNOWN)," named broker(s), ",(string first exec nProviders from brokDist where brokerTag=`UNKNOWN)," provider(s) undisclosed";
show `nProviders xdesc select brokerTag, nProviders, providers from .brk.broker.roster select from s where signalId in activeIds;

hdr "12. REVENUE BY BROKER";
show .brk.broker.pnl[w;s];

hdr "13. PROFITABILITY BY BROKER (pooled across each broker's providers)";
show .brk.broker.perf[w;s];

hdr "14. EXECUTION BEHAVIOUR BY BROKER (cancel / quote-stuffing rate)";
show .brk.broker.exec[w;s];

hdr "15. RISK BY BROKER (drawdown + toxicity)";
show .brk.broker.risk[w;eq;s];

hdr "16. ROUTING BY BROKER";
show .brk.broker.routing[w;eq;s];

hdr "17. BROKER SCORECARD (consolidated)";
show .brk.broker.summary[w;eq;s];

// ------------------------------------------------------------------
// Predictive analytics (predictive.q) - forward-looking, each backtested
// against this same window rather than just asserted; see its header.
hdr "18. EQUITY TREND PROJECTION (per provider, minTrades>=",(string minTrades),")";
et:.brk.pred.equityTrend eq;
etN:addName[nm;select from et where nDays>=10];
-1 "-- top ",(string topN)," projected UP over the next ",(string `long$.brk.pred.cfg`forecastHorizonDays)," days --";
show lim[topN;`projectedRetPct xdesc select signalId, name, nDays, lastEq, slopePerDay, r2, projectedRetPct, direction from etN];
-1 "-- top ",(string topN)," projected DOWN --";
show lim[topN;`projectedRetPct xasc select signalId, name, nDays, lastEq, slopePerDay, r2, projectedRetPct, direction from etN];

hdr "19. TOXICITY TRAJECTORY - EARLY WARNING";
tt:.brk.pred.toxTrend[w;eq];
ttN:addName[nm;tt];
emerg:select from ttN where emergingToxic;
-1 (string count emerg)," provider(s) trending toward HIGH toxicity but not there yet:";
show lim[topN;`toxTrendSlope xdesc select signalId, name, nBuckets, curToxScore, curBucket, toxTrendSlope, r2 from emerg];

hdr "20. BLOWUP-RISK CALIBRATION (backtested - see predictive.q header)";
br:.brk.pred.blowupRisk[w;eq];
-1 "calibration curve (trained on the window's first half, scored on its second):";
show br`curve;
-1 "";
brN:addName[nm;br`scores];
-1 "-- top ",(string topN)," current signals by predicted blowup probability --";
show lim[topN;brN];

hdr "21. REVENUE FORECAST (book + per-broker, each graded with its own backtest)";
show .brk.pred.revenueForecast w;
-1 "";
show .brk.pred.brokerRevenueForecast[w;s];

// ------------------------------------------------------------------
if[count csvDir;
  mkcsv:{[dir;fn;t] p:dir,"/",string[fn],".csv"; (`$":",p) 0: csv 0: t; -1 "wrote ",p};
  -1 "";
  mkcsv[csvDir;`revenue_by_instrument;revI];
  mkcsv[csvDir;`profitability;perfN];
  mkcsv[csvDir;`drawdown;ddN];
  mkcsv[csvDir;`toxicity;toxN];
  mkcsv[csvDir;`routing;recN];
  mkcsv[csvDir;`alerts;alN];
  mkcsv[csvDir;`broker_scorecard;.brk.broker.summary[w;eq;s]];
  mkcsv[csvDir;`broker_revenue;.brk.broker.pnl[w;s]];
  mkcsv[csvDir;`equity_trend;etN];
  mkcsv[csvDir;`blowup_risk_curve;br`curve];
  mkcsv[csvDir;`blowup_risk_scores;brN];
  mkcsv[csvDir;`revenue_forecast_by_broker;.brk.pred.brokerRevenueForecast[w;s]]];

-1 ""; -1 "brokerTech report complete.";
exit 0;
