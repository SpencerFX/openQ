//====================================================================
// Directory: core/config.q
//
// About:
// Minimal example process configuration: command-line parameters each
// process role needs, with sensible defaults. A real deployment would
// likely replace this with a proper process registry, but for a single
// tp/rdb/hdb/gw/cep set this flat set of params is all that's needed -
// see rdb.q's .oq.rdb.connectToTP, cep.q's .oq.cep.connectSource, and
// init.q for how they're consumed.
//
// Namespaces:
//   (none of its own - registers every role's CLI params via
//   .util.start.add)
//====================================================================
.oq.info.config.loaded:0b;

.util.start.add[`tplogdir;0b;"*";1b;1b;""];
.util.start.add[`hdbroot;0b;"*";1b;1b;"hdb"];
.util.start.add[`tpaddr;0b;"*";1b;1b;":localhost:5010"];
.util.start.add[`rdbaddr;0b;"*";1b;1b;":localhost:5011"];
.util.start.add[`rdbaddr2;0b;"*";1b;1b;""];
.util.start.add[`hdbaddr;0b;"*";1b;1b;":localhost:5012"];
.util.start.add[`eqhdbaddr;0b;"*";1b;1b;":localhost:5090"];
.util.start.add[`bmode;0b;"I";1b;1b;0i];
.util.start.add[`srcaddr;0b;"*";1b;1b;":localhost:5010"];
.util.start.add[`cepscript;0b;"*";1b;1b;""];
.util.start.add[`idbroot;0b;"*";1b;1b;"idb"];
.util.start.add[`checkpointfreq;0b;"*";1b;1b;"0D00:02:00"];
.util.start.add[`schema;0b;"*";1b;1b;"../schemas/schema.q"];
.util.start.add[`hkscript;0b;"*";1b;1b;""];
.util.start.add[`hkfreq;0b;"*";1b;1b;"0D00:01:00"];
.util.start.add[`idbaddr;0b;"*";1b;1b;""];
.util.start.add[`eodTriggerTime;0b;"*";1b;1b;"08:30:00.000"];
.util.start.add[`fhscript;0b;"*";1b;1b;""];
.util.start.add[`genFreq;0b;"*";1b;1b;""];
.util.start.add[`eodDate;0b;"*";1b;1b;""];
// mon tickerplant hosting the central `logs table (schemas/schema_mon.q).
// When set, every process loads utils/logToTab.q and forwards a copy of
// each of its own log lines there (see that file). "" disables it; the mon
// tp itself is skipped by init so it never publishes into its own feed.
.util.start.add[`logtabaddr;0b;"*";1b;1b;":localhost:5020"];

.oq.info.config.loaded:1b;
