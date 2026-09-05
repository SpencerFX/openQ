//====================================================================
// Directory: core/housekeeping.q
//
// About:
// A small, illustrative set of health checks - not the exhaustive suite
// a production deployment would want, just the pattern. Two different
// shapes live here:
//   .oq.hk.check*  - timer-driven, take a handle to a LIVE process
//                    (tp/rdb/hdb) and log WARN/ERROR through the
//                    standard logger; a housekeeping process composes
//                    its own -hkscript from these to watch a fleet.
//   .oq.hk.scanHDB - detached, disk-only, batch (same "no live process
//                    needed" shape as core/eod.q): reads an HDB's
//                    on-disk partitions directly for a date range and
//                    returns a populated .oq.hk.tableHealth table - row
//                    counts, first/last timestamp, and on-disk size per
//                    (table,date), plus each table's whole-history
//                    summary (total row count, total bytes, partition
//                    count, oldest/newest date on disk).
//
// Namespaces:
//   .oq.hk.*    - TP/RDB/HDB health checks, the generic timer-registration
//                 helper, and .init - the full startup sequence (loads a
//                 deployment-supplied -hkscript, which must define
//                 .oq.hk.run); .tableHealth/.scanHDB for the disk-based
//                 HDB scan
//====================================================================
.oq.info.hk.loaded:0b;

//@func   | .oq.hk.checkTP
//@param  | h | -6 | Handle to a tickerplant process
//@desc
//Verifies the tickerplant's message counters (.u.i received, .u.j logged) are in sync;
//a persistent gap means messages are being dropped before they reach the log
//@desc
.oq.hk.checkTP:{[h]
 counts:@[h;"(.u.i;.u.j)";{[e](0Ni;0Ni)}];
 if[counts[0]<>counts[1];
    .util.log.ex[`WARN;`.oq.hk.checkTP]"Tickerplant ",(string h)," counters diverged: i=",(string counts 0)," j=",string counts 1
   ];
 counts
 };

//@func   | .oq.hk.checkRowCounts
//@param  | h    | -6 | Handle to an RDB process
//@param  | tabs | 11 | Tables expected to have data
//@desc
//Warns if an expected table is unexpectedly empty (skipped outside typical trading hours by design)
//@desc
.oq.hk.checkRowCounts:{[h;tabs]
 counts:tabs!@[h;;{[e]0Ni}] each {"count ",string x} each tabs;
 empty:tabs where counts=0;
 if[count empty;.util.log.ex[`WARN;`.oq.hk.checkRowCounts]"RDB ",(string h)," has empty table(s): ",", " sv string empty];
 counts
 };

//@func   | .oq.hk.checkHDBFresh
//@param  | h        | -6  | Handle to an HDB process
//@param  | maxAgeDay | -7 | Maximum acceptable age (in days) of the newest partition
//@desc
//Warns if the HDB's newest on-disk date partition is older than expected
//@desc
.oq.hk.checkHDBFresh:{[h;maxAgeDay]
 newest:@[h;"$[0=count date;0Nd;max date]";{[e]0Nd}];
 if[null newest;.util.log.ex[`WARN;`.oq.hk.checkHDBFresh]"HDB ",(string h)," has no partitions loaded";:0Nd];
 if[(.z.d-newest)>maxAgeDay;.util.log.ex[`WARN;`.oq.hk.checkHDBFresh]"HDB ",(string h)," newest partition is ",(string .z.d-newest)," day(s) old"];
 newest
 };

//--------------------------------------------------------------------
// HDB table health: disk-only, no live process needed - point at any
// on-disk partitioned HDB (this repo's own module HDBs, or a real
// external archive like schemas/schema_efx.q's) and a date range.
//--------------------------------------------------------------------

// One row per (table,date) scanned, plus that table's whole-history
// summary repeated on every one of its rows (simplest flat shape for
// a table meant to be queried/dashboarded directly, at the cost of
// some repetition - see README's "Backtesting"/analytics-style tables
// for the same "denormalized on purpose" tradeoff elsewhere).
.oq.hk.tableHealth:([]
  timestamp:`timestamp$();     // when this scan ran
  sym:`symbol$();              // caller-supplied identifier for this HDB/deployment (there's no live -name to read, since nothing is running)
  tab:`symbol$();              // table name
  role:`symbol$();             // always `hdb - this scan only ever reads on-disk history, never a live rdb/cep
  date:`date$();               // the partition this row describes
  rowCountToday:`long$();      // exact row count for this date's partition
  rowCountTotal:`long$();      // exact row count across every partition this table has, repeated per date row - see .oq.hk.priv.tableTotalRows for why this is a per-partition column read, not a live `count`
  firstTime:`timestamp$();     // earliest row in this date's partition
  lastTime:`timestamp$();      // latest row in this date's partition
  ageSec:`float$();            // now - lastTime, in seconds (large/uninteresting for an old historical date - it's a "how stale is this" signal for the newest partition, not an alert for a deliberate backfill)
  bytesMem:`long$();           // always null here - in-memory footprint only applies to a live rdb/cep, which this tool never touches
  bytesDisk:`long$();          // on-disk bytes for this date's partition
  partitionCnt:`int$();        // how many dates this table has ANY partition for, across its whole on-disk history, repeated per date row
  oldestDate:`date$();         // across the table's whole on-disk history, repeated per date row
  newestDate:`date$();         // across the table's whole on-disk history, repeated per date row
  status:`symbol$());          // `EMPTY (no rows this date - either no partition on disk at all, or an empty one) or `HEALTHY

//@func  | .oq.hk.priv.allDates
//@param  | root | symbol
//@desc
// every top-level entry of an HDB root that parses as a real date,
// ascending. "D"$string on a non-date entry (e.g. the root's own `sym`
// enumeration domain file) doesn't throw - it silently returns a null
// date - so entries are filtered by nullity, not by a protected apply.
//@desc
.oq.hk.priv.allDates:{[root]
  entries:key root;
  dates:"D"$string entries;
  asc dates where not null dates
 };

//@func  | .oq.hk.priv.hasPartition
//@param  | root | symbol
//@param  | d | date
//@param  | tab | symbol
//@desc
// 1b if this table has an on-disk partition directory for date d at
// all (even an empty one - a partition can exist with 0-row column
// files, e.g. a date the vendor genuinely published nothing for).
//@desc
.oq.hk.priv.hasPartition:{[root;d;tab] 0<count key ` sv (root;`$string d;tab)};

//@func  | .oq.hk.priv.partitionBytes
//@param  | root | symbol
//@param  | d | date
//@param  | tab | symbol
//@desc
// total on-disk bytes of every file in one (table,date) partition
// directory (every column file plus the splayed .d), via hcount - pure
// filesystem metadata, no data ever read into memory. 0 if the
// partition doesn't exist.
//@desc
.oq.hk.priv.partitionBytes:{[root;d;tab]
  dir:` sv (root;`$string d;tab);
  files:key dir;
  $[count files;sum hcount each ` sv/: dir,/:files;0]
 };

//@func  | .oq.hk.priv.partitionStats
//@param  | root | symbol
//@param  | d | date
//@param  | tab | symbol
//@desc
// (rowCount;firstTime;lastTime) for one (table,date) partition, by
// reading just the `timestamp` column's file directly off disk (every
// openQ table's guaranteed-present first column) - min/max come for
// free as first/last, since a partition's timestamp column is written
// sorted ascending by construction. This is the one read
// .oq.hk.scanHDB does per partition, reused for BOTH that date's own
// row and (summed/spanned across every partition) the table's whole-
// history summary - a live `count`/`select...by date` against the
// fully-loaded table was verified directly against a real multi-decade
// archive to take well over a minute (effectively unusable) where this
// takes single-digit seconds per table; reading the file directly like
// this also means .oq.hk.scanHDB never needs to `system"l"` the whole
// hdbroot into memory at all. (0;0Np;0Np) if the partition doesn't
// exist or is empty.
//@desc
.oq.hk.priv.partitionStats:{[root;d;tab]
  tsFile:` sv (root;`$string d;tab;`timestamp);
  if[not count key tsFile;:(0j;0Np;0Np)];
  ts:get tsFile;
  n:count ts;
  $[n>0;(n;first ts;last ts);(0j;0Np;0Np)]
 };

//@func  | .oq.hk.scanHDB
//@param  | hdbroot | symbol
//@param  | schemaFile | string
//@param  | sDate | date
//@param  | eDate | date
//@param  | name | symbol
//@param  | tabs | -11 | optional - overrides schemaFile's own .oq.schema.tables[]
//@desc
//   hdbroot: root of an on-disk partitioned HDB, e.g. `:../examples/
//        data/spread/hdb or a real external archive's root
//   schemaFile: path to the schema file declaring hdbroot's
//        .oq.schema.tables[] (see "Integrating an existing HDB" in the
//        README) - only the table LIST is needed, not the data itself;
//        this scan never loads hdbroot into memory (see
//        .oq.hk.priv.partitionStats)
//   sDate/eDate: inclusive date range to produce an output row for -
//        cheap at any size, including a table's entire on-disk
//        history, since every partition in that table's history gets
//        read exactly once regardless (see .oq.hk.priv.partitionStats)
//        to build the whole-history summary anyway
//   name: caller-supplied identifier for this HDB/deployment, stored
//        in the result's `sym` column (there's no live process to read
//        a real `-name` off)
//   tabs: an empty list (the default, `symbol$()) uses schemaFile's own
//        .oq.schema.tables[] unchanged - the right choice for a schema
//        that already declares exactly the tables this hdbroot holds
//        (e.g. schema_efx_bars.q for the efx archive). A non-empty list
//        instead scans exactly those table names, letting a BROADER
//        multi-root schema (e.g. schema_yfinance.q, which declares
//        every yfinance-family table across several different physical
//        roots) be reused for a scan of just the subset that actually
//        lives under THIS hdbroot, instead of hand-duplicating a
//        one-off scan-only schema file per root just to narrow the list.
// For every table in the schema: reads every on-disk partition's
// timestamp column exactly once (.oq.hk.priv.partitionStats) to get
// that table's whole-history summary (rowCountTotal, partitionCnt,
// oldestDate, newestDate - all pure disk reads, no live query), then
// emits one row per date in [sDate;eDate] using those same
// already-read stats - a date with no partition on disk at all gets an
// `EMPTY row with zeroed counts, exactly like a date whose partition
// exists but is empty; this scan doesn't distinguish the two. Returns
// .oq.hk.tableHealth's shape, one row per (table,date) actually
// scanned, across every table in the schema.
//@desc
.oq.hk.scanHDB:{[hdbroot;schemaFile;sDate;eDate;name;tabs]
  .util.core.loadScript schemaFile;
  root:hdbroot;
  scanDates:asc distinct sDate+til 1+eDate-sDate;
  tabs:$[count tabs;tabs;.oq.schema.tables[]];
  now:.z.p;
  raze {[root;scanDates;name;now;tab]
    allDates:.oq.hk.priv.allDates root;
    existDates:allDates where .oq.hk.priv.hasPartition[root;;tab] each allDates;
    partitionCnt:count existDates;
    oldestDate:$[partitionCnt;first existDates;0Nd];
    newestDate:$[partitionCnt;last existDates;0Nd];
    stats:.oq.hk.priv.partitionStats[root;;tab] each existDates;
    rowCountTotal:sum stats[;0];
    statsByDate:existDates!stats;
    // a per-date lambda needing all of these would exceed q's 8-named-
    // parameter cap, so everything but the date itself is bundled into
    // one dict instead (same workaround this session's own
    // modules/analytics/report/deskRisk.q already needed for the same reason)
    ctx:`tab`name`now`partitionCnt`oldestDate`newestDate`rowCountTotal`statsByDate!
      (tab;name;now;partitionCnt;oldestDate;newestDate;rowCountTotal;statsByDate);
    // raze here concatenates this table's per-date one-row tables into
    // a single table before returning - without it, each per-table
    // result would itself be a LIST of one-row tables, and the outer
    // raze (below, across tables) would only unwrap one level of that,
    // leaving a list-of-tables instead of one combined table
    raze {[root;ctx;d]
      s:$[d in key ctx`statsByDate;ctx[`statsByDate] d;(0j;0Np;0Np)];
      rowCountToday:s 0; firstTime:s 1; lastTime:s 2;
      bytesDisk:.oq.hk.priv.partitionBytes[root;d;ctx`tab];
      ([]
        timestamp:enlist ctx`now; sym:enlist ctx`name; tab:enlist ctx`tab; role:enlist `hdb; date:enlist d;
        rowCountToday:enlist rowCountToday; rowCountTotal:enlist ctx`rowCountTotal;
        firstTime:enlist firstTime; lastTime:enlist lastTime;
        ageSec:enlist `float$(ctx[`now]-lastTime)%1e9;
        bytesMem:enlist 0Nj; bytesDisk:enlist bytesDisk;
        partitionCnt:enlist ctx`partitionCnt; oldestDate:enlist ctx`oldestDate; newestDate:enlist ctx`newestDate;
        status:enlist $[rowCountToday=0;`EMPTY;`HEALTHY])
     }[root;ctx] each scanDates
   }[root;scanDates;name;now] each tabs
 };

//@func  | .oq.hk.saveHealth
//@param  | health | table
//@param  | root | symbol
//@param  | tabName | symbol
//@desc
//   tabName: the on-disk table name to save under, e.g. `tableHealth
//        or `tableHealthTick - lets separate scans (different source
//        schemas, e.g. bar-level vs tick-level tables) land side by
//        side under the same root as distinct tables, rather than
//        overwriting or mixing into one
// Persists .oq.hk.scanHDB's output to root, one date partition per
// distinct date in health - reuses core/save.q's own staging/sort/
// enumerate step (.oq.save.saveTable) for each table, the same
// durable-write convention every other table in this repo uses.
// .oq.save.saveTable looks up its table's data via `value tabName`
// against a plain root-level global of that exact name, so each date's
// slice is staged into a bare global of that name (not
// .oq.hk.tableHealth, which is only this file's empty-shape stub)
// before publishing.
//
// Deliberately does NOT call .oq.save.publish for the final move: that
// function assumes it's the only writer for the whole date partition
// (true for every other module here, each with its own separate HDB
// root) and does a single whole-directory OS move - fine the first
// time a date is written, but if root/dt already exists (e.g. a
// second, independent .oq.hk.saveHealth call - bar-level tableHealth,
// then tick-level tableHealthTick - sharing one root), an OS `move`
// onto an existing directory moves the source INSIDE it rather than
// merging, silently nesting the whole staged partition one level too
// deep (found the hard way running exactly this scenario). Instead,
// when root/dt already exists, only this one table's own staged
// subdirectory is moved across (landing correctly as root/dt/tabName
// alongside whatever's already there), and the now-empty stage wrapper
// is removed directly.
//@desc
.oq.hk.saveHealth:{[health;root;tabName]
  {[health;root;tabName;d]
    tabName set 0!select from health where date=d;
    stage:.oq.save.stageDir[root;d];
    .oq.save.saveTable[tabName;d;stage;root];
    dest:.Q.dd[root;`$string d];
    $[count key dest;
      [.util.core.osMove[.Q.dd[stage;tabName];.Q.dd[dest;tabName]];
       .util.core.osRmdir stage];
      .oq.save.publish[stage;root;d]
     ];
   }[health;root;tabName] each asc distinct health`date;
 };

//@func   | .oq.hk.addTimer
//@param  | freq | -16 | How often to run the health checks
//@param  | func | 100 | Niladic function running the checks for this deployment
//@desc
//Registers a housekeeping timer; callers compose their own check function from the above
//@desc
.oq.hk.addTimer:{[freq;func]
 .util.timer.add[.z.p;0Wp;freq;func;`DEF;"housekeeping checks"]
 };

//@func   | .oq.hk.init
//@desc
//Full startup sequence for a housekeeping process: loads the deployment-
//supplied -hkscript, which is expected to define .oq.hk.run (a niladic
//function composing whichever of the check functions above make sense
//for this deployment, e.g. opening handles to the fleet and calling
//.oq.hk.checkTP/checkRowCounts/checkHDBFresh against them), then
//registers it on a timer at -hkfreq. Reads its own params from
//.util.start.CLP so callers (init.q/initFromCfg.q) don't need to know
//which CLI params a housekeeping process needs.
//@desc
.oq.hk.init:{[]
 hkscript:.util.start.CLP[`hkscript][`val];
 if[count hkscript;.util.core.loadScript[hkscript]];
 if[not `run in key `.oq.hk;.util.log.exSig[`ERROR;`.oq.hk.init]"No .oq.hk.run defined - -hkscript must define it before .oq.hk.init runs"];
 freq:"N"$.util.start.CLP[`hkfreq][`val];
 .oq.hk.info.timer.checks:.oq.hk.addTimer[freq;`.oq.hk.run];
 .util.log.ex[`INFO;`.oq.hk.init]"Housekeeping started: ",string .util.start.CLP[`name][`val];
 };

.oq.info.hk.loaded:1b;
