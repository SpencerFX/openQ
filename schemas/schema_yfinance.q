//====================================================================
// Directory: schemas/schema_yfinance.q
//
// About:
// One schema for the whole modules/ingest/yfinance/ family - the merge of
// the five former per-table files, plus the fx pair added later:
//   schema_eq_m1_yfinance.q          -> eq_m1_yfinance
//   schema_futures_m1_yfinance.q     -> futures_m1_yfinance
//   schema_rateIndices_m1_yfinance.q -> rateIndices_m1_yfinance
//   schema_futures_d1_yfinance.q     -> futures_d1_yfinance
//   schema_rateIndices_d1_yfinance.q -> rateIndices_d1_yfinance
//
// Tables
// ------
//   MINUTE bars  (timestamp,sym-first; fed live through an openQ
//   tickerplant by py/feed.py, or batch-written by q/load_yfinance.q):
//     eq_m1_yfinance          HKEX / NYSE / Nasdaq / LSE / Tokyo("nikkei")
//                             cash equities - ONE table, venue in `exchange
//     futures_m1_yfinance     CME/ICE US continuous front-month "=F" futures
//     rateIndices_m1_yfinance CBOE UST yield indices ^IRX/^FVX/^TNX/^TYX
//     fx_m1_yfinance          major FX spot pairs (EURUSD, USDJPY, GBPUSD,
//                             USDCHF, USDCAD, AUDUSD, NZDUSD)
//
//   DAILY bars   (PURE date-partitioned, NO `timestamp column - the
//   partition dir IS the trading day; HDB-only, never through a
//   tickerplant; written by py/to_kdb.py --cadence d1 + q/load_yfinance.q):
//     futures_d1_yfinance     daily sibling of futures_m1_yfinance, 2010->
//     rateIndices_d1_yfinance daily sibling of rateIndices_m1_yfinance,
//                             full Yahoo history (^IRX to 1960)
//     fx_d1_yfinance          daily sibling of fx_m1_yfinance
//
// eq_d1_yfinance (US equity daily, from the stockData project) is NOT
// here - it keeps its own canonical stub in schema_eq.q, the read-only
// external eq HDB integration, and its catalog.json entry points there.
//
// Column shapes
// -------------
//   m1:  timestamp:p sym:s barTime:p open:f high:f low:f close:f volume:j exchange:s
//   d1:  sym:s open:f high:f low:f close:f volume:j exchange:s     (`date virtual)
// On disk every table is date-partitioned with `p (parted) on `sym.
// `barTime is the minute the bar covers, UTC / tz-stripped (core.
// normalise) - deliberately not exchange-local, so `date$barTime
// partitioning always agrees with `.z.d. `timestamp is the arrival stamp
// on the live path, and is set = `barTime on the batch path.
// C:/data/db1/eq holds eq_m1_yfinance alongside the external eq_d1_yfinance.
// Three pairs of tables get their OWN shared root apiece, each for a
// different reason:
//   rateIndices_m1_yfinance + rateIndices_d1_yfinance -> C:/data/db1/rates
//     (migrated 2026-09-05, consolidating what used to be split across eq
//     (m1) and a dedicated C:/data/db1/ratesD1 (d1, ^IRX-to-1960 - sharing
//     eq would've let q/load_yfinance.q's .Q.chk stub every eq sibling
//     across ~13k extra pre-2010 partitions). Now that both rate-index
//     tables share one small, dedicated root, that stub cost is bounded
//     to just the two of them - see the migration note in hk_m1_ingest_
//     build (memory) for the sym/exchange enum-domain gotcha this move
//     surfaced: the m1 table's sym/exchange columns had been `.Q.en`'d
//     against eq's (large) domain the whole time it lived there, while
//     the d1 table's had always been enumerated against its own tiny
//     (5-symbol) domain - merging them into one root required decoding
//     m1's columns via eq's domain and re-encoding them against the
//     d1 table's domain (reused as the new root's canonical `sym file),
//     NOT just moving/copying files, or the enum codes would silently
//     resolve to the wrong (or blank) symbols.
//   futures_m1_yfinance + futures_d1_yfinance -> C:/data/db1/futures
//     (migrated 2026-09-05, purely for separation of concerns - both
//     tables were always enumerated against the SAME eq domain the whole
//     time, so this move only needed eq's current sym file copied into
//     the new root alongside the data, no re-encoding).
//   fx_m1_yfinance + fx_d1_yfinance -> C:/data/db1/efx (2026-09-05: first
//     deleted outright from eq at the user's request - eq's sym domain
//     was then pruned back down to just what eq_m1/d1_yfinance actually
//     use, see the migration note in hk_m1_ingest_build (memory) - then
//     the CONFIG repointed at C:/data/db1/efx, the read-only vendor FX
//     tick/m1/d1 archive integrated read-only via schema_efx.q (see the
//     "EFX HDB integration" note in openq_core_build (memory)). This is
//     a deliberate departure from that archive's original "openQ never
//     writes here" invariant, made knowingly at the user's explicit
//     choice after being flagged: fx_m1_yfinance's tp/rdb now write into
//     the same root on every EOD, and the first real load there will pay
//     a one-time .Q.chk stub pass across efx's ~5,375 partitions (2009->).
//     No data has been loaded into efx under this config yet as of the
//     migration - fx currently has zero rows anywhere.
//
// Why this is the ONLY procType/-name-aware schema_*.q
// ---------------------------------------------------
// Five files that each backed a SEPARATE tp/rdb/idb/hdb pipeline are now
// loaded by all of them, and two openQ conventions make a single flat
// table list wrong:
//
//  1. core/tp.q's .u.tick aborts the process (libs .util.log.exSig) if
//     any root table lacks timestamp,sym as its first two columns. The
//     daily tables have no `timestamp, so they are DEFINED only when this
//     process is an HDB (procType=`hdb) or a bare ad-hoc load - a
//     tickerplant / rdb / idb never sees them.
//
//  2. .oq.schema.tables[] means "the tables THIS pipeline owns" -
//     core/save.q and core/idb.q EOD-write every name it returns and
//     .oq.save.publish REPLACES the on-disk partition, so an over-broad
//     list would let e.g. the eq_m1 idb clobber the real
//     futures_m1_yfinance partition with an empty one. Every openQ process
//     here is named  <table>_<role>  (eq_m1_yfinance_tp,
//     futures_d1_yfinance_hdb, ...), so .oq.schema.tables[] resolves its
//     -name back to that one table; an unrecognised / absent -name
//     (manual load) gets the full set.
//
// Namespaces:
//   .oq.schema.priv.*  - the -name / procType resolution helpers
//====================================================================
.oq.info.schemaYfinance.loaded:0b;

// ---- minute-bar tables : always defined (all timestamp,sym-first) -------
eq_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
futures_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
rateIndices_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
fx_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());

//@func   | .oq.schema.priv.all
//@return | 11 | Every table this schema knows about (m1 quartet + d1 trio)
.oq.schema.priv.all:`eq_m1_yfinance`futures_m1_yfinance`rateIndices_m1_yfinance`fx_m1_yfinance`futures_d1_yfinance`rateIndices_d1_yfinance`fx_d1_yfinance;

//@func   | .oq.schema.priv.procType
//@return | -11 | this process's -procType, ` when start.q isn't loaded
.oq.schema.priv.procType:{[] @[{.util.start.CLP[`procType][`val]};`;`]};

//@func   | .oq.schema.priv.table
//@return | -11 | the yfinance table this process's -name resolves to
//                (-name is <table>_<role>), ` if it matches nothing
.oq.schema.priv.table:{[]
  nm:@[{string .util.start.CLP[`name][`val]};`;""];
  cand:`$"_" sv -1 _ "_" vs nm;
  $[cand in .oq.schema.priv.all; cand; `]
  };

// ---- daily-bar tables : HDB-only (no `timestamp -> would trip .u.tick) --
if[.oq.schema.priv.procType[] in (`;`hdb);
   futures_d1_yfinance:([] sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
   rateIndices_d1_yfinance:([] sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
   fx_d1_yfinance:([] sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());
  ];

//@func   | .oq.schema.tables
//@return | 11 | the table(s) THIS pipeline owns - its -name resolved to a
//               single table, or the full yfinance set for an
//               unrecognised / absent -name (manual load); always
//               filtered to what this process actually defined
//@desc
//Kept per-pipeline on purpose: core/save.q + core/idb.q EOD-write every
//name this returns and .oq.save.publish REPLACES the on-disk partition,
//so returning a sibling table here would let one pipeline's EOD wipe
//another's data. See this file's header.
//@desc
.oq.schema.tables:{[]
  t:$[null c:.oq.schema.priv.table[]; .oq.schema.priv.all; enlist c];
  t where t in key `.
  };

.oq.info.schemaYfinance.loaded:1b;
