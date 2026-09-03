//====================================================================
// Directory: modules/utils/generator/generator.q
//
// About:
// Generic random-data generator for any openQ schema file. Unlike every
// other module here, this one isn't a tp/rdb/idb/hdb/cep pipeline - it's
// a plain utility library, the same shape as modules/analytics/*/*.q,
// meant to be loaded by test scripts or run ad hoc against a live tp
// (there's no cfg_proc/modules/generator/ - nothing here is a process
// role).
//
// It's schema-BLIND by design: every schema_*.q file in this repo already
// exposes its table set via .oq.schema.tables[] (the same convention
// .oq.hdb.loadHDB/.oq.cep.init etc. rely on), and every column's actual
// type - read from meta, not guessed from its name - is enough to
// generate a plausible value for it. Adding a new schemas/schema_x.q
// table needs no change here at all; there's nothing per-schema to keep
// in sync. The tradeoff of not looking at column names is that generated
// values are type-plausible, not semantically plausible - a generated
// `cpuPct` isn't clamped to 0-100, a generated `sym` isn't a real
// currency pair or ticker - fine for exercising a pipeline's plumbing
// (does the schema round-trip through tp->rdb/idb->hdb correctly, does a
// CEP handler not blow up on the shape of a real row), not for testing
// actual business logic against realistic values.
//
// Namespaces:
//   .gen.* - per-type random value generation, per-table/per-schema row
//            generation, and a publish-into-a-tp convenience helper
//====================================================================
.gen.info.loaded:0b;

//@func   | .gen.priv.randSym
//@param  | len | -7 | symbol length
//@return | -11 | one random symbol of exactly len uppercase letters
//@desc
//Building block for .gen.priv.randSyms - separate so each row gets an
//independently random length, not just independently random letters
//@desc
.gen.priv.randSym:{[len]
 `$len?.Q.A
 };

//@func   | .gen.priv.randSyms
//@param  | n | -7 | count
//@return | 11 | n random symbols, 3-6 uppercase letters each
//@desc
//Random-looking but arbitrary symbols - no attempt to look like real
//tickers/currency pairs/log levels/etc, since the generator has no idea
//what a given symbol column actually means (see the module header)
//@desc
.gen.priv.randSyms:{[n]
 .gen.priv.randSym each 3+n?4
 };

//@func   | .gen.priv.randStr
//@return | 10 | one random 2-6 word, space-separated lowercase string
//@desc
//For an untyped/general-list column (e.g. schema_mon.q's `message`/
//`command`) - a placeholder for free text, not a real log message
//@desc
.gen.priv.randStr:{[]
 nWords:2+first 1?5;
 words:{x?.Q.a} each 3+nWords?6;
 " " sv words
 };

//@func   | .gen.priv.randStrs
//@param  | n | -7 | count
//@return | 0 | n random strings (see .gen.priv.randStr)
//@desc
//Wrapped in a 1-arg lambda so `each` actually calls .gen.priv.randStr
//fresh per element - a bare `.gen.priv.randStr[] each til n` would call
//it once (empty brackets evaluate immediately) and try to `each` over
//that single string instead
//@desc
.gen.priv.randStrs:{[n]
 {[i] .gen.priv.randStr[]} each til n
 };

//@func   | .gen.forType
//@param  | ty | -10 | a q type char, as meta's `t` column reports it
//@param  | n  | -7  | count
//@return | 0 | n random values of that type
//@desc
//The one place new column types need adding if a future schema uses one
//not already listed - every type char actually used across schemas/*.q
//today (p/n/s/f/j/i, plus the untyped/general-list " ") is covered. Numeric
//types are generated non-negative in a modest range (0-999/0-99999) since
//every numeric column in this repo's own schemas - prices, sizes, counts,
//pids, ports, memory - is naturally non-negative; a column that genuinely
//needs negative values or a different range isn't well served by this
//generic a generator and should be special-cased by its own test script
//instead of by name-matching here.
//@desc
.gen.forType:{[ty;n]
 $[ty="p"; .z.p-n?0D01:00:00.000000000;
   ty="n"; n?0D01:00:00.000000000;
   ty="d"; .z.d-n?365;
   ty="s"; .gen.priv.randSyms[n];
   ty="f"; n?1000f;
   ty="j"; n?100000;
   ty="i"; `int$n?10000;
   ty="b"; n?0b;
   ty=" "; .gen.priv.randStrs[n];
   '"generator: unsupported column type: ",string ty]
 };

//@func   | .gen.forTable
//@param  | t | 98 | an empty (or non-empty - only meta is used) table
//@param  | n | -7 | row count to generate
//@return | 98 | n randomly generated rows, one column at a time via .gen.forType
//@desc
//Reads t's column names/types from meta and builds a same-shaped table
//of random data - works against ANY unkeyed table, not just an openQ
//schema's, as long as every column's type is one .gen.forType covers
//@desc
.gen.forTable:{[t;n]
 m:0!meta t;
 flip (m`c)!.gen.forType[;n] each m`t
 };

//@func   | .gen.forSchema
//@param  | schemaFile | 10 | path to a schemas/schema_*.q file, as passed to -schema
//@param  | n          | -7 | row count to generate per table
//@return | 99 | tableName!generatedTable for every table the schema declares
//@desc
//Loads schemaFile (system "l") and generates n random rows for every
//table .oq.schema.tables[] lists - the schema-blind entry point "for all
//data found within the schema files" this module exists for. schemaFile
//is resolved the same way -schema always is (relative to the calling
//process's cwd - typically core/, so "../schemas/schema_x.q" from there,
//same as every JSON config's "schema" field)
//@desc
.gen.forSchema:{[schemaFile;n]
 system "l ",schemaFile;
 tabs:.oq.schema.tables[];
 tabs!{[n;t] .gen.forTable[value t;n]}[n] each tabs
 };

//@func   | .gen.publish
//@param  | tpAddr     | -11 | `:host:port of a tickerplant already running that schema
//@param  | schemaFile | 10  | path to the schemas/schema_*.q file tpAddr was started with
//@param  | n          | -7  | row count to generate and publish per table
//@desc
//Convenience wrapper for the common case: generate .gen.forSchema's rows
//and synchronously `upd` each table into a live tp, one sync call per
//table so a rejected row (e.g. a type mismatch, if the tp's schema drifted
//from schemaFile) surfaces as an error here rather than vanishing async-
//side. Meant for interactive/test use, not a production feed handler.
//@desc
.gen.publish:{[tpAddr;schemaFile;n]
 tabs:.gen.forSchema[schemaFile;n];
 h:hopen tpAddr;
 {[h;tabs;tabName] h (`upd;tabName;tabs tabName)}[h;tabs] each key tabs;
 hclose h;
 };

//@func   | .gen.selfPublish
//@desc
//Timer callback for use INSIDE an already-running tp process - unlike
//.gen.publish (opens a handle, generates against a schema FILE), this
//generates against whatever tables are already loaded in THIS process's
//own root namespace (.oq.schema.tables[], set up by the tp's own -schema
//load before this ever fires) and calls the local `upd` directly, no IPC
//hop needed since this process already is the tp. Each table gets its own
//independently-random row count (1-5) per tick rather than a fixed n, so
//a multi-table schema doesn't publish in obvious lockstep. The generated
//timestamp column is overwritten to one shared "now" per tick rather than
//using .gen.forType's default (randomly up to an hour in the past) -
//data published live should carry the time it was actually published.
//@desc
.gen.selfPublish:{[]
 {[t]
   n:1+first 1?5;
   rows:.gen.forTable[value t;n];
   upd[t;update timestamp:n#.z.p from rows]
  } each .oq.schema.tables[];
 };

//@func   | .gen.startSelfTimer
//@param  | freq | -16 | how often to generate+publish, a timespan
//@desc
//Registers .gen.selfPublish as a recurring local timer - call from inside
//a tp process (after its own utils/timer.q is loaded and .util.timer.init
//has run, which every tp's boot sequence already does before loading
//"libraries" - see initFromCfg.q). Idempotent-ish: calling it twice adds
//a second timer rather than replacing the first, so don't.
//@desc
.gen.startSelfTimer:{[freq]
 .gen.info.selfTimerID:.util.timer.add[.z.p;0Wp;freq;`.gen.selfPublish;`REL;"generator self-publish"];
 .util.log.ex[`INFO;`.gen.startSelfTimer]"Self-publish timer started, every ",string freq;
 };

//Auto-activation: if this process registered a non-blank -genFreq (see
//core/config.q), start the self-publish timer automatically on load - the
//opt-in hook a tp's cfg_proc/*/tp.json enables by listing this file under
//"libraries" and setting "genFreq" under "params", the same shape
//-cepscript/-hkscript/-fhscript already use elsewhere in this repo.
//Guarded with @ rather than a plain call: generator.q loaded standalone
//(e.g. .gen.forSchema from a bare q session, as the module's own docs
//show) has no .util.start.CLP at all, and that's a normal, supported way
//to use this file, not an error.
.gen.priv.autoStartFreq:@[{.util.start.CLP[`genFreq][`val]};(::);{""}];
if[count .gen.priv.autoStartFreq;.gen.startSelfTimer["N"$.gen.priv.autoStartFreq]];

.gen.info.loaded:1b;
