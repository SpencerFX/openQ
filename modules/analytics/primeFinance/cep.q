//====================================================================
// Directory: modules/analytics/primeFinance/cep.q
//====================================================================
// openQ's core TP/RDB/IDB/HDB remain unchanged. The CEP loads the
// domain library (its own sibling file, primeFinance.q), handles
// incoming prime-finance events, and relays every source row unchanged
// to downstream subscribers.
//====================================================================

system "l ../modules/analytics/primeFinance/primeFinance.q";

.primeMod.onInventory:{[t;x]
  {[row] .prime.inventory,:row} each 0!x;
  };

.primeMod.onLocate:{[t;x]
  {[row] .prime.locates,:row} each 0!x;
  };

.primeMod.onPosition:{[t;x]
  {[row] .prime.positions,:row} each 0!x;
  };

.primeMod.onBorrow:{[t;x]
  {[row] .prime.borrows,:row} each 0!x;
  };

.primeMod.onRecall:{[t;x]
  {[row]
    .prime.applyRecall[
      row[`lender];row[`sym];row[`qty];row[`severity];row[`due]]
  } each 0!x;
  };

.primeMod.relay:{[t;x].u.upd[t;x]};

.oq.cep.addHandler[`inventory;.primeMod.onInventory;`primeOnInventory];
.oq.cep.addHandler[`locate;.primeMod.onLocate;`primeOnLocate];
.oq.cep.addHandler[`position;.primeMod.onPosition;`primeOnPosition];
.oq.cep.addHandler[`borrow;.primeMod.onBorrow;`primeOnBorrow];
.oq.cep.addHandler[`recall;.primeMod.onRecall;`primeOnRecall];

{.oq.cep.addHandler[x;.primeMod.relay;`$"primeRelay",string x]}
  each .oq.schema.tables[];

.primeMod.sweepFreq:0D00:01:00;
.primeMod.sweep:{[] .prime.sweep .z.p};
.primeMod.info.timer.sweep:
  .util.timer.add[
    .z.p+.primeMod.sweepFreq;
    0Wp;
    .primeMod.sweepFreq;
    `.primeMod.sweep;
    `REL;
    "prime finance sweep"];

//---------------------------------------------------------------
// Real market data: periodically pulls realized-vol/ADV/latest-close stats
// from TWO real tables on the eq_hdb process (-eqhdbaddr, default
// :localhost:5090, which serves both) - eq_d1_yfinance (US daily bars) for
// the book's US names, and eq_m1_yfinance (HKEX/Nikkei 1-minute bars) for
// its HK/JP names, aggregated into daily bars first so both regions feed
// the SAME vol/ADV methodology (annualized realized vol from daily log
// returns, ADV from daily volume) - then unions the two into one `market`
// table (sym,close,adv,vol,ccy) feeding all three consumers in
// primeFinance.q (its own sibling file): .prime.calib.build (borrow-fee
// calibration), .prime.risk.build (position mark-to-market), and
// .prime.crowd.build (short-interest concentration).
//
// `ccy` (USD/HKD/JPY, from .primeMod.market.ccyMap keyed off eq_m1_yfinance's
// own `exchange column) matters because this repo has no real FX-rate feed:
// HKD/JPY prices are real and left in their own currency, NEVER converted
// to USD, so a $ SUM across rows with different ccy would silently blend
// currencies into a meaningless number - every consumer must either filter
// to one ccy before summing, or keep sums broken out per ccy. feeBp-based
// figures (calibration) are the one exception: a rate in basis points
// compares validly across currencies without conversion.
//
// Deliberately plain functional-query sends to a generic, unmodified
// eq_hdb - see schemas/schema_eq.q's own header on that HDB staying
// read-only/untouched - rather than loading any custom code there, so the
// vol/ADV/close logic travels to the data over IPC the same way idb.q's
// harvest queries an rdb.
//---------------------------------------------------------------
.primeMod.market.hdbAddr:`$.util.start.CLP[`eqhdbaddr][`val];
.primeMod.market.h:0Ni;
.primeMod.market.lookbackDays:30;
.primeMod.market.freq:0D00:05:00;

// The book's cross-border names - real, liquid, backfilled tickers
// confirmed present in eq_m1_yfinance (Tencent, Alibaba-HK, Toyota, Sony).
// Restricting the intraday query to exactly these (rather than scanning
// eq_m1_yfinance's whole multi-thousand-symbol universe) keeps a 1-minute-
// granularity query cheap - unlike eq_d1_yfinance's daily bars, there's no
// reason to aggregate vol/ADV for HK/JP names this book has no exposure to.
.primeMod.market.intlSyms:`0700.HK`9988.HK`7203.T`6758.T;
.primeMod.market.ccyMap:`hkex`nikkei`nyse`nasdaq!`HKD`JPY`USD`USD;

//@func  | .primeMod.market.query
//@param  | lookbackDays | int
//@return | 10 | q source, to run ON eq_hdb, computing per-sym realized vol
//                (annualized %, from daily log returns), ADV, and latest
//                close over the most recent lookbackDays actually present
//                in eq_d1_yfinance (i.e. trading days, not calendar days)
//@desc
//A symbol with fewer than 2 trading days in the window gets a null vol
//(1_deltas of a <2-element list is empty; var of that is meaningless) -
//.prime.calib.percentileOf treats a null as neutral, .prime.risk.build
//treats a missing/null close as an honest "no mark", not a fabricated one.
//NOTE: `maxDate:first exec ... from select maxDate:max date from t`, not a
//direct `exec max date from t` - `date` on a date-partitioned table is a
//VIRTUAL column (there's no on-disk date field; the partition directory
//name IS the date, see schema_eq.q's own header), and `exec` of that
//virtual column alone (with no other real column involved) hits a genuine
//kdb+ engine limitation ('nyi, "not yet implemented") that a `select` of
//the same column does not - confirmed directly against the real eq_hdb
//before writing this the other way and hitting exactly that error.
//@desc
.primeMod.market.query:{[lookbackDays]
  lb:string lookbackDays;
  "maxDate:first exec maxDate from select maxDate:max date from eq_d1_yfinance;",
  "t:`sym`date xasc select date,sym,close,volume from eq_d1_yfinance where date within (maxDate-",lb,";maxDate), not null close;",
  "byS:select close,volume by sym from t;",
  "select sym,close:{last x} each close,adv:avg each volume,vol:{$[2>count x;0n;100*sqrt 252*var 1_deltas log x]} each close from byS"
  };

//@func  | .primeMod.market.intlQuery
//@param  | lookbackDays | int
//@return | 10 | q source, to run ON eq_hdb, computing the SAME real vol/
//                ADV/latest-close stats as .primeMod.market.query but from
//                eq_m1_yfinance's 1-minute HKEX/Nikkei bars, restricted to
//                .primeMod.market.intlSyms, and returning `exchange
//                (hkex/nikkei) alongside so .primeMod.market.refresh can
//                map it to a real currency
//@desc
//eq_m1_yfinance is intraday (1-minute bars, ~30 days of history total per
//its own README), so this aggregates to ONE bar per (sym,date) first -
//the day's last price and total volume - before computing vol/ADV
//identically to the daily US calc, so both regions are on the same
//methodology and genuinely comparable, not two different vol definitions
//wearing the same column name. Same virtual-partition-column `exec` 'nyi
//note as .primeMod.market.query applies here too (eq_m1_yfinance is also
//date-partitioned - see schemas/schema_eq_m1_yfinance.q's header).
//@desc
.primeMod.market.intlQuery:{[lookbackDays]
  lb:string lookbackDays;
  symLit:"`",("`" sv string .primeMod.market.intlSyms);
  "syms:",symLit,";",
  "maxDate:first exec maxDate from select maxDate:max date from eq_m1_yfinance where sym in syms;",
  "d:select date,sym,close,volume,exchange from eq_m1_yfinance where date within (maxDate-",lb,";maxDate), sym in syms, not null close;",
  "exch:select exchange:first exchange by sym from d;",
  "daily:`sym`date xasc select volume:sum volume, close:last close by sym,date from d;",
  "byS:select close,volume by sym from daily;",
  "r:select sym,close:{last x} each close,adv:avg each volume,vol:{$[2>count x;0n;100*sqrt 252*var 1_deltas log x]} each close from byS;",
  "r lj `sym xkey exch"
  };

//@func  | .primeMod.market.connect
//@desc
//Reuses .primeMod.market.h if it's still a genuinely live handle (checked
//against key .z.W, not just non-null - see this session's own rdb/tp
//handle-liveness lesson), else reopens via .util.ipc.hopen.
//@desc
.primeMod.market.connect:{[]
  if[(not null .primeMod.market.h) and .primeMod.market.h in key .z.W;:(::)];
  .primeMod.market.h:@[.util.ipc.hopen;.primeMod.market.hdbAddr;
    {[a;e].util.log.ex[`WARN;`.primeMod.market.connect]"Could not connect to eq HDB ",(string a)," for real market data: ",e;0Ni}[.primeMod.market.hdbAddr]];
  };

//@func  | .primeMod.market.refresh
//@desc
//Timer callback: pulls real vol/ADV/close from eq_hdb once, then rebuilds
//.prime.calibration (against current .prime.inventory), .prime.positionRisk,
//and .prime.crowding (both against current .prime.positions) from it. Fully
//protected - an unreachable eq_hdb (or an empty/failed query) just leaves
//all three tables in place and logs a WARN, same "stale beats absent"
//posture as the rest of this module's IO.
//@desc
.primeMod.market.refresh:{[]
  .primeMod.market.connect[];
  if[null .primeMod.market.h;:(::)];
  usCols:`sym`close`adv`vol`ccy;
  us:@[.primeMod.market.h;.primeMod.market.query[.primeMod.market.lookbackDays];
    {[e].util.log.ex[`WARN;`.primeMod.market.refresh]"US market-data query failed: ",e;
     0#([] sym:`symbol$();close:`float$();adv:`float$();vol:`float$())}];
  us:usCols xcols update ccy:`USD from us;
  intl:@[.primeMod.market.h;.primeMod.market.intlQuery[.primeMod.market.lookbackDays];
    {[e].util.log.ex[`WARN;`.primeMod.market.refresh]"Intl (HKEX/Nikkei) market-data query failed: ",e;
     0#([] sym:`symbol$();close:`float$();adv:`float$();vol:`float$();exchange:`symbol$())}];
  // table concatenation (,) requires identical column ORDER on both sides
  // (a mismatched order signals 'rank) AND the identical column SET ('mismatch
  // otherwise) - `xcols` only reorders the columns it's given to the front,
  // it does NOT drop ones left unlisted (exchange stays trailing unless
  // explicitly deleted) - both confirmed directly before writing this
  intl:usCols xcols delete exchange from update ccy:.primeMod.market.ccyMap exchange from intl;
  market:us,intl;
  if[not count market;.util.log.ex[`WARN;`.primeMod.market.refresh]"No market stats returned - leaving .prime.calibration/.prime.positionRisk/.prime.crowding unchanged";:(::)];
  `.prime.calibration set .prime.calib.build[.prime.inventory;market];
  `.prime.positionRisk set .prime.risk.build[.prime.positions;market];
  `.prime.crowding set .prime.crowd.build[.prime.positions;market];
  .util.log.ex[`INFO;`.primeMod.market.refresh]"Refreshed from real market data (",(string count us)," US + ",(string count intl)," intl symbol(s)): ",
    (string count .prime.calibration)," calibration row(s), ",(string count .prime.positionRisk)," position-risk row(s), ",
    (string count .prime.crowding)," crowding row(s)";
  };

.primeMod.market.refresh[]; / populate on boot rather than waiting for the first timer tick
.primeMod.info.timer.market:
  .util.timer.add[
    .z.p+.primeMod.market.freq;
    0Wp;
    .primeMod.market.freq;
    `.primeMod.market.refresh;
    `REL;
    "prime finance real market-data refresh (calibration + position risk)"];
