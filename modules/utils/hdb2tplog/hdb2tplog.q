//====================================================================
// Directory: modules/utils/hdb2tplog/hdb2tplog.q
//
// About:
// Reads a table back out of an on-disk database and writes it as a
// tickerplant log - a flat file of  (`upd;tableName;rows)  messages, the
// exact shape core/tp.q writes with  l enlist (`upd;t;x) . The output is
// a standard openQ tp log: replay it with  -11!  and  upd:insert  (what
// core/rdb.q itself does), point a fresh core/rdb.q or core/idb.q at it,
// or drop it into a -tplogdir for a restarting RDB to catch up from.
//
// Like modules/backtest/run.q and modules/utils/generator/generator.q this is
// a plain script - not a -procType role, not driven by core/init.q /
// core/config.q - because there is nothing live to subscribe to: the
// database is static on disk. It is strictly READ-ONLY against -hdb: it
// only system"l"-loads it and selects from it, exactly like core/hdb.q's
// own .oq.hdb.loadHDB and the guarantee tests/sh/run_efx_test.sh makes.
//
// Run from the repo root:
//   q modules/utils/hdb2tplog/hdb2tplog.q -hdb <dir> -table <name> -log <file> \
//       [-schema <schema.q>] [-batch <rows>] [-part <v,v,..>] \
//       [-lastn <n>] [-keeppart] [-nosort] [-verify]
//
//   -hdb      database root to load (partitioned, segmented or splayed)
//   -table    table to export
//   -log      output log file (created / overwritten)
//   -schema   openQ schema stub to load first (e.g. schemas/schema_efx.q)
//             so .oq.schema.tables[] etc. are defined - optional, the
//             export itself reads the table's real shape from `meta`
//   -batch    rows per tp message (default 100000); -batch 1 writes one
//             upd message per row (no batching)
//   -part     export only these partition value(s), comma-separated, in
//             q literal syntax (e.g. -part 2026.05.22 or -part 2026.05.22,2026.05.21)
//   -lastn    export only the N most recent partitions
//   -keeppart keep the virtual partition column (e.g. `date`); dropped by
//             default so the replayed table matches the columns a live
//             feed publishes / what core/tp.q would have logged intraday
//   -nosort   do not order each batch by time; default is to sort by
//             `timestamp` (or `time`) when present - partitioned tables
//             are ordered within each partition
//   -verify   after writing, replay the log in-process and check the row
//             count matches what was written
//
// Example - one day of fx_m1_massive from the EFX archive:
//   q modules/utils/hdb2tplog/hdb2tplog.q -hdb C:/data/db1/efx \
//       -table fx_m1_massive -log examples/data/fx_m1_massive.tplog \
//       -schema schemas/schema_efx.q -part 2025.12.31 -verify
//
// Namespaces:
//   .oq.h2t.*  - HDB load + per-partition / splayed row extraction, tp-log
//                message write, in-process replay-and-verify. Private
//                helpers live under .oq.h2t.priv.*
//====================================================================
.oq.info.h2t.loaded:0b;

//@func   | .oq.h2t.priv.topath
//@param  | p | -11 10 | path as a symbol, hsym, or string
//@return | -11 | hsym, with Windows back-slashes normalised to '/'
.oq.h2t.priv.topath:{[p]
 hsym `$ $[10h=type p; ssr[p;"\\";"/"]; string p]
 };

//@func   | .oq.h2t.priv.unenum
//@param  | d | 98 | table
//@return | 98 | same table, any enumerated columns resolved to plain symbols
//@desc
//A live feed publishes plain symbols; on-disk sym columns are enum-typed
//(`sym$...). Resolving them makes the log self-contained - it replays
//with no dependency on the source HDB's sym file - and matches what
//core/tp.q would actually have written intraday.
//@desc
.oq.h2t.priv.unenum:{[d]
 flip {$[(type x) within 20 76h; get x; x]} each flip d
 };

//@func   | .oq.h2t.priv.flush
//@param  | h     | -6  | open log-file handle
//@param  | t     | -11 | table name
//@param  | batch | -7  | rows per message
//@param  | d     | 98  | rows to write
//@return | -7 | number of rows written
//@desc
//Appends d to the log as one or more  (`upd;t;chunk)  messages. Rows are
//picked by index (d rowIndexList), so each write is O(batch), never
//O(remaining) - the difference between fine and out-of-memory when
//batch=1 over a many-million-row table.
//@desc
.oq.h2t.priv.flush:{[h;t;batch;d]
 d:.oq.h2t.priv.unenum d;
 n:count d;
 starts:batch*til ceiling n%batch;
 {[h;t;batch;n;d;s] h enlist (`upd;t;d (s+til batch&n-s))}[h;t;batch;n;d] each starts;
 n
 };

//@func   | .oq.h2t.priv.onePart
//@param  | h        | -6  | open log-file handle
//@param  | t        | -11 | partitioned table name
//@param  | pf       | -11 | partition field (.Q.pf)
//@param  | keeppart | -1  | keep the virtual partition column?
//@param  | tcol     | -11 | time column to sort by, ` for none
//@param  | batch    | -7  | rows per message
//@param  | v        |     | one partition value
//@return | -7 | rows written for this partition
//@desc
//One partition of a partitioned table. Held in memory only one at a
//time, so peak memory is bounded by the largest partition.
//@desc
.oq.h2t.priv.onePart:{[h;t;pf;keeppart;tcol;batch;v]
 d:?[t;enlist (=;pf;v);0b;()];
 if[not keeppart; d:(cols[d] except pf)#d];
 if[not null tcol; d:tcol xasc d];
 .oq.h2t.priv.flush[h;t;batch;d]
 };

//@func   | .oq.h2t.build
//@param  | hdbDir  | -11 10 | database root (hsym or string)
//@param  | tabName | -11 10 | table to export
//@param  | logFile | -11 10 | output log file
//@param  | opt     | 99     | dict, any of `batch`keeppart`nosort`lastn`parts (all optional)
//@return | -7 | total rows written
//@desc
//Loads the database read-only, then streams the table into logFile as a
//tickerplant log. Partitioned tables are read one partition at a time;
//splayed / flat tables are read in a single select (which also resolves
//their enum columns). Sets .oq.h2t.lastLog / .oq.h2t.lastRows so a
//following .oq.h2t.verify[] knows what to check.
//@desc
.oq.h2t.build:{[hdbDir;tabName;logFile;opt]
 gv:{[o;k;d] $[k in key o; o k; d]};
 hdbDir :.oq.h2t.priv.topath hdbDir;
 logFile:.oq.h2t.priv.topath logFile;
 tabName:$[10h=abs type tabName; `$tabName; tabName];
 batch  :"j"$gv[opt;`batch;100000];
 if[batch<=0; '"batch must be > 0"];
 keeppart:gv[opt;`keeppart;0b];
 nosort  :gv[opt;`nosort;0b];
 lastn   :gv[opt;`lastn;0N];
 parts   :gv[opt;`parts;()];

 -1 "hdb2tplog: loading HDB ",1_string hdbDir;
 system "l ",1_string hdbDir;
 if[not tabName in tables[]; '"table '",string[tabName],"' not found after loading HDB"];

 tcol:$[nosort; `; first `timestamp`time inter cols tabName];
 if[not null tcol; -1 "hdb2tplog: ordering each batch by `",string tcol];

 pv:asc .Q.pv;
 if[count parts;
  if[count miss:parts except pv; '"requested partition(s) not in HDB: ",-3!miss];
  pv:pv inter parts
  ];
 if[not null lastn; pv:neg[lastn] sublist pv];
 if[tabName in .Q.pt;
  -1 "hdb2tplog: ",string[count pv]," partition(s): ",$[count pv;(-3!first pv)," .. ",-3!last pv;"(none)"]
  ];

 .[logFile;();:;()];                       // create / truncate the log file
 h:hopen logFile;

 counts:$[tabName in .Q.pt;
  .oq.h2t.priv.onePart[h;tabName;.Q.pf;keeppart;tcol;batch] each pv;
  [d:?[tabName;();0b;()];                   // select-all: also resolves enums
   if[not null tcol; d:tcol xasc d];
   .oq.h2t.priv.flush[h;tabName;batch;d]]
  ];

 hclose h;

 rows:sum counts;
 msgs:"j"$sum ceiling counts%batch;
 .oq.h2t.lastLog :logFile;
 .oq.h2t.lastRows:rows;
 -1 "hdb2tplog: wrote ",string[rows]," row(s) in ",string[msgs]," message(s) to ",1_string logFile;
 rows
 };

//@func   | .oq.h2t.verify
//@return | -1 | 1b if the last-written log replays to the expected row count
//@desc
//Replays .oq.h2t.lastLog in this process with a counting `upd` and checks
//the total against .oq.h2t.lastRows. Builds no tables, so it is safe to
//call in the same process that still has the source HDB loaded. Note it
//does overwrite the root `upd` (with a counter) - fine for the script
//path, which exits straight after. Uses  `upd set  rather than
//@[`.;`upd;:;] - the latter amends the root namespace as a dict, which
//touches every global in it and raises 'par when a partitioned table is
//loaded (which it always is here).
//@desc
.oq.h2t.verify:{[]
 .oq.h2t.vn:0;
 `upd set {[t;x] .oq.h2t.vn+:count x};
 -11! .oq.h2t.lastLog;
 ok:.oq.h2t.vn=.oq.h2t.lastRows;
 $[ok;
  -1 "hdb2tplog: verify OK - replayed ",string[.oq.h2t.vn]," row(s)";
  -2 "hdb2tplog: VERIFY MISMATCH - replayed ",string[.oq.h2t.vn]," row(s), expected ",string .oq.h2t.lastRows
  ];
 ok
 };

//@func   | .oq.h2t.replay
//@param  | logFile | -11 10 | tp log to replay
//@return | -7 | number of messages replayed
//@desc
//Convenience replay into in-memory tables: sets a permissive root `upd`
//that creates each target table on first sight (schema inferred from the
//rows) and inserts thereafter, then streams the log with -11!. This is
//just core/rdb.q's replay (upd:insert) with on-the-fly table creation -
//for the real pipeline, point a core/rdb.q or core/idb.q at the log.
//@desc
.oq.h2t.replay:{[logFile]
 logFile:.oq.h2t.priv.topath logFile;
 `upd set {[t;x] if[not t in tables[]; t set 0#x]; t insert x};
 n:-11! logFile;
 -1 "hdb2tplog: replayed ",string[n]," message(s) from ",1_string logFile;
 n
 };

//@func   | .oq.h2t.main
//@param  | argv | 0 | .z.x - the list of CLI argument strings
//@desc
//Script entry point: parse args, optionally load an openQ schema stub,
//build the log, optionally verify, then exit. Not called when the file
//is only  system"l" -loaded as a library (no args).
//@desc
.oq.h2t.main:{[argv]
 args:.Q.opt argv;
 opt:{[a;k;d] $[k in key a; first a k; d]};
 if[not all `hdb`table`log in key args;
  -2 "usage: q modules/utils/hdb2tplog/hdb2tplog.q -hdb <dir> -table <name> -log <file>",
     " [-schema <f>] [-batch <n>] [-part <v,v,..>] [-lastn <n>] [-keeppart] [-nosort] [-verify]";
  exit 1
  ];
 schema:opt[args;`schema;""];
 if[count schema; system "l ",schema];
 o:`batch`keeppart`nosort`lastn`parts!(
  "J"$opt[args;`batch;"100000"];
  `keeppart in key args;
  `nosort in key args;
  $[`lastn in key args; "J"$first args`lastn; 0N];
  $[`part in key args; value each "," vs first args`part; ()]);
 .oq.h2t.build[opt[args;`hdb;""]; `$opt[args;`table;""]; opt[args;`log;""]; o];
 if[`verify in key args; .oq.h2t.verify[]];
 exit 0
 };

.oq.info.h2t.loaded:1b;

if[count .z.x; .oq.h2t.main .z.x]
