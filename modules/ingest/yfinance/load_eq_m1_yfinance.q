// load_eq_m1_yfinance.q
// Ingest a staging CSV of 1-minute equity bars and write/overwrite date
// partitions of the eq_m1_yfinance table in a kdb+ date-partitioned HDB.
//
// Usage:
//   q load_eq_m1_yfinance.q -stage <csv> -db <hdbRoot> [-table <name>]
//     -table  target table name (default eq_m1_yfinance; every venue shares
//             it, told apart by the exchange column)
//
// Staging CSV (header required, comma delimited):
//   barTime,sym,open,high,low,close,volume,exchange
//     barTime   YYYY-MM-DDTHH:MM:SS  UTC, tz stripped -> `timestamp (matches
//               `.z.d`/`.z.p` and every other date/time decision in this
//               repo - see m1_common.normalise_bars)
//     sym       Yahoo ticker e.g. 0700.HK   -> `p# parted, sorted with barTime
//     open..close                            -> float
//     volume                                 -> long
//     exchange  e.g. hkex                    -> symbol
//
// On disk (per schemas/schema_eq_m1_yfinance.q): timestamp,sym,barTime,open,
// high,low,close,volume,exchange ; partitioned by `date$barTime ; `p# on sym.
// In this batch path `timestamp is set equal to `barTime (no tickerplant).
//
// Per date, a partition is REWRITTEN, but only the rows whose `exchange is in
// the staging file are replaced - rows from other venues already in that
// partition are read back and kept. So loading nikkei after hkex extends the
// same table, and re-running one venue for a day is still idempotent for it.

args:.Q.opt .z.x;
if[not all `stage`db in key args;
  -2 "usage: q load_eq_m1_yfinance.q -stage <csv> -db <hdbRoot>"; exit 1];

stageFile:hsym `$first args`stage;
root:hsym `$first args`db;
tbl:`$$[`table in key args; first args`table; "eq_m1_yfinance"];
if[()~key stageFile; -2 "stage file not found: ",1_ string stageFile; exit 1];

-1 (string .z.p)," reading ",1_ string stageFile;
raw:("PSFFFFJS"; enlist ",") 0: stageFile;

if[count select from raw where null exchange;
  -2 "staging file has rows with an empty exchange"; exit 1];

raw:select from raw where not null barTime, not null close;
if[0=count raw; -2 "nothing to load after filtering"; exit 1];
raw:update timestamp:barTime, date:`date$barTime from raw;

colOrder:`timestamp`sym`barTime`open`high`low`close`volume`exchange;

writeCols:{[dir;t]
  {[dir;t;c] .Q.dd[dir;c] set t c}[dir;t] each cols t;
  (`$(string dir),"/.d") set cols t; };

writePartition:{[root;tbl;dt;t]
  t:colOrder xcols .Q.en[root;] delete date from t;
  dir:.Q.dd[root;] (`$string dt;tbl);
  // preserve rows from other venues already written to this partition
  ex:distinct t`exchange;
  old:$[()~key dir; 0#t;
    {[d;e0] o:@[get;`$(string d),"/";e0]; $[98h=type o; colOrder xcols o; e0]}[dir;0#t]];
  old:?[old; enlist (not; (in; `exchange; enlist ex)); 0b; ()];
  t:`sym`barTime xasc old,t;
  writeCols[dir;t];
  .Q.dd[dir;`sym] set `p# get .Q.dd[dir;`sym];
  count t };

byDate:group exec date from raw;
{[root;tbl;raw;dt;ix]
  n:writePartition[root;tbl;dt] raw ix;
  -1 "  ",(string dt),"  ",(string n)," rows";
 }[root;tbl;raw]'[key byDate; value byDate];

// This root also holds other equity tables spanning different date ranges
// (daily eq_d1_yfinance, and any sibling eq_m1_yfinance* tables); .Q.chk stubs
// an empty copy of each into every partition it is missing from, so no table
// 'paths on an out-of-range date.
-1 (string .z.p)," .Q.chk ",1_ string root;
.Q.chk root;

-1 (string .z.p)," done: ",(string count byDate)," partition(s), ",
   (string count raw)," rows -> ",1_ string root;
exit 0
