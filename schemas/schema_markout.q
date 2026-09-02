// schema_markout.q
// Ingest schema for the markout module: real trade/order/rate streams
// shaped for modules/analytics/markout/markOutImpact.q's real-time entrypoints, rather
// than synthesizing them from the default quote/trade schema the way
// tests/q/cep_analytics_handler.q's demo adapter does. Same (timestamp,
// sym) convention as every other schema here, so the tp/rdb/idb/hdb
// pipeline needs no code of its own to handle it.
//
// Column -> library-field mapping (see modules/analytics/markout/cep.q):
//   trade: timestamp->tradeTime, price->tradeRate
//   order: timestamp->orderTime, price->orderRate
//   rate:  timestamp->time                          (shared by
//          .markout.onRate and .impact.onBook - both treat it as the
//          reference mid-rate feed they match trades/orders against)
.oq.schema.info.loaded:0b;

trade:([] timestamp:`timestamp$(); sym:`symbol$(); tradeID:`long$(); price:`float$());

order:([] timestamp:`timestamp$(); sym:`symbol$(); orderID:`long$(); price:`float$(); side:`symbol$());

rate:([] timestamp:`timestamp$(); sym:`symbol$(); mid:`float$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names managed by this schema
//@desc
//The set of tables the markout tickerplant/RDB/HDB operate on
//(tp.q's .u.tick separately validates timestamp,sym as its first 2 columns)
//@desc
.oq.schema.tables:{[] `trade`order`rate};

.oq.schema.info.loaded:1b;
