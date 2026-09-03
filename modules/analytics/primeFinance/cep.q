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

// Lender/counterparty reference data - see primeFinance.q's .prime.lenders/
// .prime.expo.build. Real reference data, seeded here (not market-derived),
// matching simulator.q's lender names so the demo has real exposure data.
`.prime.lenders upsert
  flip `lender`creditRating`creditLimit`marginFactor!
  (`PB`BANKA`BANKB`BANKC;
   `AAA`AA`A`BBB;
   500000000 250000000 150000000 75000000f;
   0.02 0.03 0.04 0.06);

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

// Real market data: pulls vol/ADV/close from eq_hdb (-eqhdbaddr, default
// :localhost:5090) - eq_d1_yfinance for US names, eq_m1_yfinance
// (HKEX/Nikkei) for HK/JP, aggregated to the same daily methodology and
// unioned into one `market` table feeding calib/risk/crowd/expo.build in
// primeFinance.q. ccy tags HKD/JPY/USD - never converted (no real FX
// feed), so $ sums must stay per-ccy; feeBp compares fine across ccy.
.primeMod.market.hdbAddr:`$.util.start.CLP[`eqhdbaddr][`val];
.primeMod.market.h:0Ni;
.primeMod.market.lookbackDays:30;
.primeMod.market.freq:0D00:05:00;

// The book's cross-border names - real tickers confirmed in eq_m1_yfinance.
.primeMod.market.intlSyms:`0700.HK`9988.HK`7203.T`6758.T;
.primeMod.market.ccyMap:`hkex`nikkei`nyse`nasdaq!`HKD`JPY`USD`USD;

//@func  | .primeMod.market.query
//@param  | lookbackDays | int
//@desc
// q source to run ON eq_hdb: per-sym realized vol/ADV/latest close over
// the most recent lookbackDays. `exec max date` alone hits a real 'nyi on
// a date-partitioned table's virtual date column - wrapped in a select instead.
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
//@desc
// Same as .primeMod.market.query but from eq_m1_yfinance's 1-minute
// HKEX/Nikkei bars (restricted to intlSyms), aggregated to one bar per
// (sym,date) first so both regions share one vol/ADV methodology.
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
// Reuses .primeMod.market.h if genuinely live (key .z.W check, not just
// non-null), else reopens.
//@desc
.primeMod.market.connect:{[]
  if[(not null .primeMod.market.h) and .primeMod.market.h in key .z.W;:(::)];
  .primeMod.market.h:@[.util.ipc.hopen;.primeMod.market.hdbAddr;
    {[a;e].util.log.ex[`WARN;`.primeMod.market.connect]"Could not connect to eq HDB ",(string a)," for real market data: ",e;0Ni}[.primeMod.market.hdbAddr]];
  };

//@func  | .primeMod.market.refresh
//@desc
// Timer callback: pulls real vol/ADV/close, rebuilds calibration/
// positionRisk/crowding/exposure from it. Fully protected - an
// unreachable eq_hdb just leaves everything in place and logs a WARN.
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
  // xcols reorders but doesn't drop unlisted columns (exchange stays
  // trailing unless deleted) - table concat needs identical column order+set
  intl:usCols xcols delete exchange from update ccy:.primeMod.market.ccyMap exchange from intl;
  market:us,intl;
  if[not count market;.util.log.ex[`WARN;`.primeMod.market.refresh]"No market stats returned - leaving .prime.calibration/.prime.positionRisk/.prime.crowding unchanged";:(::)];
  `.prime.calibration set .prime.calib.build[.prime.inventory;market];
  `.prime.positionRisk set .prime.risk.build[.prime.positions;market];
  `.prime.crowding set .prime.crowd.build[.prime.positions;market];
  `.prime.exposure set .prime.expo.build[.prime.borrows;.prime.lenders;market;.z.p];
  .util.log.ex[`INFO;`.primeMod.market.refresh]"Refreshed from real market data (",(string count us)," US + ",(string count intl)," intl symbol(s)): ",
    (string count .prime.calibration)," calibration row(s), ",(string count .prime.positionRisk)," position-risk row(s), ",
    (string count .prime.crowding)," crowding row(s), ",(string count .prime.exposure)," exposure row(s)";
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
