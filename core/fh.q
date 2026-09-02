//====================================================================
// Directory: core/fh.q
//
// About:
// Generic feed handler process: the one piece every vendor feed handler
// needs regardless of upstream protocol (WebSocket, REST poll, FIX, ...) -
// a connection out to the tickerplant it republishes into, with logging,
// reconnect-on-drop, and a batching publish helper (.oq.fh.publish) that
// turns same-shaped row dicts into one table and republishes it via `upd,
// exactly like tests/publish.q does for synthetic data. No vendor-specific
// connect/parse/auth logic lives here - deployments supply that via
// -fhscript (see modules/ingest/massive/fh.q for an example), loaded
// during .init before the CLI/JSON params it registers (e.g. wsurl,
// apikey) are re-resolved, so a vendor script's own -util.start.add calls
// take effect just like config.q's do.
//
// Namespaces:
//   .oq.fh.* - tickerplant connect/reconnect, batching publish helper,
//              and .init - the full startup sequence
//====================================================================
.oq.info.fh.loaded:0b;

//Handle to the tickerplant this feed handler republishes into
.oq.fh.tpHandle:0Ni;

//@func   | .oq.fh.connect
//@desc
//Opens (or reopens) the handle to the tickerplant this feed handler publishes into
//@desc
.oq.fh.connect:{[]
 .oq.fh.tpHandle:@[.util.ipc.hopen;(`$.util.start.CLP[`tpaddr][`val];5000);{[e].util.log.ex[`ERROR;`.oq.fh.connect]"Failed to connect to tickerplant: ",e;0Ni}];
 };

//@func   | .oq.fh.publish
//@param  | tab  | -11 | openQ table name to publish into
//@param  | rows | 99  | List of row dicts, all with the same keys
//@desc
//Batches same-shaped rows into one table and republishes it to the tickerplant
//@desc
.oq.fh.publish:{[tab;rows]
 if[0=count rows;:(::)];
 data:flip (key first rows)!flip value each rows;
 @[.util.ipc.async[.oq.fh.tpHandle];(`upd;tab;data);{[tab;e].util.log.ex[`ERROR;`.oq.fh.publish]"Failed to publish ",(string tab)," to tickerplant: ",e}[tab]];
 };

//@func   | .oq.fh.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//If the tickerplant connection drops, note it and let the reconnect timer pick it back up
//@desc
.oq.fh.ZPC:{[zpc;W]
 if[W=.oq.fh.tpHandle;
    .util.log.ex[`WARN;`.oq.fh.ZPC]"Lost connection to tickerplant";
    .oq.fh.tpHandle:0Ni;
   ];
 zpc[W]
 };

//@func   | .oq.fh.reconnectIfNeeded
//@desc
//Timer callback: reopens the tickerplant connection if the last one dropped
//@desc
.oq.fh.reconnectIfNeeded:{[]
 if[null .oq.fh.tpHandle;.oq.fh.connect[]];
 };

.oq.fh.info.handlers.zpc:.util.handlers.add[`.z.pc;`.oq.fh.ZPC];
.oq.fh.info.timer.reconnect:.util.timer.add[.z.p;0Wp;0D00:00:30;`.oq.fh.reconnectIfNeeded;`DEF;"fh reconnect to tickerplant"];

//@func   | .oq.fh.init
//@desc
//Full startup sequence for a fh process: loads the deployment-supplied
//-fhscript (if any), which registers whatever vendor-specific CLI params
//and connect/parse/auth logic it needs; re-runs .util.start.refresh so
//those newly-registered params (e.g. wsurl, apikey - unknowable to this
//generic file) get resolved from the CLI/JSON the same as any built-in
//one; connects to the tickerplant this feed handler publishes into; then,
//if the -fhscript defined a .oq.fh.connectUpstream hook, calls it to kick
//off the actual upstream connection. Reads its own params from
//.util.start.CLP so callers (init.q/initFromCfg.q) don't need to know
//which CLI params a fh needs.
//@desc
.oq.fh.init:{[]
 fhscript:.util.start.CLP[`fhscript][`val];
 if[count fhscript;.util.core.loadScript[fhscript]];
 .util.start.refresh[];
 .oq.fh.connect[];
 upstreamConnect:@[get;`.oq.fh.connectUpstream;{::}];
 if[100h~type upstreamConnect;upstreamConnect[]];
 .util.log.ex[`INFO;`.oq.fh.init]"Feed handler started: ",string .util.start.CLP[`name][`val];
 };

.oq.info.fh.loaded:1b;
