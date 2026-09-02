//====================================================================
// Directory: schemas/schema_eq_m1_yfinance.q
//
// About:
// Schema for eq_m1_yfinance - 1-minute OHLCV bars for exchange-listed
// cash equities, sourced from Yahoo Finance by the ingest scripts in
// modules/ingest/yfinance/ (m1_universe.py / m1_backfill.py / m1_feed.py /
// m1_to_kdb.py, all --exchange driven via exchanges.py). One shared table
// for every venue (HKEX, NYSE, Nasdaq, LSE, Tokyo/JPX-"nikkei", ...); the
// venue is carried in the `exchange column.
//
// The minute-bar sibling of schema_eq.q's daily eq_d1_yfinance, in the same
// on-disk HDB root (C:/data/db1/eq) - same split as efx's schema_efx.q vs
// schema_efx_bars.q. load_eq_m1_yfinance.q runs .Q.chk on the root so
// eq_m1_yfinance and eq_d1_yfinance (very different date spans) coexist
// without 'path.
//
// Two entry points feed the table:
//   - m1_feed.py  (live)  publishes completed minute bars into an openQ
//     tickerplant; tp.q's .u.updB prepends `timestamp (ingest time).
//   - load_eq_m1_yfinance.q (batch) writes date partitions straight to the
//     HDB from a staging CSV; there it sets `timestamp := `barTime.
//
// `barTime is the minute the bar covers, UTC, tz stripped (m1_common.
// normalise_bars - deliberately NOT exchange-local wall-clock, so this
// table's own `date$barTime partitioning always agrees with `.z.d` and
// every other UTC-based date decision in this repo, e.g. eod_housekeeping.q's
// scheduled EOD trigger) and is the column to sort/query on; `timestamp is
// only the arrival stamp. Exchange-local time is still used, separately,
// for session gating (exchanges.py's poll_start/poll_end) - just not for
// anything stored on disk. On disk: date-partitioned (from `date$barTime),
// `p (parted) on `sym; column order timestamp,sym,barTime,open,high,low,
// close,volume,exchange.
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.info.schemaEqM1Yfinance.loaded:0b;

eq_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//The eq_m1_yfinance minute-bar table
//@desc
.oq.schema.tables:{[] enlist `eq_m1_yfinance};

.oq.info.schemaEqM1Yfinance.loaded:1b;
