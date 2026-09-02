//====================================================================
// Directory: core/utils/handlers.q
//
// About:
// Composable .z.p* hook chaining: lets independent subsystems (connections,
// servers, auth, ...) each attach logic to a single kdb+ callback (.z.pg,
// .z.po, .z.pc, ...) without stepping on each other or on user overrides.
//
// Namespaces:
//   .util.handlers.* - hook registration/chaining and the dispatcher
//                       installed as each .z.p* callback
//====================================================================
.util.handlers.info.loaded:0b;

//Default versions of handlers as defined by kx
.util.handlers.default:(`.z.pg`.z.ps`.z.pw`.z.ts`.z.po`.z.pc`.z.ws)!({value x};{value x};{[x;y] 1b};{1b};{;};{;};{neg[.z.w][x];});

//Holds the core (innermost) logic of each handler
.util.handlers.base:()!();

.util.handlers.id:0;

//Set to 1b to wrap handler execution in .Q.trp
.util.handlers.trap:0b;

//Registered wrapper functions per handler
.util.handlers.tab:([]id:`long$();handlerName:`symbol$();func:());

//@func   | .util.handlers.setBase
//@param  | handlers | 11 | handler(s) to save
//@param  | values   | 0  | value(s) to save
//@desc
//Adds or updates values in .util.handlers.base
//@desc
.util.handlers.setBase:{[handlers;values]
 .util.handlers.base:.util.handlers.base,((),handlers)!(),values;
 };

//@func   | .util.handlers.handlerOrDefault
//@param  | handler | -11 | handler to get value of
//@return | 0 | Current value if defined, else the kx default
//@desc
//Gets value of handler if defined or default value from .util.handlers.default if not
//@desc
.util.handlers.handlerOrDefault:{[handler]
 @[get;handler;{[handler;ignore] .util.handlers.default[handler]}[handler]]
 };

//@func   | .util.handlers.setBaseAuto
//@param  | handlers | 11 | handler(s) to save
//@desc
//Seeds .util.handlers.base from the handler's current value (or kx default if unset)
//@desc
.util.handlers.setBaseAuto:{[handlers]
 .util.handlers.setBase[(),handlers;.util.handlers.handlerOrDefault each (),handlers];
 };

//@func   | .util.handlers.run
//@param  | handler | -11 | handler to run
//@param  | params  | 0   | parameters being passed
//@return | 0 | Output of handler
//@desc
//Folds all registered wrapper functions (outermost-last-added-first) over the base handler and runs the chain
//@desc
.util.handlers.run:{[handler;params]
 funcs:exec func from .util.handlers.tab where handlerName=handler;
 completeFunc:({$[104h~type y;@[y;enlist x];y[x]]})over .util.handlers.base[handler],funcs;
 func:{[handler;completeFunc;params]
       $[1~count @[;1] value .util.handlers.default[handler];@;.][completeFunc;params]
      };
 $[.util.handlers.trap;
   .Q.trp[func[;completeFunc;params];handler;.util.handlers.errTrap[handler]];
   @[func[;completeFunc;params];handler]
  ]
 };

//@func   | .util.handlers.errTrap
//@param  | handler | -11 | handler that errored
//@param  | e       | 0   | Error signal
//@param  | bt      | 0   | Backtrace returned by .Q.trp
//@desc
//Logs the error+backtrace then re-signals
//@desc
.util.handlers.errTrap:{[handler;e;bt]
 -2 string[handler]," error: ",e,"\nbacktrace:\n",.Q.sbt bt;
 'e
 };

//@func   | .util.handlers.add
//@param  | handler | -11 | handler to add to, e.g. `.z.pc
//@param  | func    | 100 -11 | Function or symbol function name
//@return | -7 | ID which can later be used with .util.handlers.removeID
//@desc
//Adds new functionality to a handler by regenerating it as a chain-dispatcher
//@desc
.util.handlers.add:{[handler;func]
 if[(::)~.util.handlers.default[handler];'"Unknown handler"];
 if[any .util.handlers.base[handler]~/:((::);());.util.handlers.setBaseAuto[handler]];
 if[-11h~type func;func:.[func]];
 thisID:.util.handlers.id;
 `.util.handlers.tab insert (thisID;handler;func);
 genFunc:{"{.util.handlers.run[`",string[x],";(",(sv[";"] string @[;1] value .util.handlers.default[x]),")]}"};
 handler set value genFunc[handler];
 .util.handlers.id+:1;
 thisID
 };

//@func   | .util.handlers.removeID
//@param  | index | -7 | index to remove
//@desc
//Removes a handler wrapper by index
//@desc
.util.handlers.removeID:{[index]
 delete from `.util.handlers.tab where id=index;
 };

.util.handlers.info.loaded:1b;
