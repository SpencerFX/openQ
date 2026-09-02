//====================================================================
// 06_replay_tplog.q
//
// Generic tplog replay: declares a schema's tables (empty, matching
// core/tp.q's own convention that a fresh table must exist before the
// first tick arrives), sets up the standard tick.q replay handler
// (upd:insert - the same convention core/tp.q's own log format and
// core/cep.q's .oq.cep.replayMissedTicks replay against), replays a
// log file into memory via -11!, then opens a listening port and stays
// up - so the resulting in-memory table(s) are queryable like any
// other openQ process. In particular, any process holding a table is
// automatically picked up by openDash's generic /api/tables browser
// (gateway/src/tables.js's SURVEY runs `tables[]` against whatever a
// process happens to hold) - no dashboard code changes needed, just
// adding this process's address to OPENQ_TABLE_SOURCES.
//
// A tplog file is a sequence of serialized (`upd;table;data) messages -
// -11! replays each one by resolving its first element (upd) as a
// function and applying the rest as its argument list, exactly the
// same mechanism core/tp.q writes with (.u.l) and core/cep.q replays
// missed segments with.
//
// Run from the repo root:
//   q examples/scripts/06_replay_tplog.q -log <path> -schema <path> -port <port> -name <name>
// e.g., to replay a day of fx_m1_massive bars and serve it on 5090:
//   q examples/scripts/06_replay_tplog.q \
//     -log C:/tmp/fx_m1_massive_2025.12.30.log \
//     -schema schemas/schema_efx_bars.q -port 5090 -name efxReplay
//====================================================================

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

logFile:  `$":",opt[args;`log;""];
schema:   opt[args;`schema;"schemas/schema_efx_bars.q"];
port:     "J"$opt[args;`port;"5090"];
procName: `$opt[args;`name;"tplogReplay"];

if[0=count 1_string logFile;'"usage: -log <path> required"];

// a minimal stand-in for what core/config.q's real CLI-parsing framework
// would normally populate - just enough for anything that introspects a
// running openQ process's own -name/-procType (e.g. openDash's /api/tables
// survey, gateway/src/tables.js) to get a sane answer, without pulling in
// the framework itself for this small standalone tool
.util.start.CLP:([name:`name`procType] val:(procName;`rdb));

system "l ",schema; / plain system"l" - this standalone tool has no other core/utils dependency

// standard tick.q replay convention: upd resolves each logged message's
// table name to the matching global and inserts the batch as-is
upd:insert;

-1 "Replaying ",(string logFile)," ...";
-11! logFile;

{[t] -1 (string t)," : ",(string count value t)," row(s)"} each .oq.schema.tables[];

system "p ",string port;
-1 "Serving on port ",(string port)," - Ctrl+C to stop.";
