//====================================================================
// Directory: core/utils/ipc.q
//
// About:
// Thin wrappers over hopen/sync/async that add logging, password masking,
// and register every opened handle with utils/conn.q's tracking table.
//
// Namespaces:
//   .util.ipc.* - hopen/sync/async/sendResult/flush, all logged and
//                 tracked
//====================================================================
.util.ipc.info.loaded:0b;

//@func   | .util.ipc.getConnSym
//@param  | port | -7 -11 | port of a local process, or a `:host:port(:user:pass) sym
//@return | -11 | Connection symbol suitable for hopen
//@desc
//Normalizes a port int or partial connection sym into a full `:host:port sym
//@desc
.util.ipc.getConnSym:{[port]
 .util.core.checkTypes[enlist(-7h;-11h);enlist port];
 $[-7h~type port;
   `$":localhost:",string port;
   [
    s:string port;
    if[":"~last s;s:-1_s];
    `$s
   ]
  ]
 };

//@func   | .util.ipc.hopen
//@param  | connInfo | -7 -11 0 | Port, connection sym, or (connInfo;timeout)
//@return | -6 | Handle to the process
//@desc
//Opens a handle, logs+signals on failure, and registers the handle with .util.conn.tab.
//Also exchanges a simple (name;procType) identify handshake with the peer.
//@desc
.util.ipc.hopen:{[connInfo]
 .util.core.checkTypes[enlist(-7h;7h;-11h;0h);enlist connInfo];
 conn:$[0h~type connInfo;connInfo 0;connInfo];
 conn:.util.ipc.getConnSym[conn];
 hArgs:$[0h~type connInfo;(conn;connInfo 1);conn];
 h:@[hopen;
     hArgs;
     {[conn;err].util.log.exSig[`ERROR;`.util.ipc.hopen]"Could not open connection to ",(string .util.core.obfus[conn])," with: ",err}[conn]
    ];
 .util.conn.upsert[h];
 @[{neg[x](`.util.conn.recvIdentify;.util.conn.identify[])};h;{[h;err].util.log.ex[`WARN;`.util.ipc.hopen]"Failed to send identify to handle ",string[h]," with: ",err}[h]];
 h
 };

//@func   | .util.ipc.sync
//@param  | hndl  | -6   | Handle to query
//@param  | query | 10 0 | Query to execute as string or list
//@return | 0 | Result of executing query
//@desc
//Sync call, updating .util.conn.tab stats
//@desc
.util.ipc.sync:{[hndl;query]
 querySz:.util.core.minus22[query];
 res:@[hndl;
       query;
       {[hndl;querySz;err] update lastp:.z.p,hits:hits+1i,errs:errs+1i,send:send+querySz from `.util.conn.tab where w=hndl;'err}[hndl;querySz]
      ];
 returnSz:.util.core.minus22[res];
 update lastp:.z.p,hits:hits+1i,receive:receive+returnSz,send:send+querySz from `.util.conn.tab where w=hndl;
 res
 };

//@func   | .util.ipc.async
//@param  | hndl  | -6   | Handle to query
//@param  | query | 10 0 | Query to execute as string or list
//@desc
//Async call, updating .util.conn.tab stats
//@desc
.util.ipc.async:{[hndl;query]
 querySz:.util.core.minus22[query];
 update lastp:.z.p,hits:hits+1i,send:send+querySz from `.util.conn.tab where w=hndl;
 neg[hndl] query;
 };

//@func   | .util.ipc.sendResult
//@param  | hndl | -6 | Handle to send to
//@param  | res  | 0  | Result to send
//@desc
//Sends a query result back to a waiting handle
//@desc
.util.ipc.sendResult:{[hndl;res]
 querySz:.util.core.minus22[res];
 update lastp:.z.p,hits:hits+1i,send:send+querySz from `.util.conn.tab where w=hndl;
 neg[hndl] res;
 };

//@func   | .util.ipc.flush
//@param  | hndl | -6 | Handle to flush
//@desc
//Flushes the async output queue for a handle
//@desc
.util.ipc.flush:{[hndl]
 @[neg[hndl];(::);{.util.log.ex[`ERROR;`.util.ipc.flush]"Failed to flush ",(string hndl)," with: ",x}]
 };

.util.ipc.info.loaded:1b;
