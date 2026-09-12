//====================================================================
// openQ brokerTech - retail brokerage & risk analytics
//
// Pure batch functions over the retail-brokerage HDB (C:/data/retail,
// schemas/schema_retail.q) - a MetaTrader "Signals" copy-trading
// dataset: per-provider trade blotters (`trade`), intraday equity curves
// (`equity`), headline growth (`growth`) and per-month returns
// (`monthly`), and provider identity (`sig`). No IPC, no live state, the
// same shape every other domain analytics library in this repo
// (modules/analytics/*/*.q, modules/backtest/backtest.q) uses - a table
// (or two) in, a table out. modules/analytics/brokerTech/run.q is the
// only thing that knows where the data actually lives; it loads that HDB
// read-only and feeds these functions.
//
// The analytics deliberately mirror what a real FX/CFD broker risk desk
// watches (the feature set of platforms like tapaas.com): exposure and
// concentration, execution quality and order behaviour, per-client
// (here: per-signal-provider) profitability and drawdown, toxic/abusive
// trader detection, A-book / B-book routing optimisation, instrument-
// level revenue attribution, and risk-threshold breach alerting. Every
// score is a deterministic, documented formula with weights/thresholds
// in .brk.cfg - explainable, not a fitted model (there's no labelled
// "this account was toxic" training set here), the same stance
// primeFinance.q's allocator takes.
//
// "Client" == signal provider == one `signalId`. A provider's `trade`
// rows are their account's orders; the broker, if it internalises
// (B-books) that flow, is the counterparty - so broker market PnL on a
// trade is `neg profit`, and `commission`/`swap` (both stored negative =
// a cost to the client) are broker revenue as `neg commission` /
// `neg swap`. `.brk.notional` (volume * openPrice) is a *relative*
// exposure measure - there's no per-symbol contract-size table here, so
// it ranks and shares correctly but isn't a real currency amount.
//
// Namespaces:
//   .brk.cfg        - all tunable thresholds / blend weights
//   .brk.<helper>   - executed/orders/ledger filters, holdMin, notional,
//                     clamp, pctile
//   .brk.expo.*     - exposure & concentration
//   .brk.exec.*     - execution quality & order behaviour
//   .brk.perf.*     - per-signal profitability, drawdown, monthly stats
//   .brk.tox.*      - toxic / abusive trader scoring
//   .brk.book.*     - A-book / B-book routing recommendation + optimiser
//   .brk.rev.*      - revenue attribution
//   .brk.alert.*    - risk-threshold breach alerts
//   .brk.cluster.*  - client (signal provider) behavioural clustering
//====================================================================
.brk.info.loaded:0b;

// All tunables in one dict (same one-liner style as .prime.cfg /
// .bt.pipelineDefaults). USD-ish figures are in the dataset's own
// account currency, uncorrected.
.brk.cfg:`scalpMaxHoldMin`scalpTradesPerDay`mgScale`burstGapMin`suspiciousWinRate`expectedDDPct`wScalp`wMartingale`wOneSided`wBurst`wTooGood`toxMed`toxHigh`toxExtreme`profitableClientUsd`largeSizeLots`splitHedgeFrac`alertMaxDDPct`alertCancelRate`alertConcTop1Pct`alertToxScore`alertMinEquityPts`alertMinTrades!(5f;20f;1.0;1f;0.90;0.15;0.25;0.25;0.15;0.15;0.20;0.33;0.55;0.75;0f;50f;0.5;0.40;0.50;0.60;0.55;30;10);

//--------------------------------------------------------------------
// Helpers
//--------------------------------------------------------------------

//@func  | .brk.clamp
//@param  | x  | float
//@param  | lo | float
//@param  | hi | float
//@desc
// Clamp x into [lo;hi]. Vectorised.
//@desc
.brk.clamp:{[x;lo;hi] lo|hi&x};

//@func  | .brk.pctile
//@param  | p | float | 0..1
//@param  | x | float list
//@desc
// Nearest-rank percentile (this q build has no `percentile` builtin).
// Nulls dropped; empty input -> 0n.
//@desc
.brk.pctile:{[p;x]
  x:asc x where not null x;
  $[0=count x; 0n; x floor 0.5+p*-1+count x]};

//@func  | .brk.holdMin
//@param  | t | table | .prime-style rows with openTime/closeTime
//@desc
// Hold time in minutes (float) per row: closeTime-openTime, ns -> min.
//@desc
.brk.holdMin:{[t] (`long$(t[`closeTime]-t`openTime))%6e10};

//@func  | .brk.notional
//@param  | t | table | rows with volume/openPrice
//@desc
// Relative traded notional per row: volume (lots) * openPrice. Not a
// real currency amount (no contract-size table) - use for ranking and
// share-of-book, not for a P&L figure.
//@desc
.brk.notional:{[t] t[`volume]*t`openPrice};

//@func  | .brk.executed
//@param  | t | table | raw `trade` rows
//@desc
// Real fills only: kind=`trade and cancelled=0. Everything downstream
// that talks about P&L / hold time / win rate starts here.
//@desc
.brk.executed:{[t] select from t where kind=`trade, cancelled=0};

//@func  | .brk.orders
//@param  | t | table
//@desc
// All order rows (fills + never-executed cancels), kind=`trade. For
// cancel-rate / order-mix behaviour, where the cancels are the point.
//@desc
.brk.orders:{[t] select from t where kind=`trade};

//@func  | .brk.ledger
//@param  | t | table
//@desc
// Balance-operation rows (deposits / withdrawals / credits), kind=`balance.
//@desc
.brk.ledger:{[t] select from t where kind=`balance};

//--------------------------------------------------------------------
// Source-window pulls (.brk.src.*) - overridable per-HDB
//--------------------------------------------------------------------
// Every caller (the gateway's SUITE/CLUSTER_QUERY, run.q) gets its window
// through these four instead of a bare "select ... from trade/equity/sig/
// monthly where date within (...)" - the default bodies below are exactly
// that bare select (schema_retail.q's single-platform shape, `trade`/
// `equity` already keyed by `signalId`, `sig`/`monthly` already in their
// final shape), so nothing changes for that HDB. A differently-shaped HDB
// (e.g. modules/analytics/brokerTech/brokerTechSourceR.q, loaded AFTER
// this file, for the multi-platform C:/data/r source) overrides these four
// to hand back the exact same column shape from whatever its own tables
// actually look like - every other function in this file takes `trades`/
// `equity`/`sig` as a plain parameter and never touches these globals
// directly, so nothing below this section needs to know or care which
// HDB it's running against.
.brk.src.trade:{[sDate;eDate]
  select date,tradeKey,signalId,kind,action,orderType,symbol,openTime,closeTime,
      openPrice,closePrice,sl,tp,volume,commission,swap,profit,cancelled
    from trade where date within (sDate;eDate)};

.brk.src.equity:{[sDate;eDate]
  select date,signalId,ts,balance,equity from equity where date within (sDate;eDate)};

.brk.src.growth:{[sDate;eDate]
  select date,signalId,growthPct from growth where date within (sDate;eDate)};

.brk.src.sig:{[] sig};

.brk.src.monthly:{[] monthly};

//--------------------------------------------------------------------
// Exposure & concentration (.brk.expo.*)
//--------------------------------------------------------------------

//@func  | .brk.expo.bySymbol
//@param  | trades | table | raw `trade` rows
//@desc
// One row per symbol: trade count, gross relative notional, buy/sell/net
// lots, client P&L, and that symbol's share of the whole book's notional.
//@desc
.brk.expo.bySymbol:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] symbol:`symbol$(); nTrades:`long$(); grossNotional:`float$();
    buyLots:`float$(); sellLots:`float$(); netLots:`float$(); clientPnl:`float$();
    bookSharePct:`float$())];
  t:update notl:.brk.notional t from t;
  // 0! immediately: `r`col` on a still-keyed select result is a KEY
  // lookup, not column access (a symbol key against a symbol/long key
  // column - silently wrong, or 'type)
  r:0!select nTrades:count i, grossNotional:sum notl,
      buyLots:sum volume*action=`buy, sellLots:sum volume*action=`sell,
      netLots:(sum volume*action=`buy)-sum volume*action=`sell,
      clientPnl:sum profit
    by symbol from t;
  tot:sum r`grossNotional;
  r:update bookSharePct:?[tot>0; 100*grossNotional%tot; 0n] from r;
  `grossNotional xdesc r};

//@func  | .brk.expo.bySignal
//@param  | trades | table
//@desc
// One row per signal provider: same measures as .brk.expo.bySymbol but
// grouped by account, plus its share of the whole book.
//@desc
.brk.expo.bySignal:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] signalId:`long$(); nTrades:`long$(); grossNotional:`float$();
    buyLots:`float$(); sellLots:`float$(); netLots:`float$(); clientPnl:`float$();
    bookSharePct:`float$())];
  t:update notl:.brk.notional t from t;
  r:0!select nTrades:count i, grossNotional:sum notl,
      buyLots:sum volume*action=`buy, sellLots:sum volume*action=`sell,
      netLots:(sum volume*action=`buy)-sum volume*action=`sell,
      clientPnl:sum profit
    by signalId from t;
  tot:sum r`grossNotional;
  r:update bookSharePct:?[tot>0; 100*grossNotional%tot; 0n] from r;
  `grossNotional xdesc r};

//@func  | .brk.expo.signalConcentration
//@param  | trades | table
//@desc
// Per signal: how concentrated its own notional is in one instrument -
// number of symbols traded, top instrument and its %, and the symbol
// Herfindahl index (sum of squared shares, 1 = one instrument only).
//@desc
.brk.expo.signalConcentration:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] signalId:`long$(); nSymbols:`long$(); top1Symbol:`symbol$();
    top1SymbolPct:`float$(); symbolHHI:`float$())];
  t:update notl:.brk.notional t from t;
  bs:select notl:sum notl by signalId, symbol from t;
  tt:select tot:sum notl by signalId from bs;
  r:update sharePct:?[tot>0; 100*notl%tot; 0n], shr:?[tot>0; notl%tot; 0n] from bs lj tt;
  select nSymbols:count i,
      top1Symbol:first symbol where sharePct=max sharePct,
      top1SymbolPct:max sharePct,
      symbolHHI:sum shr*shr
    by signalId from 0!r};

//@func  | .brk.expo.bookConcentration
//@param  | trades | table
//@desc
// One-row book-level concentration snapshot: symbol/signal Herfindahl,
// top-1 and top-5 concentration % for both dimensions, and the counts.
//@desc
.brk.expo.bookConcentration:{[trades]
  bySym:.brk.expo.bySymbol trades;
  bySig:.brk.expo.bySignal trades;
  symSh:(0^bySym`bookSharePct)%100;
  sigSh:(0^bySig`bookSharePct)%100;
  `symbolHHI`signalHHI`top1SymbolPct`top5SymbolPct`top1SignalPct`top5SignalPct`nSymbols`nSignals!(
    sum symSh*symSh;
    sum sigSh*sigSh;
    100*max 0f,symSh;
    100*sum 5 sublist desc symSh;
    100*max 0f,sigSh;
    100*sum 5 sublist desc sigSh;
    count bySym;
    count bySig)};

//@func  | .brk.expo.peakConcurrent
//@param  | trades | table
//@desc
// Per symbol: the maximum lots open at the same instant over the window,
// reconstructed from a sweep line over (+volume at openTime, -volume at
// closeTime). A real "peak exposure" number the per-trade rollups can't
// give - a book can trade huge cumulative volume while never holding
// much at once, or vice versa.
//@desc
.brk.expo.peakConcurrent:{[trades]
  t:.brk.executed trades;
  t:select symbol, openTime, closeTime, volume from t
    where not null openTime, not null closeTime, closeTime>=openTime;
  if[not count t;:([] symbol:`symbol$(); peakConcurrentLots:`float$(); peakAt:`timestamp$())];
  ev:(select symbol, tm:openTime, d:volume from t),
     (select symbol, tm:closeTime, d:neg volume from t);
  ev:`symbol`tm xasc ev;
  ev:update run:sums d by symbol from ev;
  `peakConcurrentLots xdesc select
      peakConcurrentLots:max run,
      peakAt:first tm where run=max run
    by symbol from ev};

//--------------------------------------------------------------------
// Execution quality & order behaviour (.brk.exec.*)
//--------------------------------------------------------------------

.brk.priv.pendingTypes:`$("Buy Limit";"Sell Limit";"Buy Stop";"Sell Stop");
.brk.priv.limitTypes:`$("Buy Limit";"Sell Limit");
.brk.priv.stopTypes:`$("Buy Stop";"Sell Stop");

//@func  | .brk.exec.cancelRates
//@param  | orders | table | raw `trade` rows (fills + cancels)
//@desc
// Per signal: order count, executed vs cancelled, cancel rate %. A high
// cancel rate is a classic quote-stuffing / gaming signal - orders
// placed to probe or move the book, not to trade.
//@desc
.brk.exec.cancelRates:{[orders]
  o:.brk.orders orders;
  if[not count o;:([] signalId:`long$(); nOrders:`long$(); nExecuted:`long$();
    nCancelled:`long$(); cancelRatePct:`float$())];
  select nOrders:count i,
      nExecuted:sum cancelled=0, nCancelled:sum cancelled=1,
      cancelRatePct:100*(sum cancelled=1)%count i
    by signalId from o};

//@func  | .brk.exec.orderMix
//@param  | orders | table
//@desc
// Per signal: % market vs pending, and limit vs stop within pending.
//@desc
.brk.exec.orderMix:{[orders]
  o:.brk.orders orders;
  if[not count o;:([] signalId:`long$(); nOrders:`long$(); marketPct:`float$();
    pendingPct:`float$(); limitPct:`float$(); stopPct:`float$())];
  select nOrders:count i,
      marketPct:100*(sum orderType in `Buy`Sell)%count i,
      pendingPct:100*(sum orderType in .brk.priv.pendingTypes)%count i,
      limitPct:100*(sum orderType in .brk.priv.limitTypes)%count i,
      stopPct:100*(sum orderType in .brk.priv.stopTypes)%count i
    by signalId from o};

//@func  | .brk.exec.holdTimeDist
//@param  | trades | table
//@desc
// Per signal: hold-time percentiles (minutes) plus the sub-1-min and
// sub-5-min share - the scalping / latency-gaming lens.
//@desc
.brk.exec.holdTimeDist:{[trades]
  t:.brk.executed trades;
  t:update holdMin:.brk.holdMin t from t;
  t:select from t where not null holdMin, holdMin>=0;
  if[not count t;:([] signalId:`long$(); nTrades:`long$(); p5:`float$(); p25:`float$();
    p50:`float$(); p75:`float$(); p95:`float$(); subMinPct:`float$();
    sub5MinPct:`float$(); maxHoldMin:`float$())];
  select nTrades:count i,
      p5:.brk.pctile[0.05;holdMin], p25:.brk.pctile[0.25;holdMin],
      p50:.brk.pctile[0.50;holdMin], p75:.brk.pctile[0.75;holdMin],
      p95:.brk.pctile[0.95;holdMin],
      subMinPct:100*(sum holdMin<1)%count i,
      sub5MinPct:100*(sum holdMin<=.brk.cfg`scalpMaxHoldMin)%count i,
      maxHoldMin:max holdMin
    by signalId from t};

//@func  | .brk.exec.stopSlippage
//@param  | trades | table
//@desc
// Per signal, over trades that carried a stop (sl>0): how often the exit
// landed at or beyond the stop, and the average/max adverse gap between
// the stop level and the actual close. A proxy for stop-out slippage -
// the raw feed has no requested-vs-filled pair, so this is close price
// vs stop level, not a true slippage measurement.
//@desc
.brk.exec.stopSlippage:{[trades]
  t:.brk.executed trades;
  t:select from t where sl>0, not null closePrice, action in `buy`sell;
  if[not count t;:([] signalId:`long$(); nWithStop:`long$(); nStoppedOut:`long$();
    stopHitRatePct:`float$(); avgAdverseGapPx:`float$(); maxAdverseGapPx:`float$())];
  t:update stoppedOut:?[action=`buy; closePrice<=sl; closePrice>=sl],
      gapPx:?[action=`buy; sl-closePrice; closePrice-sl] from t;
  // parens matter: `max 0f,gapPx where stoppedOut` splits at the comma
  // into two select columns, one of them an unnamed nested list
  select nWithStop:count i,
      nStoppedOut:sum stoppedOut,
      stopHitRatePct:100*(sum stoppedOut)%count i,
      avgAdverseGapPx:avg (gapPx where stoppedOut and gapPx>0),
      maxAdverseGapPx:max (0f,gapPx where stoppedOut)
    by signalId from t};

//--------------------------------------------------------------------
// Per-signal profitability, drawdown, monthly stats (.brk.perf.*)
//--------------------------------------------------------------------

//@func  | .brk.perf.bySignal
//@param  | trades | table
//@desc
// Per signal provider: trade count, win rate, gross/avg win & loss,
// profit factor, expectancy, net P&L, commission & swap totals (as
// stored - negative = client paid), total lots, hold-time stats, first/
// last trade, span, trades/day.
//@desc
.brk.perf.bySignal:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] signalId:`long$(); nTrades:`long$(); nWin:`long$(); nLoss:`long$();
    winRatePct:`float$(); grossWin:`float$(); grossLoss:`float$(); avgWin:`float$();
    avgLoss:`float$(); netProfit:`float$(); grossCommission:`float$(); grossSwap:`float$();
    totalLots:`float$(); avgHoldMin:`float$(); medHoldMin:`float$(); sub5MinPct:`float$();
    firstTrade:`timestamp$(); lastTrade:`timestamp$(); profitFactor:`float$();
    expectancy:`float$(); spanDays:`float$(); tradesPerDay:`float$())];
  t:update holdMin:.brk.holdMin t from t;
  r:select nTrades:count i,
      nWin:sum profit>0, nLoss:sum profit<0,
      winRatePct:100*(sum profit>0)%count i,
      grossWin:sum profit*profit>0, grossLoss:sum profit*profit<0,
      avgWin:avg profit where profit>0, avgLoss:avg profit where profit<0,
      netProfit:sum profit,
      grossCommission:sum commission, grossSwap:sum swap,
      totalLots:sum volume,
      avgHoldMin:avg holdMin, medHoldMin:.brk.pctile[0.5;holdMin],
      sub5MinPct:100*(sum holdMin<=.brk.cfg`scalpMaxHoldMin)%count i,
      firstTrade:min openTime, lastTrade:max closeTime
    by signalId from t;
  r:update profitFactor:?[grossLoss<0; grossWin%abs grossLoss; 0n],
      expectancy:netProfit%nTrades,
      spanDays:(`long$(lastTrade-firstTrade))%864e11 from r;
  update tradesPerDay:?[spanDays>0; nTrades%spanDays; 0n] from 0!r};

//@func  | .brk.perf.drawdown
//@param  | equity | table | `equity` rows (signalId, ts, balance, equity)
//@desc
// Per signal, from the intraday equity curve: max & current drawdown %,
// share of samples underwater (a rough time-in-drawdown), an approximate
// underwater duration in days, net return % over the window, and a
// recovery factor (net return / abs max drawdown).
//@desc
.brk.perf.drawdown:{[equity]
  e:`signalId`ts xasc select signalId, ts, equity from equity where not null equity;
  if[not count e;:([] signalId:`long$(); nPts:`long$(); firstEq:`float$(); lastEq:`float$();
    maxDDPct:`float$(); curDDPct:`float$(); underwaterSamplePct:`float$();
    spanDays:`float$(); netReturnPct:`float$(); recoveryFactor:`float$();
    ddDaysApprox:`float$())];
  e:update peak:maxs equity by signalId from e;
  e:update dd:?[peak>0; 100*(equity-peak)%peak; 0n] from e;
  r:select nPts:count i, firstEq:first equity, lastEq:last equity,
      maxDDPct:min dd, curDDPct:last dd,
      underwaterSamplePct:100*(sum dd<0)%count i,
      spanDays:(`long$(max[ts]-min ts))%864e11
    by signalId from e;
  r:update netReturnPct:?[firstEq>0; 100*(lastEq-firstEq)%firstEq; 0n] from r;
  r:update recoveryFactor:?[maxDDPct<0; netReturnPct%abs maxDDPct; 0n],
      ddDaysApprox:(underwaterSamplePct%100)*spanDays from r;
  0!r};

//@func  | .brk.perf.monthlyStats
//@param  | monthly | table | `monthly` rows (signalId, year, month, returnPct, yearlyPct)
//@desc
// Per signal, from the reported per-month returns: month count, mean &
// stdev monthly return %, best/worst month, positive-month share,
// compounded annualised return %, and a monthly Sharpe (mean/stdev * sqrt 12).
//@desc
.brk.perf.monthlyStats:{[monthly]
  m:select from monthly where not null returnPct;
  if[not count m;:([] signalId:`long$(); nMonths:`long$(); avgMonthlyRetPct:`float$();
    monthlyVolPct:`float$(); bestMonthPct:`float$(); worstMonthPct:`float$();
    posMonthPct:`float$(); annualisedRetPct:`float$(); monthlySharpe:`float$())];
  select nMonths:count i,
      avgMonthlyRetPct:avg returnPct,
      monthlyVolPct:dev returnPct,
      bestMonthPct:max returnPct, worstMonthPct:min returnPct,
      posMonthPct:100*(sum returnPct>0)%count i,
      annualisedRetPct:100*(-1+(prd 1+returnPct%100) xexp 12%count i),
      monthlySharpe:?[0f=dev returnPct; 0n; (avg returnPct)%(dev returnPct)*sqrt 12]
    by signalId from m};

//--------------------------------------------------------------------
// Toxic / abusive trader scoring (.brk.tox.*)
//--------------------------------------------------------------------

//@func  | .brk.tox.bucket
//@param  | s | float | a 0..1 toxicity score
//@desc
// LOW / MEDIUM / HIGH / EXTREME by .brk.cfg's toxMed/toxHigh/toxExtreme;
// null -> UNKNOWN. Same shape as primeFinance's .prime.crowd.bucket.
//@desc
.brk.tox.bucket:{[s]
  $[null s;`UNKNOWN;
    s>=.brk.cfg`toxExtreme;`EXTREME;
    s>=.brk.cfg`toxHigh;`HIGH;
    s>=.brk.cfg`toxMed;`MEDIUM;
    `LOW]};

//@func  | .brk.tox.score
//@param  | trades | table
//@param  | equity | table
//@desc
// One row per signal provider with five component scores (each 0..1), a
// weighted composite `toxScore`, and its bucket:
//   scalpScore      - sub-5-min share + trades/day (feed scalping)
//   martingaleScore - avg lot-size ratio after a loss vs after a win
//                     (doubling-down / martingale)
//   oneSidedScore   - directional bias, |2*buyShare - 1|
//   burstScore      - share of consecutive opens < burstGapMin apart
//                     (grid / burst entries)
//   tooGoodScore    - high win rate with little/no drawdown (a book
//                     that never loses is usually exploiting stale
//                     pricing or latency, not skill)
// Weights and thresholds are all in .brk.cfg. Deterministic and
// explainable - no labelled training data exists here to fit against.
//@desc
.brk.tox.score:{[trades;equity]
  perf:.brk.perf.bySignal trades;
  dd:.brk.perf.drawdown equity;
  t:.brk.executed trades;
  ord:`signalId`openTime xasc select signalId, openTime, action, volume, profit from t;
  ord:update pv:prev volume, pp:prev profit by signalId from ord;
  ord:update gapMin:(`long$(openTime-prev openTime))%6e10 by signalId from ord;
  // martingale: lot ratio after a losing trade vs after a winning one
  mg0:update vr:volume%pv, lb:pp<0 from select from ord where pv>0;
  mg:select afterLoss:avg vr where lb, afterWin:avg vr where not lb by signalId from mg0;
  mg:update afterLoss:0^afterLoss, afterWin:1^afterWin from mg;
  mg:update martingaleScore:.brk.clamp[(afterLoss-afterWin)%.brk.cfg`mgScale;0f;1f] from mg;
  // directional bias
  os:select buyShare:(sum action=`buy)%count i by signalId from t;
  os:update oneSidedScore:.brk.clamp[abs (2*buyShare)-1;0f;1f] from os;
  // burst entries
  bu:select burstScore:(sum (gapMin>=0) and gapMin<.brk.cfg`burstGapMin)%count i by signalId from ord;
  // assemble onto the per-signal perf base
  r:0!perf lj `signalId xkey select signalId, maxDDPct from dd;
  r:r lj `signalId xkey select signalId, martingaleScore from mg;
  r:r lj `signalId xkey select signalId, oneSidedScore from os;
  r:r lj `signalId xkey select signalId, burstScore from bu;
  r:update martingaleScore:0^martingaleScore, oneSidedScore:0^oneSidedScore,
      burstScore:0^burstScore, maxDDPct:0^maxDDPct from r;
  r:update
      scalpScore:.brk.clamp[
        (0.7*sub5MinPct%100)
        +0.3*.brk.clamp[(0^tradesPerDay)%.brk.cfg`scalpTradesPerDay;0f;1f];
        0f;1f],
      tooGoodScore:.brk.clamp[
        (.brk.clamp[((winRatePct%100)-0.5)*2;0f;1f])
        *(1f-.brk.clamp[(abs maxDDPct)%100*.brk.cfg`expectedDDPct;0f;1f]);
        0f;1f]
    from r;
  r:update toxScore:
      (.brk.cfg[`wScalp]*scalpScore)
      +(.brk.cfg[`wMartingale]*martingaleScore)
      +(.brk.cfg[`wOneSided]*oneSidedScore)
      +(.brk.cfg[`wBurst]*burstScore)
      +(.brk.cfg[`wTooGood]*tooGoodScore)
    from r;
  `toxScore xdesc update bucket:.brk.tox.bucket each toxScore from
    select signalId, nTrades, winRatePct, maxDDPct, scalpScore, martingaleScore,
      oneSidedScore, burstScore, tooGoodScore, toxScore from r};

//--------------------------------------------------------------------
// A-book / B-book routing (.brk.book.*)
//--------------------------------------------------------------------

//@func  | .brk.book.brokerPnl
//@param  | trades | table
//@desc
// Per signal, the broker-side economics of that provider's flow:
// client net profit, B-book market PnL (neg of it), commission & swap
// revenue (neg of the stored costs), and the two headline totals -
// bBookTotalRev (internalise everything) and aBookRev (hedge the market
// risk, keep only the fee).
//@desc
.brk.book.brokerPnl:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] signalId:`long$(); nTrades:`long$(); clientNetProfit:`float$();
    bBookMarketPnl:`float$(); commissionRev:`float$(); swapRev:`float$();
    totalLots:`float$(); bBookTotalRev:`float$(); aBookRev:`float$())];
  r:select nTrades:count i,
      clientNetProfit:sum profit,
      bBookMarketPnl:neg sum profit,
      commissionRev:neg sum commission,
      swapRev:neg sum swap,
      totalLots:sum volume
    by signalId from t;
  update bBookTotalRev:bBookMarketPnl+commissionRev+swapRev, aBookRev:commissionRev
    from 0!r};

//@func  | .brk.book.recommend
//@param  | trades | table
//@param  | equity | table
//@desc
// Per signal, a deterministic routing call - route in `A`B`SPLIT with a
// one-line rationale and the expected broker revenue under that route:
//   toxScore >= toxHigh            -> A  (don't warehouse sharp flow)
//   client net profit > threshold  -> A  (a consistent winner - hedge)
//   total lots > largeSizeLots     -> SPLIT (partial hedge)
//   otherwise                      -> B  (losing/neutral non-toxic - internalise)
// SPLIT blends aBookRev / bBookTotalRev by cfg`splitHedgeFrac. Same
// stance as primeFinance's allocator: an explainable rule, swappable for
// an optimiser later without changing the signature.
//@desc
.brk.book.recommend:{[trades;equity]
  bp:.brk.book.brokerPnl trades;
  tox:.brk.tox.score[trades;equity];
  r:bp lj `signalId xkey select signalId, toxScore, bucket from tox;
  r:update toxScore:0^toxScore from r;
  r:update route:?[toxScore>=.brk.cfg`toxHigh; `A;
      ?[clientNetProfit>.brk.cfg`profitableClientUsd; `A;
        ?[totalLots>.brk.cfg`largeSizeLots; `SPLIT; `B]]] from r;
  r:update rationale:?[toxScore>=.brk.cfg`toxHigh; `$"high toxicity - pass through, do not warehouse";
      ?[route=`A; `$"consistently profitable client - hedge to LP";
        ?[route=`SPLIT; `$"large size - partial hedge"; `$"losing/neutral non-toxic flow - internalise"]]] from r;
  hf:.brk.cfg`splitHedgeFrac;
  update expectedRev:?[route=`A; aBookRev;
      ?[route=`B; bBookTotalRev; (hf*aBookRev)+(1f-hf)*bBookTotalRev]] from r};

//@func  | .brk.book.optimise
//@param  | trades | table
//@param  | equity | table
//@desc
// Book-level headline: total expected broker revenue under all-B-book,
// under all-A-book, and under .brk.book.recommend's per-signal split,
// plus the uplift of the split over the better of the two extremes and
// the route counts.
//@desc
.brk.book.optimise:{[trades;equity]
  r:.brk.book.recommend[trades;equity];
  allB:sum r`bBookTotalRev;
  allA:sum r`aBookRev;
  rec:sum r`expectedRev;
  `allBBookRev`allABookRev`recommendedRev`upliftVsBestExtreme`nSignals`nRouteA`nRouteB`nRouteSplit!(
    allB; allA; rec; rec-allB|allA;
    count r; sum r[`route]=`A; sum r[`route]=`B; sum r[`route]=`SPLIT)};

//--------------------------------------------------------------------
// Revenue attribution (.brk.rev.*)
//--------------------------------------------------------------------

//@func  | .brk.rev.byInstrument
//@param  | trades | table
//@desc
// Per symbol: broker B-book PnL, commission & swap revenue, total
// revenue, and revenue per lot - "which instruments actually make the
// desk money". Sorted worst-to-best revenue is often the more useful
// read, so this returns it best-first and the caller can reverse.
//@desc
.brk.rev.byInstrument:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] symbol:`symbol$(); nTrades:`long$(); totalLots:`float$();
    clientNetProfit:`float$(); bBookPnl:`float$(); commissionRev:`float$();
    swapRev:`float$(); totalRev:`float$(); revPerLot:`float$())];
  r:select nTrades:count i, totalLots:sum volume,
      clientNetProfit:sum profit, bBookPnl:neg sum profit,
      commissionRev:neg sum commission, swapRev:neg sum swap
    by symbol from t;
  r:update totalRev:bBookPnl+commissionRev+swapRev from r;
  r:update revPerLot:?[totalLots>0; totalRev%totalLots; 0n] from r;
  `totalRev xdesc 0!r};

//@func  | .brk.rev.bySignal
//@param  | trades | table
//@desc
// Per signal provider: the same revenue breakdown as .brk.rev.byInstrument
// but grouped by account - who the desk earns from.
//@desc
.brk.rev.bySignal:{[trades]
  t:.brk.executed trades;
  if[not count t;:([] signalId:`long$(); nTrades:`long$(); totalLots:`float$();
    clientNetProfit:`float$(); bBookPnl:`float$(); commissionRev:`float$();
    swapRev:`float$(); totalRev:`float$())];
  r:select nTrades:count i, totalLots:sum volume,
      clientNetProfit:sum profit, bBookPnl:neg sum profit,
      commissionRev:neg sum commission, swapRev:neg sum swap
    by signalId from t;
  `totalRev xdesc update totalRev:bBookPnl+commissionRev+swapRev from 0!r};

//@func  | .brk.rev.summary
//@param  | trades | table
//@desc
// One-row book-level revenue snapshot over the window: counts, lots,
// client net P&L, and the B-book / A-book revenue totals. ledgerNet is
// the sum of balance-operation amounts (deposits net of withdrawals) as
// carried in `profit` on kind=`balance rows.
//@desc
.brk.rev.summary:{[trades]
  t:.brk.executed trades;
  ord:.brk.orders trades;
  led:.brk.ledger trades;
  `nSignals`nTrades`nOrders`nCancelled`totalLots`clientNetProfit`bBookPnl`commissionRev`swapRev`bBookTotalRev`aBookRev`ledgerNet!(
    count distinct t`signalId;
    count t;
    count ord;
    `long$sum ord[`cancelled]=1;
    sum t`volume;
    sum t`profit;
    neg sum t`profit;
    neg sum t`commission;
    neg sum t`swap;
    (neg sum t`profit)+(neg sum t`commission)+neg sum t`swap;
    neg sum t`commission;
    sum led`profit)};

//--------------------------------------------------------------------
// Risk-threshold breach alerts (.brk.alert.*)
//--------------------------------------------------------------------

//@func  | .brk.alert.breaches
//@param  | trades | table
//@param  | equity | table
//@desc
// One row per (signal, breached threshold): kind in
// `DRAWDOWN`CANCEL_RATE`CONCENTRATION`TOXICITY, a severity, the metric
// name, its value, the threshold it crossed, and a message. Same shape
// as primeFinance's .prime.alerts - a monitoring feed can consume it
// directly. Thresholds are .brk.cfg's alert* entries.
//@desc
.brk.alert.breaches:{[trades;equity]
  perf:.brk.perf.bySignal trades;
  dd:.brk.perf.drawdown equity;
  tox:.brk.tox.score[trades;equity];
  cr:.brk.exec.cancelRates trades;
  conc:.brk.expo.signalConcentration trades;
  // spine is the UNION of providers seen in trades OR in the equity
  // curve - a provider that blew up and then stopped trading still has
  // no `perf` row, but its drawdown must not be silently skipped.
  ids:distinct raze (exec signalId from perf; exec signalId from dd);
  m:([] signalId:ids);
  m:m lj `signalId xkey select signalId, nTrades from perf;
  m:m lj `signalId xkey select signalId, nPts, maxDDPct, curDDPct from dd;
  m:m lj `signalId xkey select signalId, toxScore, bucket from tox;
  m:m lj `signalId xkey select signalId, cancelRatePct from cr;
  m:m lj `signalId xkey select signalId, top1Symbol, top1SymbolPct from conc;
  m:update nTrades:0^nTrades, nPts:0^nPts from m;
  ddLim:neg 100*.brk.cfg`alertMaxDDPct;
  crLim:100*.brk.cfg`alertCancelRate;
  ccLim:100*.brk.cfg`alertConcTop1Pct;
  txLim:.brk.cfg`alertToxScore;
  minPts:.brk.cfg`alertMinEquityPts;
  minTr:.brk.cfg`alertMinTrades;
  // NB: a select column literally named `value` triggers 'assign (it's a
  // builtin) - so the observed figure is `obsValue`, not `value`.
  // Alerts gate on nPts / nTrades so a 2-sample equity curve or a
  // handful of trades can't raise a spurious breach.
  a1:select signalId, kind:`DRAWDOWN, severity:`HIGH, metric:`maxDDPct,
      obsValue:maxDDPct, threshold:ddLim, message:`$"equity drawdown beyond limit"
    from m where nPts>=minPts, maxDDPct<ddLim;
  a2:select signalId, kind:`CANCEL_RATE, severity:`MEDIUM, metric:`cancelRatePct,
      obsValue:cancelRatePct, threshold:crLim, message:`$"order cancel rate abnormally high"
    from m where nTrades>=minTr, cancelRatePct>crLim;
  a3:select signalId, kind:`CONCENTRATION, severity:`MEDIUM, metric:`top1SymbolPct,
      obsValue:top1SymbolPct, threshold:ccLim, message:`$"single-instrument concentration high"
    from m where nTrades>=minTr, top1SymbolPct>ccLim;
  a4:select signalId, kind:`TOXICITY, severity:`HIGH, metric:`toxScore,
      obsValue:toxScore, threshold:txLim, message:`$"composite toxicity above threshold"
    from m where nTrades>=minTr, toxScore>=txLim;
  `severity`kind xasc raze (a1;a2;a3;a4)};

//--------------------------------------------------------------------
// Per-brokerage rollups (.brk.broker.*)
//--------------------------------------------------------------------
// The retail archive carries no broker/exchange field - it's mql5.com
// Signals data, and mql5 doesn't publish which broker a signal account
// runs on. But a good fraction of providers name their broker right in
// sig.name ("Scalp IC Markets ECN", "R Factor Broker FPMarkets", "EA
// Happy News Eightcap", ...). .brk.broker.tag parses that; everything
// below groups the per-signal analytics by the parsed tag. A provider
// whose name discloses nothing lands in `UNKNOWN - still a bucket, just
// an unnamed one.

// (canonical broker; lowercase like-patterns that map to it). Ordered
// most-specific first; the first canonical with any pattern match wins.
// Names are matched space-padded (" ",lower name," ") so a short token
// like "icm" or "xm" only matches on a word boundary, not mid-word.
.brk.broker.keywords:(
  (`$"IC Markets";  ("*ic markets*";"*icmarkets*";"*ic-markets*";"* icm *";"* icm ";" icm *"));
  (`Pepperstone;    ("*pepperstone*";"*papperstone*"));
  (`FPMarkets;      ("*fpmarkets*";"*fp markets*"));
  (`Eightcap;       (enlist "*eightcap*"));
  (`Exness;         (enlist "*exness*"));
  (`Vantage;        (enlist "*vantage*"));
  (`Tickmill;       (enlist "*tickmill*"));
  (`Darwinex;       (enlist "*darwinex*"));
  (`OANDA;          (enlist "*oanda*"));
  (`RoboForex;      ("*roboforex*";"*robo forex*"));
  (`Alpari;         (enlist "*alpari*"));
  (`FXTM;           (enlist "* fxtm *"));
  (`Fusion;         ("*fusion market*";"* fusion *"));
  (`Blueberry;      (enlist "*blueberry*"));
  (`XM;             ("* xm *";"* xm group*";" xm *")));

//@func  | .brk.broker.tagName
//@param  | nm | symbol | a provider's sig.name
//@desc
// The broker canonical for one name, or `UNKNOWN. See .brk.broker.keywords.
//@desc
.brk.broker.tagName:{[nm]
  s:" ",(lower string nm)," ";
  hits:{[s;e] $[any s like/: e 1; e 0; `]}[s] each .brk.broker.keywords;
  idx:where not null hits;
  $[0=count idx; `UNKNOWN; hits first idx]};

//@func  | .brk.broker.tag
//@param  | sig | table | `sig`-shaped (signalId, name, ...)
//@return | table | signalId, brokerTag
//@desc
// Broker canonical per provider, parsed from sig.name.
//@desc
.brk.broker.tag:{[sig]
  select signalId, brokerTag:.brk.broker.tagName each name from sig};

//@func  | .brk.broker.priv.join
//@desc
// Internal: 0! a per-signal analytics table and left-join the broker tag,
// filling `UNKNOWN where a provider isn't in sig or didn't parse.
//@desc
.brk.broker.priv.join:{[t;sig]
  update brokerTag:`UNKNOWN^brokerTag from (0!t) lj `signalId xkey .brk.broker.tag sig};

//@func  | .brk.broker.roster
//@param  | sig | table
//@desc
// One row per broker tag: provider count, first/last seen across its
// providers, and the list of provider names.
//@desc
.brk.broker.roster:{[sig]
  s:.brk.broker.priv.join[select signalId, name, firstSeen, lastSeen from sig; sig];
  `nProviders xdesc 0!select nProviders:count i, firstSeen:min firstSeen,
      lastSeen:max lastSeen, providers:name
    by brokerTag from s};

//@func  | .brk.broker.pnl
//@param  | trades | table
//@param  | sig    | table
//@desc
// Per broker tag: the broker-side revenue breakdown (client net P&L,
// B-book PnL, commission & swap revenue, total revenue) summed across
// that broker's providers - .brk.rev.bySignal rolled up a level.
//@desc
.brk.broker.pnl:{[trades;sig]
  r:.brk.broker.priv.join[.brk.rev.bySignal trades; sig];
  `totalRev xdesc 0!select nProviders:count i, nTrades:sum nTrades, totalLots:sum totalLots,
      clientNetProfit:sum clientNetProfit, bBookPnl:sum bBookPnl,
      commissionRev:sum commissionRev, swapRev:sum swapRev, totalRev:sum totalRev
    by brokerTag from r};

//@func  | .brk.broker.perf
//@param  | trades | table
//@param  | sig    | table
//@desc
// Per broker tag: pooled win rate / profit factor / expectancy / net
// P&L across all its providers' trades, plus the average per-provider
// hold time and trades/day.
//@desc
.brk.broker.perf:{[trades;sig]
  p:.brk.broker.priv.join[.brk.perf.bySignal trades; sig];
  r:select nProviders:count i, nTrades:sum nTrades,
      grossWin:sum grossWin, grossLoss:sum grossLoss, netProfit:sum netProfit,
      nWin:sum nWin, totalLots:sum totalLots,
      avgProviderHoldMin:avg avgHoldMin, avgProviderTradesPerDay:avg tradesPerDay
    by brokerTag from p;
  r:update winRatePct:100*nWin%nTrades,
      profitFactor:?[grossLoss<0; grossWin%abs grossLoss; 0n],
      expectancy:netProfit%nTrades from r;
  `netProfit xdesc 0!r};

//@func  | .brk.broker.exec
//@param  | trades | table
//@param  | sig    | table
//@desc
// Per broker tag: pooled order count, executed/cancelled, and cancel
// rate % across its providers - the quote-stuffing lens by broker.
//@desc
.brk.broker.exec:{[trades;sig]
  c:.brk.broker.priv.join[.brk.exec.cancelRates trades; sig];
  `cancelRatePct xdesc 0!select nProviders:count i, nOrders:sum nOrders,
      nExecuted:sum nExecuted, nCancelled:sum nCancelled,
      cancelRatePct:100*(sum nCancelled)%sum nOrders
    by brokerTag from c};

//@func  | .brk.broker.risk
//@param  | trades | table
//@param  | equity | table
//@param  | sig    | table
//@desc
// Per broker tag: worst & average provider max-drawdown (over providers
// with >= alertMinEquityPts samples), average time underwater, average &
// max composite toxicity, and how many of its providers score HIGH+ tox.
//@desc
.brk.broker.risk:{[trades;equity;sig]
  dd:.brk.broker.priv.join[.brk.perf.drawdown equity; sig];
  tx:.brk.broker.priv.join[.brk.tox.score[trades;equity]; sig];
  a:select nProvidersWithCurve:count i, worstMaxDDPct:min maxDDPct,
      avgMaxDDPct:avg maxDDPct, avgUnderwaterPct:avg underwaterSamplePct
    by brokerTag from dd where nPts>=.brk.cfg`alertMinEquityPts;
  b:select avgToxScore:avg toxScore, maxToxScore:max toxScore,
      nHighTox:`long$sum toxScore>=.brk.cfg`toxHigh
    by brokerTag from tx;
  0!a lj b};

//@func  | .brk.broker.routing
//@param  | trades | table
//@param  | equity | table
//@param  | sig    | table
//@desc
// Per broker tag: how .brk.book.recommend's routing calls distribute
// (nRouteA/B/SPLIT), the all-B / all-A / recommended revenue for that
// broker's slice, and the uplift of the recommended split over the
// better extreme.
//@desc
.brk.broker.routing:{[trades;equity;sig]
  r:.brk.broker.priv.join[.brk.book.recommend[trades;equity]; sig];
  x:0!select nProviders:count i,
      nRouteA:`long$sum route=`A, nRouteB:`long$sum route=`B,
      nRouteSplit:`long$sum route=`SPLIT,
      allBBookRev:sum bBookTotalRev, allABookRev:sum aBookRev,
      recommendedRev:sum expectedRev
    by brokerTag from r;
  `recommendedRev xdesc update upliftVsBestExtreme:recommendedRev-allBBookRev|allABookRev from x};

//@func  | .brk.broker.summary
//@param  | trades | table
//@param  | equity | table
//@param  | sig    | table
//@desc
// One consolidated scorecard row per broker tag - the headline figures
// from pnl / perf / exec / risk / routing joined together.
//@desc
.brk.broker.summary:{[trades;equity;sig]
  p:.brk.broker.pnl[trades;sig];
  pf:.brk.broker.perf[trades;sig];
  ex:.brk.broker.exec[trades;sig];
  rk:.brk.broker.risk[trades;equity;sig];
  rt:.brk.broker.routing[trades;equity;sig];
  r:`brokerTag xkey select brokerTag, nProviders, nTrades, totalLots,
      clientNetProfit, totalRev from p;
  r:r lj `brokerTag xkey select brokerTag, winRatePct, profitFactor, expectancy from pf;
  r:r lj `brokerTag xkey select brokerTag, cancelRatePct from ex;
  r:r lj `brokerTag xkey select brokerTag, avgMaxDDPct, avgToxScore, nHighTox from rk;
  r:r lj `brokerTag xkey select brokerTag, nRouteA, nRouteB, nRouteSplit, recommendedRev from rt;
  `totalRev xdesc 0!r};

//--------------------------------------------------------------------
// Client clustering (.brk.cluster.*)
//--------------------------------------------------------------------
// Behavioural segmentation of signal providers ("clients") - trade size,
// time-of-day mix, instrument diversity, hold-time/duration, headline
// profitability, and profitability-by-trade-size - via a from-scratch
// k-means over standardised (z-scored) features. Seeding is a deterministic
// farthest-point traversal (no RNG anywhere in this namespace), so the same
// window always produces the same clusters - a rerun-friendly property the
// usual random-init k-means doesn't have, and consistent with every other
// score in this library being a documented formula, not a fitted model.
// Cluster names are derived, not hand-labelled: each centroid's 2 most
// distinctive (highest |z|) features pick a phrase from
// .brk.cluster.priv.phrase.

//@func  | .brk.cluster.features
//@param  | trades | table | raw `trade` rows
//@desc
// Per-signal behavioural feature vector: avgLots/totalLots (size),
// medHoldMin (duration), nSymbols/symbolHHI/top1Symbol (instrument
// diversity, via .brk.expo.signalConcentration), asianPct/londonPct/nyPct/
// dominantSession (time-of-day mix over 3 equal 8h UTC blocks - a relative
// clustering feature, not a literal FX session definition), winRatePct/
// profitFactor/expectancy/netProfit (headline profitability, via
// .brk.perf.bySignal), and sizeProfitBias - this account's own average
// profit on trades above its own median lot size minus its own trades at or
// below it (positive = wins its big trades more; negative = wins its small
// ones more).
//@desc
.brk.cluster.features:{[trades]
  t:.brk.executed trades;
  if[not count t; :([] signalId:`long$(); nTrades:`long$(); winRatePct:`float$();
    profitFactor:`float$(); expectancy:`float$(); netProfit:`float$(); totalLots:`float$();
    avgHoldMin:`float$(); medHoldMin:`float$(); nSymbols:`long$(); top1Symbol:`symbol$();
    top1SymbolPct:`float$(); symbolHHI:`float$(); asianPct:`float$(); londonPct:`float$();
    nyPct:`float$(); dominantSession:`symbol$(); avgLots:`float$(); smallAvgProfit:`float$();
    largeAvgProfit:`float$(); sizeProfitBias:`float$())];
  allIds:([] signalId:exec asc distinct signalId from t);

  perf:.brk.perf.bySignal trades;
  conc:.brk.expo.signalConcentration trades;

  // time-of-day mix: 3 equal 8h UTC blocks (not literal FX session
  // definitions - just enough resolution to separate an Asia-hours book
  // from a US-hours one for clustering purposes).
  ts:update hr:(`time$openTime) div 3600000 from t;
  ts:update session:?[hr<8;`Asian;?[hr<16;`London;`NewYork]] from ts;
  sess:0!select n:count i by signalId,session from ts;
  tot:`signalId xkey select tot:sum n by signalId from sess;
  sess:update pct:100*n%tot from sess lj tot;
  asianP:select signalId,asianPct:pct from sess where session=`Asian;
  londonP:select signalId,londonPct:pct from sess where session=`London;
  nyP:select signalId,nyPct:pct from sess where session=`NewYork;

  // profitability by trade size: split each provider's own trades at its
  // own median lot size, compare average profit above vs at-or-below it.
  sz:update volMed:med volume by signalId from t;
  sz:update sizeBucket:?[volume<=volMed;`small;`large] from sz;
  szAgg:select avgProfit:avg profit by signalId,sizeBucket from sz;
  smallP:select signalId,smallAvgProfit:avgProfit from 0!szAgg where sizeBucket=`small;
  largeP:select signalId,largeAvgProfit:avgProfit from 0!szAgg where sizeBucket=`large;

  // NB: "t lj a lj b lj c" is NOT left-to-right accumulation - q has no
  // operator precedence, so a chain of infix binary calls groups right-to-
  // left ("t lj (a lj (b lj c))"), which is nonsense for lj (the right arg
  // must already be a keyed table). Fold explicitly instead.
  joins:(
    `signalId xkey select signalId,nTrades,winRatePct,profitFactor,expectancy,netProfit,
        totalLots,avgHoldMin,medHoldMin from perf;
    `signalId xkey select signalId,nSymbols,top1Symbol,top1SymbolPct,symbolHHI from conc;
    `signalId xkey asianP;
    `signalId xkey londonP;
    `signalId xkey nyP;
    `signalId xkey smallP;
    `signalId xkey largeP);
  f:{x lj y}/[allIds;joins];
  f:update nTrades:0^nTrades, totalLots:0^totalLots, asianPct:0^asianPct,
      londonPct:0^londonPct, nyPct:0^nyPct, smallAvgProfit:0^smallAvgProfit,
      largeAvgProfit:0^largeAvgProfit from f;
  update avgLots:?[nTrades>0; totalLots%nTrades; 0n],
      sizeProfitBias:largeAvgProfit-smallAvgProfit,
      dominantSession:?[asianPct>=londonPct; ?[asianPct>=nyPct;`Asian;`NewYork]; ?[londonPct>=nyPct;`London;`NewYork]]
    from f};

//@func  | .brk.cluster.priv.zscore
//@param  | x | float list
//@desc
// Standardise a feature column to z-scores; a constant column (dev=0) maps
// to all-zero rather than dividing by zero.
//@desc
.brk.cluster.priv.zscore:{[x] d:dev x; $[d=0; 0f*x; (x-avg x)%d]};

//@func  | .brk.cluster.priv.dist2
//@param  | Fs | list of float lists | m feature columns, each length n
//@param  | c  | float list | one length-m centroid
//@desc
// Squared Euclidean distance from every one of the n rows to centroid c,
// vectorised across all n at once (no per-row loop).
//@desc
.brk.cluster.priv.dist2:{[Fs;c] sum {(x-y)*(x-y)}'[Fs;c]};

//@func  | .brk.cluster.priv.initCentroids
//@param  | Fs | list of float lists
//@param  | k  | long
//@desc
// Deterministic farthest-point-first seeding: the first centroid is the
// point farthest from the global mean, then each next one is whichever
// remaining point is farthest from its nearest already-chosen centroid. No
// randomness anywhere - the same Fs always seeds (and therefore clusters)
// the same way.
//@desc
.brk.cluster.priv.initCentroids:{[Fs;k]
  mean0:avg each Fs;
  d0:.brk.cluster.priv.dist2[Fs;mean0];
  idxs:enlist d0?max d0;
  i:1;
  while[i<k;
    cs:{x@\:y}[Fs] each idxs;
    Dall:.brk.cluster.priv.dist2[Fs] each cs;
    minD:min each flip Dall;
    minD:@[minD;idxs;:;-1f];
    idxs,:minD?max minD;
    i+:1];
  {x@\:y}[Fs] each idxs};

//@func  | .brk.cluster.priv.kmeans
//@param  | Fs    | list of float lists
//@param  | k     | long | clamped here to [1; count first Fs]
//@param  | iters | long
//@desc
// Lloyd's algorithm from the deterministic seed above, run for a fixed
// iteration count (small k / small n here always converges well inside 25
// passes). An empty cluster keeps its previous centroid rather than
// producing a null. Returns a dict of the final centroids and the length-n
// cluster assignment (0-based, parallel to Fs's rows).
//@desc
.brk.cluster.priv.kmeans:{[Fs;k;iters]
  n:count first Fs;
  k:1|k&n;
  C:.brk.cluster.priv.initCentroids[Fs;k];
  i:0;
  while[i<iters;
    D:.brk.cluster.priv.dist2[Fs] each C;
    assign:{x?min x} each flip D;
    C:{[Fs;assign;old;ci] sel:where assign=ci; $[0=count sel; old ci; avg each Fs@\:sel]}[Fs;assign;C] each til k;
    i+:1];
  D:.brk.cluster.priv.dist2[Fs] each C;
  assign:{x?min x} each flip D;
  `centroids`assign!(C;assign)};

// (feature; sign of z; short descriptive phrase) - .brk.cluster.priv.label
// picks a cluster's 2 most distinctive features and looks each one up here.
.brk.cluster.priv.phrase:([]
  feat:`avgLots`avgLots`medHoldMin`medHoldMin`symbolHHI`symbolHHI`asianPct`londonPct`nyPct`profitFactor`profitFactor`sizeProfitBias`sizeProfitBias;
  sign:1 -1 1 -1 1 -1 1 1 1 1 -1 1 -1;
  phrase:("large size";"small size";"swing/position";"scalper";"single-instrument";"diversified";
    "Asian-session";"London-session";"NY-session";"high profit-factor";"low profit-factor";
    "wins big trades";"wins small trades"));

//@func  | .brk.cluster.priv.label
//@param  | featCols | symbol list | feature columns, in the same order as z
//@param  | z        | float list  | one centroid's standardised feature vector
//@desc
// Human-readable tag from a centroid's 2 most distinctive (highest |z|)
// features, e.g. "large size, scalper". Falls back to "mixed profile" if
// neither top feature has a phrase for that sign (z near 0 either way).
//@desc
.brk.cluster.priv.label:{[featCols;z]
  top:2 sublist idesc abs z;
  phr:{[featCols;z;i]
    f:featCols i; s:`long$signum z i;
    r:exec phrase from .brk.cluster.priv.phrase where feat=f, sign=s;
    $[count r; first r; ""]
  }[featCols;z] each top;
  // phr's items are variable-length char vectors ("" vs "large size") - <>
  // needs matching lengths, so filter on count instead of comparing to "".
  phr:phr where 0<count each phr;
  $[count phr; ", " sv phr; "mixed profile"]};

//@func  | .brk.cluster.run
//@param  | trades    | table
//@param  | k         | long | requested cluster count (UI should restrict to roughly [2;12]; this clamps to [1; nClients])
//@param  | minTrades | long | drop low-activity providers before clustering (noise)
//@desc
// Deterministic k-means client segmentation. Builds .brk.cluster.features,
// z-scores 8 of them (size, duration, symbol concentration, 3-way session
// mix, profit factor, size-profit bias), clusters, then labels each cluster
// from its centroid. Returns `clients` (one row per provider: every raw
// feature + clusterId + label) and `clusters` (one row per cluster: mean
// raw features, provider count, summed net profit/lots, label).
//@desc
.brk.cluster.run:{[trades;k;minTrades]
  f:.brk.cluster.features trades;
  f:select from f where nTrades>=minTrades;
  if[0=count f; :(`clients`clusters)!(f;([] clusterId:`long$(); label:`$()))];

  featCols:`avgLots`medHoldMin`symbolHHI`asianPct`londonPct`nyPct`profitFactor`sizeProfitBias;
  // fill nulls (e.g. profitFactor is 0n for a provider with zero losing
  // trades, medHoldMin/symbolHHI can be 0n for a degenerate few-trade
  // account) before z-scoring - kdb+ float arithmetic propagates nulls, so
  // one null cell would otherwise null out an entire standardised column.
  f:update avgLots:0f^avgLots, medHoldMin:0f^medHoldMin, symbolHHI:0f^symbolHHI,
      asianPct:0f^asianPct, londonPct:0f^londonPct, nyPct:0f^nyPct,
      profitFactor:.brk.clamp[10f^profitFactor;0f;10f], sizeProfitBias:0f^sizeProfitBias
    from f;
  raw:value flip featCols#f;
  Fs:.brk.cluster.priv.zscore each raw;

  k:1|k&count f;
  res:.brk.cluster.priv.kmeans[Fs;k;25];
  labels:.brk.cluster.priv.label[featCols] each res`centroids;

  clients:update clusterId:res`assign from f;
  clients:update label:labels clusterId from clients;

  clusterSummary:0!select nProviders:count i, avgLots:avg avgLots, medHoldMin:avg medHoldMin,
      nSymbols:avg nSymbols, symbolHHI:avg symbolHHI, asianPct:avg asianPct, londonPct:avg londonPct,
      nyPct:avg nyPct, profitFactor:avg profitFactor, sizeProfitBias:avg sizeProfitBias,
      winRatePct:avg winRatePct, netProfit:sum netProfit, totalLots:sum totalLots
    by clusterId from clients;
  clusterSummary:`nProviders xdesc update label:labels clusterId from clusterSummary;
  (`clients`clusters)!(clients;clusterSummary)};

.brk.info.loaded:1b;
