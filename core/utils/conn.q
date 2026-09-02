//====================================================================
// Directory: core/utils/conn.q
//
// About:
// Passive connection tracking: every inbound+outbound handle for this
// process, hooked automatically via .z.po/.z.pc/.z.ps/.z.pg so there's
// always a live "who's connected" table for observability.
//
// Namespaces:
//   .util.conn.* - the tracking table and its .z.p*-hooked upkeep
//====================================================================
.util.conn.info.loaded:0b;
.util.conn.info.init:0b;

.util.conn.tab:([w:`int$()] host:`symbol$(); pid:`int$(); port:`int$(); name:`symbol$(); procType:`symbol$();
                 startp:`timestamp$(); endp:`timestamp$(); lastp:`timestamp$(); hits:`int$(); errs:`int$(); send:`long$(); receive:`long$());

//@func   | .util.conn.upsert
//@param  | W | -6 | Handle being added
//@desc
//Add a basic row for a newly opened handle
//@desc
.util.conn.upsert:{[W]
 `.util.conn.tab upsert (W;.z.h;0Ni;0Ni;`;`;zp;0Np;zp:.z.p;0i;0i;0j;0j);
 };

//@func   | .util.conn.track
//@param  | handler | 100 | Handler to run (the base .z.ps/.z.pg)
//@param  | query   | 0   | Query
//@return | 0 | Result of query
//@desc
//Wraps .z.ps/.z.pg to record hit/error/byte-size stats per handle
//@desc
//@func   | .util.conn.priv.bumpErr
//@param  | querySz | -7 | Size of the query that just errored
//@desc
//Bumps .z.w's error/hit stats after a handler call failed - split out so
//.util.conn.track can run it protected. .z.w's row can legitimately
//already be gone (e.g. the caller disconnected the same instant a
//request of theirs errored), and this bookkeeping must never itself
//throw: unprotected, a bookkeeping failure here would replace the REAL
//error with a different one, or - worse, for a sync .z.pg caller - mean
//no response ever gets sent because this handler threw instead of
//returning the original error.
//@desc
.util.conn.priv.bumpErr:{[querySz]
 update lastp:.z.p,hits:hits+1i,errs:errs+1i,receive:receive+querySz from `.util.conn.tab where w=.z.w;
 };

//@func   | .util.conn.priv.bumpOk
//@param  | querySz  | -7 | Size of the query that just succeeded
//@param  | returnSz | -7 | Size of the result being sent back
//@desc
//Bumps .z.w's hit/byte stats after a successful handler call - same
//protected-bookkeeping rationale as .util.conn.priv.bumpErr.
//@desc
.util.conn.priv.bumpOk:{[querySz;returnSz]
 update lastp:.z.p,hits:hits+1i,receive:receive+querySz,send:send+returnSz from `.util.conn.tab where w=.z.w;
 };

.util.conn.track:{[handler;query]
 querySz:.util.core.minus22[query];
 res:@[handler;
       query;
       {[querySz;err] @[.util.conn.priv.bumpErr;querySz;{[e]}];'err}[querySz]
      ];
 returnSz:.util.core.minus22[res];
 .[.util.conn.priv.bumpOk;(querySz;returnSz);{[e]}];
 res
 };

//@func   | .util.conn.cleanup
//@desc
//Removes rows for handles that are no longer open
//@desc
.util.conn.cleanup:{[]
 update endp:.z.p,w:0Ni from `.util.conn.tab where not w in key .z.W,not null w;
 };

//@func   | .util.conn.ZPO
//@param  | zpo | 100 | Base .z.po
//@param  | W   | -6  | Handle being opened
//@desc
//Wraps .z.po to track new inbound connections
//@desc
.util.conn.ZPO:{[zpo;W]
 .util.conn.cleanup[];
 .util.conn.upsert[W];
 zpo[W]
 };

//@func   | .util.conn.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//Wraps .z.pc to mark a connection closed
//@desc
.util.conn.ZPC:{[zpc;W]
 update w:0Ni,endp:.z.p from `.util.conn.tab where w=W;
 .util.conn.cleanup[];
 zpc[W]
 };

//@func   | .util.conn.setInfo
//@param  | W        | -6  | Handle
//@param  | name     | -11 | Peer process name
//@param  | procType | -11 | Peer process type
//@desc
//Records the peer's declared name/procType against its handle (used by servers.q)
//@desc
.util.conn.setInfo:{[W;name;procType]
 update name:name,procType:procType from `.util.conn.tab where w=W;
 };

//@func   | .util.conn.identify
//@return | 99 | This process's own (name;procType)
//@desc
//Returns this process's own name/procType for the identify handshake
//@desc
.util.conn.identify:{[]
 (.util.start.CLP[`name][`val];.util.start.CLP[`procType][`val])
 };

//@func   | .util.conn.recvIdentify
//@param  | info | 0 | (name;procType) sent by the peer
//@desc
//Async callback: peer identifies itself on connect
//@desc
.util.conn.recvIdentify:{[info]
 .util.conn.setInfo[.z.w;info 0;info 1];
 };

//@func   | .util.conn.init
//@desc
//Wires connection tracking into .z.po/.z.pc/.z.ps/.z.pg and starts the 10s cleanup timer
//@desc
.util.conn.init:{[]
 if[.util.conn.info.init;:(::)];
 .util.conn.info.handlers.zps:.util.handlers.add[`.z.ps;`.util.conn.track];
 .util.conn.info.handlers.zpg:.util.handlers.add[`.z.pg;`.util.conn.track];
 .util.conn.info.handlers.zpo:.util.handlers.add[`.z.po;`.util.conn.ZPO];
 .util.conn.info.handlers.zpc:.util.handlers.add[`.z.pc;`.util.conn.ZPC];
 .util.conn.info.timer.cleanup:.util.timer.add[.z.p;0Wp;0D00:00:10;`.util.conn.cleanup;`DEF;".util.conn.cleanup"];
 .util.conn.info.init:1b;
 };

.util.conn.info.loaded:1b;
