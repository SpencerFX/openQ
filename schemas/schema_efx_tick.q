// schema_efx_tick.q
// The EFX archive's two tick-level tables only (see schema_efx_bars.q
// for its bar-level sibling and the reasoning behind splitting them) -
// fx_tick_massive/fx_tick_dukasCopy carry tens of millions of rows/day,
// so a whole-history .oq.hk.scanHDB pass over these is expected to take
// substantially longer than the bar-level tables (see
// core/housekeeping.q's .oq.hk.priv.partitionStats header: the scan
// scales with real on-disk row volume, by design).
.oq.info.schemaEfxTick.loaded:0b;

fx_tick_massive:([] timestamp:`timestamp$(); sym:`symbol$(); ask:`float$(); bid:`float$(); ask_exchange:`long$(); bid_exchange:`long$());

fx_tick_dukasCopy:([] timestamp:`timestamp$(); sym:`symbol$(); ask:`float$(); bid:`float$(); ask_volume:`float$(); bid_volume:`float$(); ask_exchange:`symbol$(); bid_exchange:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this narrower, tick-only view of the EFX archive
//@desc
//The EFX archive's tick-level tables only - see the file header for why
//@desc
.oq.schema.tables:{[] `fx_tick_massive`fx_tick_dukasCopy};

.oq.info.schemaEfxTick.loaded:1b;
