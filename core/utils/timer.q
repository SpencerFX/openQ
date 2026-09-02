//====================================================================
// Directory: core/utils/timer.q
//
// About:
// Multi-timer scheduler layered over kdb+'s single .z.ts, so independent
// subsystems (logging, connections, servers, housekeeping...) can each
// register their own periodic work without fighting over one callback.
//
// Namespaces:
//   .util.timer.* - timer registration (ABS/REL/DEF/ONCE modes), the
//                   shared .z.ts scan/dispatch loop
//====================================================================
.util.timer.info.loaded:0b;
.util.timer.info.init:0b;

.util.timer.tab:([id:`long$()] added:`timestamp$(); start:`timestamp$(); end:`timestamp$(); frequency:`timespan$(); func:();
        lastRun:`timestamp$(); nextRun:`timestamp$(); active:`boolean$(); mode:`$(); info:());

.util.timer.id:0;

//Next-run calculators per scheduling mode:
// `ABS  - fixed grid aligned to timer start time
// `REL  - relative to last start
// `DEF  - deferred, relative to last finish (avoids overlap drift)
// `ONCE - run once at start time then deactivate
.util.timer.modes:(!). flip (
    (`ABS;{[start;begin;finish;las;freq] start+freq*ceiling (begin-start)%freq});
    (`REL;{[start;begin;finish;las;freq] begin+freq});
    (`DEF;{[start;begin;finish;las;freq] finish+freq});
    (`ONCE;{[start;begin;finish;las;freq] start})
   );

//@func  | .util.timer.add
//@param | start     | -12 | Start time, 0Np for immediate
//@param | end       | -12 | End time, 0Wp for eternal
//@param | frequency | -16 | How often to fire timer
//@param | func      | 0   | Symbol/Function to run
//@param | mode      | -11 | One of `ABS`REL`DEF`ONCE
//@param | info      | 10  | Description of timer
//@return | -7 | ID of added timer
//@desc
//Add a timer
//@desc
.util.timer.add:{[start;end;frequency;func;mode;info]
 if[not mode in key .util.timer.modes;
    .util.log.exSig[`ERROR;`.util.timer.add]"Illegal timer mode passed: ",-3!mode
   ];
 now:.z.p;
 .util.timer.id+:1;
 active:now<=0Wp^end;
 nextRun:$[now<start;start;`ABS~mode;.util.timer.modes[`ABS][start;now;now;start;frequency];not active;0Np;now];
 if[-11h~type func;func:@[func]];
 if[type[func] in 0 11h;func:{[fn;x] value fn}[func]];
 `.util.timer.tab upsert (.util.timer.id;now;-0Wp^start;0Wp^end;frequency;func;-0Wp;nextRun;active;mode;info);
 .util.log.ex[`DEBUG;`.util.timer.add]"Added timer \"",info,"\" ID ",string .util.timer.id;
 .util.timer.id
 };

//@func  | .util.timer.runOnce
//@param | runTime | -12 | Start time, 0Np for immediate
//@param | func    | 0   | Symbol/Function to run
//@param | info    | 10  | Description of timer
//@return | -7 | ID of added timer
//@desc
//Add a function to be run once at a specified time
//@desc
.util.timer.runOnce:{[runTime;func;info]
 .util.timer.add[runTime;0Wp;0Nn;func;`ONCE;info]
 };

//@func   | .util.timer.remove
//@param  | timerId | -7 | ID to remove
//@desc
//Remove a timer
//@desc
.util.timer.remove:{[timerId]
 delete from `.util.timer.tab where id=timerId;
 };

//@func   | .util.timer.ZTS
//@desc
//Installed as .z.ts: scans the timer table each base tick for due timers and runs them
//@desc
.util.timer.ZTS:{
 now:.z.p;
 update nextRun:0Np,active:0b from `.util.timer.tab where active,now>end;
 runs:`nextRun xasc select from 0!.util.timer.tab where active,now>nextRun;
 @'[.util.timer.run;runs;{[e]}];
 };

//@func   | .util.timer.run
//@param  | tmr | 99 | Row of timer info
//@desc
//Run a single timer, trapping errors, and reschedule its next run
//@desc
.util.timer.run:{[tmr]
 now:.z.p;
 if[now>tmr[`end];:update nextRun:0Np,active:0b from `.util.timer.tab where id=tmr[`id]];
 success:1b~err:.Q.trp[{x[y];1b}[tmr[`func]];
                       now;
                       {[e;bt]if[.util.log.level>=.util.log.levels[`DEBUG];-1 .Q.sbt bt];e}
                      ];
 finish:.z.p;
 duration:finish-now;
 nextRun:.util.timer.modes[tmr[`mode]][tmr[`start];now;finish;tmr[`lastRun];tmr[`frequency]];
 if[tmr[`id] in key .util.timer.tab;
    `.util.timer.tab upsert (tmr[`id];tmr[`added];tmr[`start];tmr[`end];tmr[`frequency];tmr[`func];now;nextRun;tmr[`active];tmr[`mode];tmr[`info]);
   ];
 if[tmr[`mode]=`ONCE;update nextRun:0Np,active:0b from `.util.timer.tab where id=tmr[`id]];
 $[success;
   .util.log.ex[`DEBUG;`.util.timer.run]"Timer \"",tmr[`info],"\" took: ",string duration;
   .util.log.ex[`ERROR;`.util.timer.run]"Timer \"",tmr[`info],"\" failed after: ",(string duration)," with: ",err
  ];
 };

//@func   | .util.timer.init
//@desc
//Starts the base .z.ts tick running (100ms) and installs .util.timer.ZTS as .z.ts
//@desc
.util.timer.init:{
 if[.util.timer.info.init;:(::)];
 system"t 100";
 .z.ts:.util.timer.ZTS;
 .util.timer.info.init:1b;
 };

//@func   | .util.timer.chgFreq
//@param  | timerId | -7  | ID to change
//@param  | freq    | -16 | New frequency
//@desc
//Change a timer's frequency
//@desc
.util.timer.chgFreq:{[timerId;freq]
 update frequency:freq from `.util.timer.tab where id=timerId;
 };

//@func   | .util.timer.toggle
//@param  | timerId | -7 | ID to toggle
//@param  | flag    | 1  | New active value
//@desc
//Enable/disable a timer without removing it
//@desc
.util.timer.toggle:{[timerId;flag]
 update active:flag from `.util.timer.tab where id=timerId;
 };

//@func   | .util.timer.getRandOffset
//@param  | maxOffset | -16 | Maximum timespan offset
//@return | -16 | Random timespan less than maxOffset
//@desc
//Returns a random timespan, used to jitter timer start times and avoid thundering herds
//@desc
.util.timer.getRandOffset:{[maxOffset]
 first 1?maxOffset
 };

//@func   | .util.timer.getRandStartTime
//@param  | maxOffset | -16 | Maximum timespan offset
//@return | -12 | Random timestamp offset from now
//@desc
//Returns a random timestamp offset from current UTC time by less than maxOffset
//@desc
.util.timer.getRandStartTime:{[maxOffset]
 .z.p+.util.timer.getRandOffset maxOffset
 };

.util.timer.info.loaded:1b;
