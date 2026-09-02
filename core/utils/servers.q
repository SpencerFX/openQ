//====================================================================
// Directory: core/utils/servers.q
//
// About:
// Named outbound "who do I talk to" registry: keeps a handle per named peer
// connection, retrying dropped connections on a timer. This is the single
// generic server-discovery mechanism used by rdb.q (connect to TP) and
// gw.q (connect to RDB/HDB backends).
//
// Namespaces:
//   .util.servers.* - registry, (re)connect/disconnect handling, and the
//                      retry timer that keeps dropped peers coming back
//====================================================================
.util.servers.info.loaded:0b;
.util.servers.info.init:0b;

.util.servers.timeout:5000;

.util.servers.tab:([connSym:`symbol$()] name:`symbol$(); procType:`symbol$(); w:`int$(); hits:`int$(); startp:`timestamp$(); endp:`timestamp$());

//@func   | .util.servers.connCust
//@param  | conn | -11 | Connection sym
//@desc
//Extension point: overwrite this to run custom logic whenever a server (re)connects
//@desc
.util.servers.connCust:{[conn]};

//@func   | .util.servers.add
//@param  | conn | -11 | Connection sym to add
//@desc
//Registers and opens a handle to a named server connection
//@desc
.util.servers.add:{[conn]
 if[conn in exec connSym from .util.servers.tab where not null w;
    .util.log.ex[`INFO;`.util.servers.add]"Connection already present in .util.servers.tab";
    :(::)
   ];
 `.util.servers.tab upsert (conn;`;`;0Ni;0i;.z.p;0Np);
 .util.servers.conn[conn];
 };

//@func   | .util.servers.conn
//@param  | conn | -11 | Connection sym
//@desc
//(Re)connects a registered server entry
//@desc
.util.servers.conn:{[conn]
 .util.log.ex[`INFO;`.util.servers.conn]"Opening handle to ",string .util.core.obfus[conn];
 h:@[.util.ipc.hopen;
     (conn;.util.servers.timeout);
     {[conn;err].util.log.ex[`WARN;`.util.servers.conn]"Failed to open handle to ",(string .util.core.obfus[conn])," with: ",err;0Ni}[conn]
    ];
 if[not null h;
    .util.log.ex[`INFO;`.util.servers.conn]"Opened handle to ",(string .util.core.obfus[conn])," on: ",string h;
    update w:h,hits:hits+1i,startp:.z.p from `.util.servers.tab where connSym=conn;
    info:@[h;".util.conn.identify[]";{[e] (`;`)}];
    if[2=count info;update name:info[0],procType:info[1] from `.util.servers.tab where connSym=conn];
   ];
 .util.servers.connCust[conn];
 };

//@func   | .util.servers.retry
//@desc
//Attempts to (re)connect any registered server without an open handle
//@desc
.util.servers.retry:{[]
 {.Q.trp[.util.servers.conn;x;.util.servers.errTrap[x]]} each exec connSym from .util.servers.tab where null w;
 };

//@func   | .util.servers.errTrap
//@param  | connSym | -11 | Connection which failed
//@param  | e       | 0   | Error signal
//@param  | bt      | 0   | Backtrace
//@desc
//Logs a failed retry attempt
//@desc
.util.servers.errTrap:{[connSym;e;bt]
 .util.log.ex[`ERROR;`.util.servers.errTrap]"Failed to retry connection to ",(string .util.core.obfus[connSym])," with: ",e;
 };

//@func   | .util.servers.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle which closed
//@desc
//Marks a server entry disconnected when its handle closes
//@desc
.util.servers.ZPC:{[zpc;W]
 update w:0Ni,endp:.z.p from `.util.servers.tab where w=W;
 zpc[W]
 };

//@func   | .util.servers.init
//@desc
//Wires the disconnect handler and starts the 30s reconnect-retry timer
//@desc
.util.servers.init:{[]
 if[.util.servers.info.init;:(::)];
 .util.servers.zpcID:.util.handlers.add[`.z.pc;`.util.servers.ZPC];
 .util.servers.timerID:.util.timer.add[.z.p;0Wp;0D00:00:30;`.util.servers.retry;`DEF;".util.servers.retry"];
 .util.servers.info.init:1b;
 };

//@func   | .util.servers.remove
//@param  | conn | -11 | Connection sym to remove
//@desc
//Removes a server entry, flushing and closing its handle if open
//@desc
.util.servers.remove:{[conn]
 if[not conn in key .util.servers.tab;:(::)];
 W:first exec w from .util.servers.tab where connSym=conn;
 delete from `.util.servers.tab where connSym=conn;
 if[not null W;
    @[.util.ipc.flush;W;{.util.log.ex[`ERROR;`.util.servers.remove]"Failed to flush handle with ",x}];
    @[hclose;W;{.util.log.ex[`ERROR;`.util.servers.remove]"Failed to close handle with ",x}]
   ];
 };

.util.servers.info.loaded:1b;
