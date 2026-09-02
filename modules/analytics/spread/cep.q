//====================================================================
// Directory: modules/analytics/spread/cep.q
//
// About:
// -cepscript for the spread module's CEP (cfg_proc/modules/spread/cep.json).
// This file already fed spread.q's (its own sibling file) real-time
// entrypoint from the incoming `spreadQuote` stream, plus a widest-spread
// summary timer - see .spreadMod.onQuote/.spreadMod.summary below. rdb
// (an active/standby pair - see core/rdb.q's header) points its -tpaddr
// at this CEP rather than at the tp directly (the default process flow:
// fh -> tp -> cep -> rdb -> eod -> hdb, plus idb pivoting the rdb pair
// on its own timer rather than subscribing anywhere - see core/idb.q's
// header - see the README's "Modules" section), so alongside the
// analytics this file also relays every row unchanged via .u.upd -
// otherwise nothing downstream of the CEP would ever see any data.
//
// Unlike markout/impact, spread attribution needs no future data to
// resolve (see spread.q's own "Real-time path" section) - a
// quote is fully explainable the instant it arrives, so there's no
// pending-row sweep timer here the way markout's module has. The one
// custom timer this module needs instead logs which (sym,aggression,
// marketStatus) keys are currently quoting widest, using whatever
// .spread.onQuote has already composed into .spread.snap - a cheap,
// always-current read, not a fresh aggregation over raw history.
//
// Namespaces:
//   .spreadMod.* - quote ingest handler, widest-spread summary timer,
//                  and the relay
//====================================================================
system "l ../modules/analytics/spread/spread.q";

//How many of the currently-widest keys .spreadMod.summary logs
.spreadMod.summaryTop:3;

//How often .spreadMod.summary fires
.spreadMod.summaryFreq:0D00:01:00;

//@func   | .spreadMod.onQuote
//@param  | t | -11 | Table name (always `spreadQuote)
//@param  | x | 98  | Incoming batch of `spreadQuote rows
//@desc
//Composes and snapshots every incoming quote via .spread.onQuote, one row
//at a time - .spread.snap is keyed per (sym,aggression,marketStatus), so
//each call upserts that key's latest state rather than accumulating history
//@desc
.spreadMod.onQuote:{[t;x]
 {[row] .spread.onQuote `sym`aggression`marketStatus`time`weight`refSprd`baseSprd`clientSprd`volSprd`smoothSprd`fallbackSprd`alphaSprd!
    (row[`sym];row[`aggression];row[`marketStatus];row[`timestamp];row[`weight];row[`refSprd];row[`baseSprd];row[`clientSprd];row[`volSprd];row[`smoothSprd];row[`fallbackSprd];row[`alphaSprd])
  } each 0!x;
 };

//@func   | .spreadMod.summary
//@desc
//Timer callback: logs the currently-widest .spreadMod.summaryTop keys by
//totalSprd out of .spread.latest[] - a snapshot of "who's priced widest
//right now", not a windowed count like mon's error summary (there's
//nothing to reset here; .spread.snap is already just the latest state)
//@desc
.spreadMod.summary:{[]
 latest:.spread.latest[];
 if[0=count latest;:(::)];
 widest:.spreadMod.summaryTop sublist `totalSprd xdesc latest;
 {[row].util.log.ex[`INFO;`.spreadMod.summary]"Widest spread: ",(string row[`sym])," ",(string row[`aggression])," ",(string row[`marketStatus])," totalSprd=",string row[`totalSprd]} each 0!widest;
 };

//@func   | .spreadMod.relay
//@param  | t | -11 | Table name (always `spreadQuote)
//@param  | x | 98  | Incoming batch of rows for t
//@desc
//Republishes an incoming batch unchanged - logs it to this CEP's own
//tplog and publishes it to its subscribers (rdb - idb doesn't subscribe to
//anything, see core/idb.q's header),
//same as a real tp would. Registered alongside (not instead of)
//.spreadMod.onQuote's analytics.
//@desc
.spreadMod.relay:{[t;x]
 .u.upd[t;x];
 };

.oq.cep.addHandler[`spreadQuote;.spreadMod.onQuote;`spreadIngestQuote];
{.oq.cep.addHandler[x;.spreadMod.relay;`$"spreadRelay",string x]} each .oq.schema.tables[];
.spreadMod.info.timer.summary:.util.timer.add[.z.p+.spreadMod.summaryFreq;0Wp;.spreadMod.summaryFreq;`.spreadMod.summary;`REL;"spread widest-key summary"];
