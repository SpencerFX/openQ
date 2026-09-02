//====================================================================
// Directory: schemas/schema_eq.q
//
// About:
// Schema stub matching an existing on-disk equities HDB (C:/data/db1/eq),
// produced by the stockData project's Yahoo Finance daily-OHLCV loader
// (NYSE + Nasdaq listings). Read-only integration, same intent as
// schemas/schema_efx.q: the table is declared here only so
// .oq.hdb.loadHDB has something to reload against, and so querying a date
// with no data returns zero rows rather than erroring on an undefined
// global - nothing in openQ/core ever writes to this table or this root.
//
// Two tables, both read-only, both under C:/data/db1/eq:
//
//   eq_d1_yfinance  - daily OHLCV, US (NYSE + Nasdaq), 2010 -> present. NO
//     `timestamp` column: a pure date-partitioned daily bar table (the
//     partition directory IS the trading day), so it never flows through a
//     tickerplant and tp.q's .u.tick timestamp,sym validation does not
//     apply. On disk: sym,open,high,low,close,volume,exchange with `p
//     (parted) on sym; the `date column is virtual, from the partitioning.
//
//   eq_m1_yfinance - 1-minute OHLCV, Asian markets (HKEX + Tokyo/Nikkei),
//     rolling ~1-month window (Yahoo's 1m history limit). This one DOES
//     carry the openQ `timestamp,sym`-first columns plus its own `barTime`
//     (the minute the bar covers). `p (parted) on sym; `date virtual.
//
// Both are declared here only so .oq.hdb.loadHDB has something to reload
// against and querying an empty date returns zero rows rather than
// erroring - nothing in openQ/core ever writes to this root.
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.info.schemaEq.loaded:0b;

eq_d1_yfinance:([] sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());

eq_m1_yfinance:([] timestamp:`timestamp$(); sym:`symbol$(); barTime:`timestamp$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); exchange:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this HDB
//@desc
//The equities archive's table set
//@desc
.oq.schema.tables:{[] `eq_d1_yfinance`eq_m1_yfinance};

.oq.info.schemaEq.loaded:1b;
