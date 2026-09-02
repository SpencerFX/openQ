//====================================================================
// Directory: modules/ingest/massive/cep.q
//
// About:
// -cepscript for the massive module's CEP (cfg_proc/modules/massive/cep.json).
// tp/rdb/idb/hdb are the exact same core/ code the default pipeline uses,
// pointed at schemas/schema_efx.q - the same fx_tick_massive table/columns
// a real historical EFX archive uses for this vendor (see the README's
// "Integrating an existing HDB" section), so this module's live-ingested
// data lines up with that archive's shape. What's different for this
// module is the shape of the pipeline itself: rdb.json/idb.json point
// their -tpaddr at this CEP instead of at the tp directly, so the data
// flow is tp -> cep -> rdb/idb -> hdb rather than tp -> rdb/idb -> hdb -
// the default process flow every module now follows (fh -> tp -> cep ->
// rdb/idb -> eod -> hdb, see the README's "Modules" section). This file is
// what makes that worthwhile to have at all: right now it's a deliberately
// generic pass-through (republish every incoming row of every
// schemas/schema_efx.q table unchanged via .u.upd, which both logs it to
// this CEP's own tplog and publishes it to rdb/idb), but it's the seam
// where massive-specific filtering/dedup/enrichment of the vendor feed
// would go once there's a real need for it - see modules/ingest/massive/
// fh.q for where the raw feed itself is parsed and mapped to this schema.
//
// Namespaces:
//   .massiveMod.* - the pass-through relay handler
//====================================================================

//@func   | .massiveMod.relay
//@param  | t | -11 | Table name (any table schemas/schema_efx.q declares)
//@param  | x | 98  | Incoming batch of rows for t
//@desc
//Republishes an incoming batch unchanged - logs it to this CEP's own
//tplog and publishes it to its subscribers (rdb/idb), same as a real tp
//would. Placeholder for future massive-specific processing.
//@desc
.massiveMod.relay:{[t;x]
 .u.upd[t;x];
 };

{.oq.cep.addHandler[x;.massiveMod.relay;`$"massiveRelay",string x]} each .oq.schema.tables[];
