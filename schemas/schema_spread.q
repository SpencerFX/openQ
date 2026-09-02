//====================================================================
// Directory: schemas/schema_spread.q
//
// About:
// Schema for the spread module: one table, `spreadQuote`, matching
// modules/analytics/spread/spread.q's own canonical input shape (.spread.quote) exactly -
// one row per quote, already broken down into its seven named build-up
// components (refSprd/baseSprd/clientSprd/volSprd/smoothSprd/
// fallbackSprd/alphaSprd) rather than a single bid/ask spread. That's a
// real pricing engine's own internal accounting of how it built the
// quote, not something derivable from a plain bid/ask - unlike `massive`/
// `yfinance`, whose vendor feeds only ever report the total, this module
// assumes an upstream that already knows the components (see
// tests/q/cep_analytics_handler.q for how the default `quote` schema's
// bid/ask gets synthetically split into components when no such upstream
// exists - fine for exercising the ingest path, not a real pricing
// signal). Column renamed `time`->`timestamp` from .spread.quote's own
// definition to match every other openQ schema's timestamp,sym-first
// convention, enforced by tp.q's .u.tick.
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.info.schemaSpread.loaded:0b;

spreadQuote:([] timestamp:`timestamp$(); sym:`symbol$(); aggression:`symbol$(); marketStatus:`symbol$(); weight:`float$(); refSprd:`float$(); baseSprd:`float$(); clientSprd:`float$(); volSprd:`float$(); smoothSprd:`float$(); fallbackSprd:`float$(); alphaSprd:`float$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//The spread module's table set
//@desc
.oq.schema.tables:{[] enlist `spreadQuote};

.oq.info.schemaSpread.loaded:1b;
