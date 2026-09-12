// modules/ingest/calendar/q/load_calendar.q
//
// Ingest a pipe-delimited staging CSV of fxStreet economic-calendar rows
// (written by ../py/to_kdb.py) and write/overwrite date partitions of the
// `econCal` table in a kdb+ date-partitioned HDB (default C:/data/calendar).
//
// SCHEMA-DRIVEN, same convention as modules/ingest/yfinance/q/
// load_yfinance.q: the on-disk column order and the CSV parse-type string
// are both derived from -table's definition in -schema
// (schemas/schema_calendar.q) via `meta` - there is no hard-coded column
// list here, so a schema change (a new column) needs no change here.
//
// Staging CSV (header row required, `|`-delimited - fxStreet event text
// carries embedded commas and, rarely, embedded double quotes, so `|`
// sidesteps CSV quoting entirely rather than needing a quote-aware
// reader; the source data never contains a literal `|`, verified against
// the full archive when this loader was built):
//   date|time|country|currency|category|event|importance|actual|
//   consensus|previous|revised|unit|potency|allDay|tentative|
//   preliminary|report|speech|eventId
// Column 1 is `date` (YYYY-MM-DD), the partition key - dropped from the
// on-disk table, same as -table's own schema stub (schema_calendar.q's
// `econCal` has no `date column - it's virtual, supplied by the
// partitioned-DB directory name). Columns 2.. are -table's value columns
// in schema order.
//
// Unlike load_yfinance.q's per-partkey merge/preserve (several exchanges
// sharing one table), fxStreet's per-month scrape is authoritative for
// every date in that month - there's exactly one source file per date -
// so every date partition present in the staging file is REWRITTEN
// WHOLESALE from that file. That makes re-running the same or a
// refreshed month's file idempotent with no extra bookkeeping. Ends with
// .Q.chk so this table doesn't 'path on out-of-range dates.
//
// Usage:
//   q load_calendar.q -stage <csv> -db <hdbRoot> -schema <schema.q> [-table econCal]

args:.Q.opt .z.x;
if[not all `stage`db`schema in key args;
  -2 "usage: q load_calendar.q -stage <csv> -db <hdbRoot> -schema <schema.q> [-table econCal]";
  exit 1];

stageFile:hsym `$first args`stage;
root:hsym `$first args`db;
tbl:`$$[`table in key args; first args`table; "econCal"];
schemaPath:first args`schema;
if[()~key stageFile; -2 "stage file not found: ",1_ string stageFile; exit 1];
if[()~key hsym `$schemaPath; -2 "schema file not found: ",schemaPath; exit 1];

system "l ",schemaPath;
if[not tbl in tables `.; -2 (string tbl)," is not a table defined by ",schemaPath; exit 1];

// ---- derive CSV layout + parse types from the schema ------------------
onDisk:cols tbl;                       // on-disk column order (no `date - virtual)
mt:exec c!t from meta tbl;             // column -> kdb type char
csvCols:enlist[`date],onDisk;          // date,time,country,...,eventId
parseStr:upper "d",mt onDisk;

-1 (string .z.p)," reading ",(1_ string stageFile),"  -> ",(string tbl),
   " (",("," sv string csvCols),"  ",parseStr,")";
raw:csvCols xcol (parseStr; enlist "|") 0: stageFile;

// the header row's `date` field fails "D"$ -> null; drop it, the same
// idiom load_yfinance.q uses for its own partition-key column.
raw:?[raw; enlist (not;(null; `date)); 0b; ()];
if[0=count raw; -2 "nothing to load after filtering"; exit 1];

// ---- writedown ------------------------------------------------------
colOrder:onDisk;
sortKey:enlist `time;

writeCols:{[dir;t]
  {[dir;t;c] .Q.dd[dir;c] set t c}[dir;t] each cols t;
  (`$(string dir),"/.d") set cols t; };

writePartition:{[root;tbl;colOrder;sortKey;dt;t]
  t:colOrder xcols .Q.en[root;] delete date from t;
  dir:.Q.dd[root;] (`$string dt;tbl);
  t:sortKey xasc t;
  writeCols[dir;t];
  count t };

byDate:group exec date from raw;
nDates:count byDate;
i:0;                                   // top-level global - visible to the
                                        // lambda below with no param needed
{[dt;ix]
  n:writePartition[root;tbl;colOrder;sortKey;dt] raw ix;
  i+:1;
  if[(0=i mod 250) or i=nDates;
    -1 "  ",(string i),"/",(string nDates)," partitions  (",(string dt),": ",(string n)," rows)"];
 }'[key byDate;value byDate];

-1 (string .z.p)," .Q.chk ",1_ string root;
.Q.chk root;

-1 (string .z.p)," done: ",(string nDates)," partition(s), ",
   (string count raw)," rows -> ",1_ string root;
exit 0
