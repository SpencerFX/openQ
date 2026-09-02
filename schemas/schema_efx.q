// schema_efx.q
// Schema stubs matching an existing on-disk EFX historical HDB (see the
// "Integrating an existing HDB" section of the README) - tick and 1-
// minute/daily bar tables across two vendor feeds ("massive" and
// "dukasCopy"), each already keyed timestamp,sym first on disk. This is a
// read-only integration: these tables are declared here only so
// .oq.hdb.loadHDB has something to reload against and so querying a table
// that happens to have no data for a given date returns zero rows rather
// than erroring on an undefined global - nothing in openQ/core ever
// writes to these tables or this root.
.oq.info.schemaEfx.loaded:0b;

fx_tick_massive:([] timestamp:`timestamp$(); sym:`symbol$(); ask:`float$(); bid:`float$(); ask_exchange:`long$(); bid_exchange:`long$());

fx_tick_dukasCopy:([] timestamp:`timestamp$(); sym:`symbol$(); ask:`float$(); bid:`float$(); ask_volume:`float$(); bid_volume:`float$(); ask_exchange:`symbol$(); bid_exchange:`symbol$());

fx_m1_massive:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); transactions:`long$(); source:`symbol$());

fx_m1_dukasCopy:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`float$(); ask_exchange:`symbol$(); bid_exchange:`symbol$());

fx_d1_massive:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); transactions:`long$(); source:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this HDB
//@desc
//The EFX archive's table set
//@desc
.oq.schema.tables:{[] `fx_tick_massive`fx_tick_dukasCopy`fx_m1_massive`fx_m1_dukasCopy`fx_d1_massive};

.oq.info.schemaEfx.loaded:1b;
