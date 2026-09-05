// load_yfinance.q
// Ingest a staging CSV of Yahoo-Finance bars and write/overwrite date
// partitions of ONE table in a kdb+ date-partitioned HDB.
//
// SCHEMA-DRIVEN: the on-disk column order AND the CSV parse-type string
// are both derived from -table's definition in -schema
// (schemas/schema_yfinance.q) via `meta` - there is no hard-coded column
// list here. The same loader therefore handles every yfinance bar table:
//   * minute tables (have a `timestamp column; on disk
//     timestamp,sym,barTime,open,high,low,close,volume,exchange):
//     eq_m1_yfinance / futures_m1_yfinance / rateIndices_m1_yfinance
//   * daily tables (NO `timestamp - the partition dir IS the day; on disk
//     sym,open,high,low,close,volume,exchange):
//     eq_d1_yfinance / futures_d1_yfinance / rateIndices_d1_yfinance
// Replaces load_eq_m1_yfinance.q + load_d1_yfinance.q.
//
// Usage:
//   q load_yfinance.q -stage <csv> -db <hdbRoot> -table <name> -schema <schema.q> [-partkey exchange]
//
// Staging CSV (header row required, comma delimited). Column 1 is the
// partition source, decided by whether -table has a `timestamp column:
//   HAS `timestamp -> col 1 is `barTime, ISO YYYY-MM-DDTHH:MM:SS (UTC, tz
//     stripped). `timestamp := `barTime and `date := `date$barTime are
//     derived here (batch path, no tickerplant).
//   NO  `timestamp -> col 1 is `date, YYYY-MM-DD, and is the partition
//     itself (dropped from the on-disk table).
//   cols 2.. : sym, then -table's value columns in schema order, then the
//   -partkey column (default `exchange).
// The parse-type string (e.g. "PSFFFFJS" / "DSFFFFJS") is built from the
// upper-cased `meta -table` type chars, "D" prepended for the daily case.
//
// Per date the partition is REWRITTEN, but only rows whose -partkey value
// appears in the staging file are replaced - rows carrying another -partkey
// value already in that partition are read back and kept (so loading
// nikkei after hkex extends the same table, and re-running one value stays
// idempotent for it). Ends with .Q.chk so this table and its longer/
// shorter-dated siblings under the same root don't 'path on out-of-range
// dates.

args:.Q.opt .z.x;
if[not all `stage`db`table`schema in key args;
  -2 "usage: q load_yfinance.q -stage <csv> -db <hdbRoot> -table <name> -schema <schema.q> [-partkey exchange]";
  exit 1];

stageFile:hsym `$first args`stage;
root:hsym `$first args`db;
tbl:`$first args`table;
schemaPath:first args`schema;
partkey:`$$[`partkey in key args; first args`partkey; "exchange"];
if[()~key stageFile; -2 "stage file not found: ",1_ string stageFile; exit 1];
if[()~key hsym `$schemaPath; -2 "schema file not found: ",schemaPath; exit 1];

system "l ",schemaPath;
if[not tbl in tables `.; -2 (string tbl)," is not a table defined by ",schemaPath; exit 1];

// ---- derive CSV layout + parse types from the schema ------------------
onDisk:cols tbl;                       // on-disk column order
mt:exec c!t from meta tbl;             // column -> kdb type char
hasTs:`timestamp in onDisk;

tcol:$[hasTs; first onDisk where (onDisk<>`timestamp) & "p"=mt onDisk; `date];
if[hasTs and null tcol;
  -2 (string tbl)," has `timestamp but no second timestamp column to carry barTime"; exit 1];

csvCols:$[hasTs;
  enlist[tcol],onDisk except (`timestamp;tcol);   // barTime,sym,<vals>,<partkey>
  enlist[`date],onDisk];                          // date,sym,<vals>,<partkey>
parseStr:upper $[hasTs; mt csvCols; "d",mt 1_ csvCols];

if[not partkey in csvCols;
  -2 "-partkey ",(string partkey)," is not a column of ",string tbl; exit 1];

-1 (string .z.p)," reading ",(1_ string stageFile),"  -> ",(string tbl),
   " (",("," sv string csvCols),"  ",parseStr,")";
raw:csvCols xcol (parseStr; enlist ",") 0: stageFile;

if[count select from raw where null raw partkey;
  -2 "staging file has rows with an empty ",string partkey; exit 1];
raw:?[raw; enlist (not;(null; first csvCols)); 0b; ()];
if[`close in csvCols; raw:?[raw; enlist (not;(null;`close)); 0b; ()]];
if[0=count raw; -2 "nothing to load after filtering"; exit 1];

raw:$[hasTs;
  ![raw; (); 0b; `date`timestamp!((`date$;tcol);(::;tcol))];
  ![raw; (); 0b; (enlist `date)!enlist (`date$;`date)]];

// ---- writedown ------------------------------------------------------
colOrder:onDisk;
sortKey:$[hasTs; `sym,tcol; enlist `sym];

writeCols:{[dir;t]
  {[dir;t;c] .Q.dd[dir;c] set t c}[dir;t] each cols t;
  (`$(string dir),"/.d") set cols t; };

writePartition:{[root;tbl;colOrder;sortKey;partkey;dt;t]
  t:colOrder xcols .Q.en[root;] delete date from t;
  dir:.Q.dd[root;] (`$string dt;tbl);
  // preserve rows carrying a different -partkey value already in this partition
  ex:distinct t partkey;
  old:$[()~key dir; 0#t;
    {[d;e0] o:@[get;`$(string d),"/";e0]; $[98h=type o; colOrder xcols o; e0]}[dir;0#t]];
  old:?[old; enlist (not; (in; partkey; enlist ex)); 0b; ()];
  t:sortKey xasc old,t;
  writeCols[dir;t];
  .Q.dd[dir;`sym] set `p# get .Q.dd[dir;`sym];
  count t };

byDate:group exec date from raw;
{[root;tbl;colOrder;sortKey;partkey;raw;dt;ix]
  n:writePartition[root;tbl;colOrder;sortKey;partkey;dt] raw ix;
  -1 "  ",(string dt),"  ",(string n)," rows";
 }[root;tbl;colOrder;sortKey;partkey;raw]'[key byDate; value byDate];

-1 (string .z.p)," .Q.chk ",1_ string root;
.Q.chk root;

-1 (string .z.p)," done: ",(string count byDate)," partition(s), ",
   (string count raw)," rows -> ",1_ string root;
exit 0
