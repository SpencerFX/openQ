// schema.q
// Table schema registry + two example generic tables (quote, trade).
// Every table must have `timestamp` and `sym` as its first two columns -
// this is enforced by tp.q's .u.tick and is what lets grouped/parted
// attributes and per-sym log/replay logic work uniformly across any
// instrument class. Column named `timestamp` (not the shorter `time`) to
// match the convention of on-disk kdb+ tick data typically encountered in
// the wild (see the efx integration in the README).
.oq.schema.info.loaded:0b;

quote:([] timestamp:`timestamp$(); sym:`symbol$(); bid:`float$(); ask:`float$(); bidSize:`float$(); askSize:`float$(); source:`symbol$());

trade:([] timestamp:`timestamp$(); sym:`symbol$(); price:`float$(); size:`float$(); side:`symbol$(); source:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//The set of tables the tickerplant/RDB/HDB operate on
//(tp.q's .u.tick separately validates each has timestamp,sym as its first 2 columns)
//@desc
.oq.schema.tables:{[] `quote`trade};

.oq.schema.info.loaded:1b;
