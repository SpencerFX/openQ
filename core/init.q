//====================================================================
// Directory: core/init.q
//
// About:
// Single bootstrap script for every process role. Run as:
//   q init.q -procType tp|rdb|hdb|gw|cep|idb|housekeeping|fh|eod -name <name> -port <port> [role-specific params]
// Loads the shared utility layer, then loads the scripts each role needs
// and calls that role's own .init[] (defined in the role's own file -
// tp.q's .oq.tp.init, rdb.q's .oq.rdb.init, and so on) to do the actual
// startup wiring. init.q itself only knows WHICH files a role needs, never
// HOW to start one - that keeps this file from growing every time a
// role's own startup sequence changes, and keeps init.q and
// initFromCfg.q from duplicating that sequence between them.
//
// Namespaces:
//   (none of its own - loads utils/*.q and config.q, then dispatches by
//   -procType to each role's own .init[])
//====================================================================
system "l utils/log.q";
system "l utils/timer.q";
system "l utils/handlers.q";
system "l utils/start.q";
system "l utils/core.q";
system "l utils/conn.q";
system "l utils/ipc.q";
system "l utils/servers.q";
system "l utils/perm.q";
system "l config.q";
.util.start.refresh[];
.util.log.setLogLevel .util.start.CLP[`logLevel][`val];
.util.start.resolveInstancePort[];

if[0<.util.start.CLP[`port][`val];system "p ",string .util.start.CLP[`port][`val]];

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
ltMon:.util.start.CLP[`schema][`val] like "*schema_mon*";
if[(0<count lta) and not (ltSelf or ltMon);
   // trapped: central logging must never take the process down (e.g. a
   // deployment that loads utils/logToTab.q without its utils/ipc.q dep).
   @[{[lta] system "l utils/logToTab.q"; .util.logToTab.connect `$lta;
      .util.log.ex[`INFO;`LOG_TAB]"central logging -> ",lta," (",$[null .util.logToTab.monHandle;"pending, 30s retry";"connected"],")"};
     lta;
     {[e].util.log.ex[`WARN;`LOG_TAB]"central logging not enabled: ",e}]
  ];

procType:.util.start.CLP[`procType][`val];

if[procType=`tp;
   system "l ",.util.start.CLP[`schema][`val];
   system "l tp.q";
   .oq.tp.init[];
  ];

if[procType=`rdb;
   system "l ",.util.start.CLP[`schema][`val];
   system "l rdb.q";
   system "l utils/gateway.q";
   system "l query.q";
   system "l save.q";
   .oq.rdb.init[];
  ];

if[procType=`hdb;
   schema:.util.start.CLP[`schema][`val];
   if[count schema;system "l ",schema];
   system "l hdb.q";
   system "l utils/gateway.q";
   system "l query.q";
   .oq.hdb.init[];
  ];

if[procType=`gw;
   system "l utils/gateway.q";
   system "l query.q";
   system "l gw.q";
   .oq.gw.init[];
  ];

if[procType=`cep;
   system "l tp.q";
   system "l cep.q";
   .oq.cep.init[];
  ];

if[procType=`idb;
   system "l ",.util.start.CLP[`schema][`val];
   system "l save.q";
   system "l idb.q";
   .oq.idb.init[];
  ];

if[procType=`housekeeping;
   system "l housekeeping.q";
   .oq.hk.init[];
  ];

if[procType=`fh;
   system "l fh.q";
   .oq.fh.init[];
  ];

if[procType=`eod;
   system "l ",.util.start.CLP[`schema][`val];
   system "l save.q";
   system "l eod.q";
   .oq.eod.init[];
  ];
