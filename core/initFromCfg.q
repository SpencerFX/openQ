//====================================================================
// Directory: core/initFromCfg.q
//
// About:
// Config-driven bootstrap, an alternative to init.q's procType if-chain.
// Reads a JSON file (see cfg_proc/) instead of a long CLI flag list. Run as:
//   q initFromCfg.q -config ../cfg_proc/<role>.json
//
// A CLI flag with the same name as a JSON key still wins - e.g.
// `-config ../cfg_proc/rdb.json -port 5099` starts rdb on 5099 even though
// the JSON says 5011 - the JSON only fills in values the command line
// didn't already provide (see .oq.cfg.merge).
//
// `schema`/`utilities`/`libraries` are read straight off the parsed JSON
// and used once, right here, to drive `system "l"` - they never go through
// .util.start.CLP the way tpaddr/hdbroot/etc. do, since nothing reads them
// again after startup. Everything else in the JSON (procType, name, port,
// and every key under "params") IS merged into .util.start.params, so role
// code below reads it exactly the way init.q's does:
// .util.start.CLP[key][`val] - unchanged from today.
//
// Doesn't touch init.q or any shared utils/*.q file - both bootstrap paths
// work side by side. Each role's actual startup wiring lives in the
// role's own file now (tp.q's .oq.tp.init, rdb.q's .oq.rdb.init, ...), so
// the dispatch below - same as init.q's - only needs to know which files
// to load and which .init[] to call, not how any role actually starts.
//
// Namespaces:
//   .oq.cfg.*   - JSON load/parse and the CLI-params merge (this file's
//                 only new code; everything after it is the same
//                 dispatch-then-.init[] shape init.q uses)
//====================================================================
system "l utils/log.q";
system "l utils/start.q";
system "l utils/core.q";
system "l config.q";

.util.start.add[`config;1b;"*";1b;1b;""];

//@func   | .oq.cfg.load
//@param  | path | -11 | path to a JSON config file (see cfg_proc/)
//@return | 99 | the parsed config, as a dict
//@desc
//Reads and parses one process's JSON config file
//@desc
.oq.cfg.load:{[path]
 .j.k "\n" sv read0 path
 };

//@func   | .oq.cfg.strOf
//@param  | v | 0 | any value out of a parsed JSON dict
//@return | 10 | v as a plain string
//@desc
//.j.k gives back real strings for JSON strings (type 10h) - `string` on
//one of those is NOT a no-op, it maps `string` over every character
//instead (string"tp" -> (,"t";,"p")), silently wrong for this purpose.
//Short JSON strings can also come back as a bare char atom (-10h) rather
//than a one-element char vector. Route around both: strings/char-atoms
//pass through as-is (enlisted if an atom), everything else goes through
//the normal `string` cast.
//@desc
.oq.cfg.strOf:{[v]
 $[10h~type v;v;
   -10h~type v;enlist v;
   string v]
 };

//@func   | .oq.cfg.merge
//@param  | cfg | 99 | parsed JSON config (.oq.cfg.load's return)
//@desc
//Injects the JSON's scalar fields (procType/name/port and everything
//under "params") into .util.start.params as if passed on the command
//line - upsert only into keys not already present, so an actual CLI flag
//with the same name is left untouched and wins over the JSON
//@desc
.oq.cfg.merge:{[cfg]
 scalars:(`procType`name`port) inter key cfg;
 flat:(scalars#cfg),cfg`params;
 {[k;v] if[not k in key .util.start.params;.util.start.params[k]:enlist .oq.cfg.strOf v]}'[key flat;value flat];
 };

configPath:first .util.start.params[`config];
if[0=count configPath;.util.log.exSig[`ERROR;`IC_E001]"No -config given - usage: q initFromCfg.q -config ../cfg_proc/<role>.json"];
cfg:.oq.cfg.load `$configPath;
.oq.cfg.merge cfg;

.util.start.refresh[];
.util.log.setLogLevel .util.start.CLP[`logLevel][`val];
.util.start.resolveInstancePort[];
if[0<.util.start.CLP[`port][`val];system "p ",string .util.start.CLP[`port][`val]];

{system "l ",x} each cfg`utilities;
.util.timer.init[];
.util.conn.init[];

// central logging: forward this process's own log lines to the mon tp's
// `logs table (utils/logToTab.q). Skipped when -logtabaddr is empty, when
// it resolves to this very process, or when this process belongs to the
// mon module itself (any schema_mon proc) - a process on the pipeline that
// carries the `logs stream must not also publish into it (feedback loop),
// and the mon hdb/gw's own per-query logging would just be noise.
lta:.util.start.CLP[`logtabaddr][`val];
ltSelf:(string .util.start.CLP[`port][`val]) ~ last ":" vs lta;
ltMon:($[`schema in key cfg;.oq.cfg.strOf cfg`schema;""]) like "*schema_mon*";
if[(0<count lta) and not (ltSelf or ltMon);
   // trapped: central logging is a nice-to-have, and a config that omits a
   // util logToTab.q needs (utils/ipc.q) must not take the whole process
   // down over it.
   @[{[lta] system "l utils/logToTab.q"; .util.logToTab.connect `$lta;
      .util.log.ex[`INFO;`IC_LOGTAB]"central logging -> ",lta," (",$[null .util.logToTab.monHandle;"pending, 30s retry";"connected"],")"};
     lta;
     {[e].util.log.ex[`WARN;`IC_LOGTAB]"central logging not enabled: ",e}]
  ];

schemaPath:$[`schema in key cfg;cfg`schema;""];
if[count schemaPath;system "l ",schemaPath];
{system "l ",x} each cfg`libraries;

// Every role's startup wiring now lives in the role's own file (tp.q's
// .oq.tp.init, rdb.q's .oq.rdb.init, ...) - this dispatch only needs to
// know which one to call, the same simplification init.q got.
procType:.util.start.CLP[`procType][`val];

if[procType=`tp;.oq.tp.init[]];
if[procType=`rdb;.oq.rdb.init[]];
if[procType=`hdb;.oq.hdb.init[]];
if[procType=`gw;.oq.gw.init[]];
if[procType=`cep;.oq.cep.init[]];
if[procType=`idb;.oq.idb.init[]];
if[procType=`housekeeping;.oq.hk.init[]];
if[procType=`fh;.oq.fh.init[]];
if[procType=`eod;.oq.eod.init[]];
