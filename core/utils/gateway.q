//====================================================================
// Directory: core/utils/gateway.q
//
// About:
// Generic async fan-out gateway engine: a client sends a query plus the
// server type(s) to run it on; the query is queued until matching backend
// handles are idle, sent to all of them in parallel, and once every
// targeted server has replied the results are joined and returned.
// No FX/domain knowledge lives here - gw.q layers routing decisions on top.
//
// Namespaces:
//   .util.gw.* - queue/scheduling, per-query result slots, backend
//                fan-out/join, timeout sweep, client/server disconnect
//                handling
//====================================================================
.util.gw.info.loaded:0b;

.util.servers.init[];

.util.gw.safeExecute:0b;
.util.gw.maxSize:0Wj;

.util.gw.ID:0;

//@func   | .util.gw.genID
//@return | -7 | A unique query ID
//@desc
//Generates a unique query ID
//@desc
.util.gw.genID:{:.util.gw.ID+:1};

//Queue of submitted queries
.util.gw.queue:([queryID:`u#`long$()] time:`timestamp$(); clientH:`g#`int$(); query:(); serverType:(); join:(); postback:(); timeout:`timespan$(); submitted:`timestamp$(); returned:`timestamp$(); took:`timespan$(); error:`boolean$(); discard:`boolean$());

//Per-query dispatch/result slots: queryID -> (clientH; slots keyed table)
//slots: ([serverType] handle;result;error;data;stack)
.util.gw.results:(`long$())!();

//Pool of backend connections available to run queries
.util.gw.servers:([handle:`int$()] serverType:`symbol$(); inuse:`boolean$(); active:`boolean$(); querycount:`int$(); lastquery:`timestamp$(); usage:`timespan$());

//@func   | .util.gw.addServer
//@param  | handle     | -6  | Handle to backend server
//@param  | serverType | -11 | Server type tag, e.g. `rdb`hdb
//@desc
//Registers a backend server in the load-balancing pool
//@desc
.util.gw.addServer:{[handle;serverType]
 `.util.gw.servers upsert (handle;serverType;0b;1b;0i;0Np;0D);
 };

//@func   | .util.gw.setState
//@param  | serverh | -6 -6h | Handle(s)
//@param  | use     | -1     | New inuse state
//@desc
//Marks server handle(s) busy/idle, tracking query count and cumulative usage time
//@desc
.util.gw.setState:{[serverh;use]
 $[use;
   update inuse:use,lastquery:.z.p,querycount+1i from `.util.gw.servers where handle in serverh;
   update inuse:use,usage:usage+.z.p-lastquery from `.util.gw.servers where handle in serverh];
 };

//@func   | .util.gw.available
//@param  | inuse | -1 | 1b to include busy servers, 0b to return only idle ones
//@return | 99 | handle!serverType dict, idle-longest-first
//@desc
//Returns available servers; used both for scheduling and load balancing across replicas
//@desc
.util.gw.available:{[inuse]
 $[inuse;
   exec handle!serverType from `inuse xasc select handle,serverType,inuse from .util.gw.servers where active;
   exec handle!serverType from .util.gw.servers where active,not inuse]
 };

//@func   | .util.gw.pendingServerTypes
//@param  | queryID | -7 | Query ID
//@return | 11 | Server types for this query not yet dispatched to a handle
//@desc
//Server types in this query's result slots which have not yet been sent to a handle
//@desc
.util.gw.pendingServerTypes:{[queryID]
 exec serverType from .util.gw.results[queryID;1] where null handle
 };

//@func   | .util.gw.canBeRun
//@return | 99 | Table of queued queries with the server type(s) to dispatch now
//@desc
//For each open query, finds pending server types that currently have idle capacity somewhere
//@desc
.util.gw.canBeRun:{[]
 avail:distinct value .util.gw.available[0b];
 open:0!select from .util.gw.queue where null returned;
 if[0=count open;:update required:(),available:() from open];
 open:update required:{$[x in key .util.gw.results;.util.gw.pendingServerTypes[x];y]}'[queryID;serverType] from open;
 open:update available:required inter\:avail from open;
 select from open where 0<count each available
 };

//@func   | .util.gw.nextQuery
//@return | 99 | Table with 0 or 1 query, now marked submitted
//@desc
//Picks the oldest runnable query and marks it submitted
//@desc
.util.gw.nextQuery:{[]
 qid:1 sublist select from .util.gw.canBeRun[] where time=min time;
 if[0=count qid;:qid];
 update submitted:.z.p^submitted from `.util.gw.queue where queryID in qid`queryID;
 qid
 };

//@func   | .util.gw.prepareQuery
//@param  | serverType | 11  | Server type(s) to query
//@param  | join       | 100 | Join function
//@param  | query      | 0   | Query
//@return | 99 | `serverType`join`query dict
//@desc
//Normalizes the (serverType;join;query) triple for the queue.
//A single-server query is wrapped so that server applies join itself (identity, since there's nothing to join)
//@desc
.util.gw.prepareQuery:{[serverType;join;query]
 if[1~count serverType:distinct serverType,();
    query:(eval;(join;(enlist;(`.q.value;enlist query))));
    join:first];
 `serverType`join`query!(serverType;join;query)
 };

//@func   | .util.gw.addQueryTimeout
//@param  | time       | -12 | Submission time
//@param  | clientH    | -6  | Handle of caller
//@param  | query      | 0   | Query
//@param  | serverType | 11  | Server type(s)
//@param  | join       | 100 | Join
//@param  | postback   | 100 | Postback, () for none
//@param  | timeout    | -16 | Timeout, 0Wn for none
//@desc
//Queues a query to run
//@desc
.util.gw.addQueryTimeout:{[time;clientH;query;serverType;join;postback;timeout]
 prep:.util.gw.prepareQuery[serverType;join;query];
 `.util.gw.queue upsert (.util.gw.genID[];time;clientH;prep`query;prep`serverType;prep`join;postback;timeout;0Np;0Np;0D;0b;0b);
 };

//@func   | .util.gw.removeClient
//@param  | handle | -6 | Handle of disconnected client
//@desc
//Marks in-flight queries from a disconnected client as discarded
//@desc
.util.gw.removeClient:{[handle]
 .util.log.ex[`INFO;`.util.gw.removeClient]"Removing client: ",string handle;
 update discard:1b from `.util.gw.queue where clientH=handle,null returned;
 };

//@func   | .util.gw.finishQuery
//@param  | qid | -7 -7h | Query ID(s)
//@param  | err | -1     | Did the query error
//@desc
//Records completion stats and frees the query's result cache
//@desc
.util.gw.finishQuery:{[qid;err]
 now:.z.p;
 update error:err,returned:now,took:now-submitted from `.util.gw.queue where queryID in qid;
 .util.gw.results:((),qid) _ .util.gw.results;
 };

//@func   | .util.gw.addEmptyResult
//@param  | queryID     | -7 | Query ID
//@param  | clientH     | -6 | Client handle
//@param  | serverTypes | 11 | Full server type(s) required for this query
//@desc
//Seeds the per-query result slots (one row per required server type) before any are dispatched
//@desc
.util.gw.addEmptyResult:{[queryID;clientH;serverTypes]
 serverTypes:distinct serverTypes,();
 n:count serverTypes;
 slots:([serverType:serverTypes] handle:n#0Ni; result:n#0b; error:n#0b; data:n#enlist(::); stack:n#enlist(::));
 .util.gw.results[queryID]:(clientH;slots);
 };

//@func   | .util.gw.addServerToQuery
//@param  | queryID     | -7 | Query ID
//@param  | serverTypes | 11 | Server type(s) being dispatched this round
//@param  | handles     | -6h| Handle(s) chosen, parallel to serverTypes
//@desc
//Records which handle is answering which server-type slot for a query
//@desc
.util.gw.addServerToQuery:{[queryID;serverTypes;handles]
 m:serverTypes!handles;
 slots:.util.gw.results[queryID;1];
 slots:update handle:m serverType from slots where serverType in serverTypes;
 .util.gw.results[queryID;1]:slots;
 };

//@func   | .util.gw.addServerResult
//@param  | queryID | -7 | Query ID
//@param  | srvRes  | 99 | `result`error`data`stack dict from serverExecute
//@desc
//Records a successful backend reply, frees the server, and schedules more work.
//NOTE: the param is deliberately not named `result` - the slots table has its own
//`result` column, and update/exec clauses bind column names into scope, silently
//shadowing an outer variable of the same name.
//@desc
.util.gw.addServerResult:{[queryID;srvRes]
 if[queryID in key .util.gw.results;
    slots:update result:srvRes`result,error:srvRes`error,data:enlist srvRes`data,stack:enlist srvRes`stack from .util.gw.results[queryID;1] where handle=.z.w;
    .util.gw.results[queryID;1]:slots;
   ];
 .util.gw.setState[.z.w;0b];
 .util.gw.runNextQuery[];
 .util.gw.checkResults[queryID];
 };

//@func   | .util.gw.addServerError
//@param  | queryID | -7 | Query ID
//@param  | srvRes  | 99 | `result`error`data`stack dict, error=1b
//@desc
//A backend errored: reply to the client immediately with the error
//@desc
.util.gw.addServerError:{[queryID;srvRes]
 if[queryID in key .util.gw.results;.util.gw.sendReply[queryID;`error`data`stack!(srvRes`error;srvRes`data;srvRes`stack)]];
 .util.gw.setState[.z.w;0b];
 .util.gw.runNextQuery[];
 .util.gw.finishQuery[queryID;1b];
 };

//@func   | .util.gw.checkResults
//@param  | queryID | -7 | Query ID
//@desc
//If every server targeted for this query has now replied, join the results and reply to the client
//@desc
.util.gw.checkResults:{[queryID]
 slots:.util.gw.results[queryID;1];
 if[all exec result from slots;
    querydetails:.util.gw.queue[queryID];
    res:`error`data`stack!.perm.readOnlyTrp (querydetails[`join];exec data from slots);
    if[res[`error];res[`data]:"Failed to apply join function to result sets: ",res[`data]];
    .util.gw.sendReply[queryID;res];
    .util.gw.finishQuery[queryID;res[`error]]
   ];
 };

//@func   | .util.gw.sendReply
//@param  | qID    | -7 | Query ID
//@param  | result | 99 | `error`data`stack dict
//@desc
//Sends the final (possibly postback-transformed) result to the client
//@desc
.util.gw.sendReply:{[qID;result]
 querydetails:.util.gw.queue[qID];
 result[`queryID]:qID;
 tosend:$[()~querydetails[`postback];result;(querydetails[`postback];result)];
 if[not querydetails`discard;
    @[.util.ipc.sendResult[querydetails`clientH];tosend;{[e].util.log.ex[`WARN;`.util.gw.sendReply]"Failed to send reply to client: ",e}]
   ];
 .util.log.ex[`INFO;`.util.gw.sendReply]"Sent reply with queryID: ",string qID;
 };

//@func   | .util.gw.serverExecute
//@param  | queryID     | -7 | Query ID
//@param  | query       | 0  | Query to run
//@param  | maxSize     | -7 | Allowed max result size
//@param  | safeExecute | -1 | Enforce maxSize
//@desc
//Runs on the backend (RDB/HDB): executes the query read-only-trapped and calls back the gateway async
//@desc
.util.gw.serverExecute:{[queryID;query;maxSize;safeExecute]
 .util.log.ex[`INFO;`.util.gw.serverExecute]"Running gateway query, queryID: ",string queryID;
 res:`result`error`data`stack!(enlist 1b),.perm.readOnlyTrp query;
 if[res[`error];res[`data]:"Failed to run query on server ",(string .z.h),":",(string system"p"),": ",res[`data]];
 if[safeExecute and not res`error;
    if[maxSize<rs:.util.core.minus22[res[`data]];
       res[`error]:1b;
       res[`data]:"Returned result exceeds maxSize (",(string maxSize),"B): ",string rs]
   ];
 @[.util.ipc.async[.z.w];($[res[`error];`.util.gw.addServerError;`.util.gw.addServerResult];queryID;res);{[e] .util.log.ex[`ERROR;`.util.gw.serverExecute]"Failed to callback gateway: ",e}];
 };

//@func   | .util.gw.sendQuery
//@param  | queryID | -7 | Query ID
//@param  | query   | 0  | Query to send
//@param  | serverh | -6h| Handle(s) to send to
//@desc
//Sends the same query async to every chosen server handle in parallel
//@desc
.util.gw.sendQuery:{[queryID;query;serverh]
 (.util.ipc.async @/: serverh,:())@\:(.util.gw.serverExecute;queryID;query;.util.gw.maxSize;.util.gw.safeExecute);
 .util.gw.setState[serverh;1b];
 .util.log.ex[`INFO;`.util.gw.sendQuery]"Sent query, queryID: ",string queryID;
 };

//@func   | .util.gw.removeServer
//@param  | serverh | -6 | Handle that disconnected
//@desc
//Errors out any in-flight queries waiting on a server that just disconnected
//@desc
.util.gw.removeServer:{[serverh]
 if[null first exec serverType from .util.gw.servers where handle=serverh;:(::)];
 qids:(key .util.gw.results) where {[serverh;qid] any exec (handle=serverh)&not result from .util.gw.results[qid;1]}[serverh] each key .util.gw.results;
 if[0<count qids;
    {.util.gw.sendReply[x;`error`data`stack!(1b;"Backend server closed the connection";"")]} each qids;
    .util.gw.finishQuery[qids;1b];
   ];
 update active:0b from `.util.gw.servers where handle=serverh;
 .util.gw.runNextQuery[];
 };

//@func   | .util.gw.checkTimeout
//@desc
//Timer callback (every 5s): errors out any queries that have exceeded their timeout
//@desc
.util.gw.checkTimeout:{[]
 qids:exec queryID from .util.gw.queue where not timeout=0Wn,.z.p>time+timeout,null returned;
 if[count qids;
    {.util.gw.sendReply[x;`error`data`stack!(1b;"Query exceeded specified timeout";"")]} each qids;
    .util.gw.finishQuery[qids;1b];
   ];
 };

//@func   | .util.gw.join
//@param  | results | 0 | List of per-server result values
//@return | 0 | Concatenation of results, or the single result if only one
//@desc
//Default join: append results from each server into one table (e.g. HDB history + RDB intraday)
//@desc
.util.gw.join:{[results]
 $[1<count results;{x,y} over results;first results]
 };

//@func   | .util.gw.checkMissingServers
//@param  | serverType | 11 | Server type(s) required
//@return | -1 | 1b if any required server type has zero active connections
//@desc
//Used to reject a query up front rather than let it queue forever
//@desc
.util.gw.checkMissingServers:{[serverType]
 0<count (distinct serverType,()) except exec distinct serverType from .util.gw.servers where active
 };

//@func   | .util.gw.asyncExecJPT
//@param  | query      | 0   | Query to run
//@param  | serverType | 11  | Server type(s) to query
//@param  | join       | 100 | Join function, `.util.gw.join for default
//@param  | postback   | 100 | Postback function, () for none
//@param  | timeout    | -16 | Timeout, 0Wn for none
//@desc
//Client entry point (called as an async message on the gateway): validates and queues the query
//@desc
.util.gw.asyncExecJPT:{[query;serverType;join;postback;timeout]
 if[`~join;join:`.util.gw.join];
 if[`~postback;postback:()];
 if[`~timeout;timeout:0Wn];
 if[11h~type serverType;serverType:distinct serverType];
 if[.util.gw.checkMissingServers[serverType];
    @[.util.ipc.sendResult[.z.w];`error`data`stack`queryID!(1b;"Not all requested server types are available";"";0Nj);{[e]}];
    :(::)
   ];
 .util.gw.addQueryTimeout[.z.p;.z.w;query;serverType;join;postback;timeout];
 .util.gw.runNextQuery[];
 };

//@func   | .util.gw.asyncExec
//@param  | query      | 0  | Query to run
//@param  | serverType | 11 | Server type(s) to query
//@desc
//Client entry point with default join/postback/timeout
//@desc
.util.gw.asyncExec:.util.gw.asyncExecJPT[;;`.util.gw.join;();0Wn];

//@func   | .util.gw.runNextQuery
//@desc
//Runs the next runnable query in the queue, if any, against available server(s)
//@desc
.util.gw.runNextQuery:{[]
 if[count torun:.util.gw.nextQuery[];
    torun:first torun;
    if[not torun[`queryID] in key .util.gw.results;
       .util.gw.addEmptyResult[torun`queryID;torun`clientH;torun`serverType]
      ];
    handles:.util.gw.available[1b]?torun`available;
    .util.gw.addServerToQuery[torun`queryID;torun`available;handles];
    .util.gw.sendQuery[torun`queryID;torun`query;handles];
   ];
 };

//@func   | .util.gw.ZPC
//@param  | zpc | 100 | Base .z.pc
//@param  | W   | -6  | Handle being closed
//@desc
//On disconnect, clean up both client and server bookkeeping for the closed handle
//@desc
.util.gw.ZPC:{[zpc;W]
 .util.gw.removeClient[W];
 .util.gw.removeServer[W];
 zpc[W]
 };

//@func   | .util.gw.ZPS
//@param  | zps   | 100 | Base .z.ps
//@param  | query | 0   | Query
//@desc
//If an async query fails, send an error object back to the caller instead of dying silently
//@desc
.util.gw.ZPS:{[zps;query]
 .Q.trp[zps;query;{[err;bt] .util.log.ex[`ERROR;`.util.gw.ZPS]"Async handler error: ",err,"\n",.Q.sbt bt; @[.util.ipc.sendResult[.z.w];`error`data`stack`queryID!(1b;err;"";0Nj);{[e]}]}]
 };

.util.gw.info.handlers.zpc:.util.handlers.add[`.z.pc;`.util.gw.ZPC];
.util.gw.info.handlers.zps:.util.handlers.add[`.z.ps;`.util.gw.ZPS];

.util.servers.connCust:{[conn]
 row:exec from .util.servers.tab where connSym=conn;
 if[not null first row`w;.util.gw.addServer[first row`w;first row`procType]];
 };

.util.gw.info.timer.checkTimeout:.util.timer.add[.z.p;0Wp;0D00:00:05;`.util.gw.checkTimeout;`DEF;".util.gw.checkTimeout"];

.util.gw.info.loaded:1b;
