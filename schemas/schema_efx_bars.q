// schema_efx_bars.q
// A deliberately narrower sibling of schema_efx.q (see the README's
// "Integrating an existing HDB" section): declares only the EFX
// archive's bar-level tables (fx_m1_massive, fx_m1_dukasCopy,
// fx_d1_massive), leaving out fx_tick_massive/fx_tick_dukasCopy - the
// two genuinely tick-level tables (tens of millions of rows/day).
// Exists specifically so tools that need to summarize a table's whole
// on-disk history (see core/housekeeping.q's .oq.hk.scanHDB, and
// examples/scripts/05_table_health_scan.q's own default) have a fast,
// safe target out of the box - point at schema_efx.q instead if you
// deliberately want the tick tables included and are prepared for a
// summary scan over them to take a while.
.oq.info.schemaEfxBars.loaded:0b;

fx_m1_massive:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); transactions:`long$(); source:`symbol$());

fx_m1_dukasCopy:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`float$(); ask_exchange:`symbol$(); bid_exchange:`symbol$());

fx_d1_massive:([] timestamp:`timestamp$(); sym:`symbol$(); open:`float$(); high:`float$(); low:`float$(); close:`float$(); volume:`long$(); transactions:`long$(); source:`symbol$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this narrower view of the EFX archive
//@desc
//The EFX archive's bar-level tables only - see the file header for why
//@desc
.oq.schema.tables:{[] `fx_m1_massive`fx_m1_dukasCopy`fx_d1_massive};

.oq.info.schemaEfxBars.loaded:1b;
