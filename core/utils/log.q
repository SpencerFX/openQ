//====================================================================
// Directory: core/utils/log.q
//
// About:
// Leveled logging: writes to stdout/stderr, optional in-memory ring buffer,
// and doubles as the exception-raising mechanism (log-then-signal).
//
// Namespaces:
//   .util.log.* - level threshold, formatted write, ring-buffer-recording
//                 variant, log-then-signal variant
//====================================================================
.util.log.info.loaded:0b;

.util.log.levels:`FATAL`ERROR`WARN`INFO`DEBUG!0 1 2 3 4;
.util.log.level:3;
.util.log.tab:([]time:`timestamp$();PID:`int$();level:`symbol$();mem:`long$();code:`symbol$();msg:());
.util.log.tabThreshold:2D;

//@func  | .util.log.setLogLevel
//@param | level | 0 | symbol name or long level
//@desc
//Set the active log level, below which messages are not written
//@desc
.util.log.setLogLevel:{[level]
 if[not type[level] in -7 -11h;.util.log.exSig[`ERROR;`.util.log.setLogLevel]"Unknown log level type: ",-3! level];
 if[and[-11h~type level;any level~/:key .util.log.levels];.util.log.level:.util.log.levels[level];:(::)];
 if[and[-7h~type level;any level~/:value .util.log.levels];.util.log.level:level;:(::)];
 .util.log.exSig[`ERROR;`.util.log.setLogLevel]"Unknown log level:",-3! level;
 };

//@func   | .util.log.write
//@param  | level | -11 | symbol log level
//@param  | code  | -11 | symbol code
//@param  | msg   | 10  | string log message
//@return | 99 | The contents of the logged message
//@desc
//Formats and writes a log line to stdout (INFO/DEBUG) or stderr (WARN+) if it passes the level threshold
//@desc
.util.log.write:{[level;code;msg]
 logMsg:`level`code`msg!(level;code;msg);
 logMsg[`PID]:.z.i;
 logMsg[`time]:.z.p;
 logMsg[`mem]:`long$floor (.Q.w[]`used)%1024*1024;
 logMsg[`frmt]:"|" sv (_[-3;string logMsg[`time]];string logMsg[`PID];string level;string logMsg[`mem];string code;msg);
 if[.util.log.level>=.util.log.levels[level];
    $[.util.log.levels[`WARN]>=.util.log.levels[level];-2;-1] logMsg[`frmt]];
 logMsg
 };

//@func   | .util.log.ex
//@param  | level | -11 | symbol log level
//@param  | code  | -11 | symbol code
//@param  | msg   | 10  | string log message
//@return | 99 | The contents of the logged message
//@desc
//Logs message with exception code to standard out/error
//@desc
.util.log.ex:{[level;code;msg]
 .util.log.write[level;code;msg]
 };

//@func   | .util.log.memEx
//@desc
//As .util.log.ex, also recording the message into the in-memory ring buffer .util.log.tab
//@desc
.util.log.memEx:{[level;code;msg]
 logMsg:.util.log.ex[level;code;msg];
 `.util.log.tab insert logMsg`time`PID`level`mem`code`msg;
 logMsg
 };

//@func   | .util.log.exSig
//@param  | level | -11 | symbol log level
//@param  | code  | -11 | symbol code
//@param  | msg   | 10  | string log message
//@desc
//Logs message with exception code, then signals with code and message
//@desc
.util.log.exSig:{[level;code;msg]
 .util.log.ex[level;code;msg];
 'string[code],"|",msg
 };

//@func   | .util.log.maskConnPass
//@param  | conn | -11 | Connection details passed to hopen
//@return | 10 | String of connection details with password replaced
//@desc
//Replaces the password portion of a connection string so it's not written to log
//@desc
.util.log.maskConnPass:{[conn]
 (":" sv 3#":" vs string conn),":***"
 };

//@func   | .util.log.truncateLogTab
//@desc
//Deletes rows from the in-memory log table which are over threshold age
//@desc
.util.log.truncateLogTab:{[]
 delete from `.util.log.tab where .z.p>time+.util.log.tabThreshold;
 };

//@func   | .util.log.addTruncateTimer
//@desc
//Registers an hourly timer to prune the in-memory log table
//@desc
.util.log.addTruncateTimer:{[]
 .util.log.info.timer.truncateLogTab:.util.timer.add[.z.p;0Wp;0D01:00:00;`.util.log.truncateLogTab;`DEF;".util.log.truncateLogTab"];
 };

.util.log.info.loaded:1b;
