//====================================================================
// Directory: schemas/schema_candlepattern.q
//
// About:
// Schema for candlePattern - the standalone, multi-timeframe candlestick
// pattern scan modules/analytics/candle/run.q produces against real
// eq_m1_yfinance 1-minute bars. Not fed by any tp - populated in one
// batch by run.q, which persists it into its own dated HDB root
// (C:/data/db1/candlePattern) via the same .oq.save.saveTable/.oq.save.eod
// pipeline every other module's EOD path uses, so it's queryable like any
// other partitioned table afterward (see the README's "Integrating an
// existing HDB" section for the read side of that story).
//
// One row per (sym, timeframe, pattern) where the pattern actually fired
// - sparse by construction (.candle.signals only emits non-zero signals),
// not one row per bar. timestamp is the fired bar's own timeframe-bucket
// start (not an arrival time - there's no live feed here).
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.schema.info.loaded:0b;

candlePattern:([] timestamp:`timestamp$(); sym:`symbol$(); exchange:`symbol$(); timeframe:`symbol$(); pattern:`symbol$(); direction:`symbol$(); signal:`float$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//This standalone schema's one table
//@desc
.oq.schema.tables:{[] enlist `candlePattern};

.oq.schema.info.loaded:1b;
