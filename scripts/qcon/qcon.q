//====================================================================
// Directory: scripts/qcon/qcon.q
//
// About:
// Interactive remote console: connect to any configured openQ process by
// NAME (not port), then type q code at the prompt and have it evaluated
// on THAT process, not this one - exactly like opening q against it
// directly, minus having to remember its port.
//
// An rdb config (port1/port2, active/standby - core/rdb.q's own header)
// registers as TWO names: <name> resolves to port1, <name>.2 to port2.
//
// Usage (see scripts/qcon/qcon.sh for the rlwrap-wrapped launcher):
//   q scripts/qcon/qcon.q -name eq_m1_yfinance_rdb          / port1 (active)
//   q scripts/qcon/qcon.q -name eq_m1_yfinance_rdb.2         / port2 (standby)
//   q scripts/qcon/qcon.q -name eq_m1_yfinance_gw -host myhost.local
//   q scripts/qcon/qcon.q -list                              / print the registry, don't connect
//
//====================================================================

.qcon.scriptDir:{[p]
 p:ssr[p;"\\";"/"];
 sv["/";-1_"/" vs p]
 }[string .z.f];

.qcon.cfgDir:.qcon.scriptDir,"/../../cfg_proc";

//@func   | .qcon.findConfigs
//@return | 10 | Every *.json path under .qcon.cfgDir, recursively
//@desc
//Shells out to the platform's own recursive file listing rather than
//hand-rolling a kdb+ directory walk - matches this repo's existing
//OS-branch-on-.z.o convention (see core/utils/core.q's osMove/osRmdirTree).
//@desc
.qcon.findConfigs:{[]
 dir:.qcon.cfgDir;
 out:$["w"=first string .z.o;
       system "dir /s /b \"",dir,"\\*.json\"";
       system "find \"",dir,"\" -name *.json"
      ];
 out:out where out like "*.json";
 {ssr[x;"\\";"/"]} each out   / kdb+ file symbols on this repo are always forward-slash (see hdbroot etc. throughout cfg_proc); `dir /s /b` on Windows returns backslash paths
 };

//@func   | .qcon.registry
//@return | 98 | (name;procType;host;port) for every connectable process,
//               rdb configs expanded into <name> (port1) and <name>.2 (port2)
//@desc
//Reads every cfg_proc JSON file directly (not via core/utils/start.q -
//this script is deliberately standalone, no dependency on the rest of
//core/ loading correctly) and pulls out just what a console needs to
//connect: name, procType, port(s).
//@desc
.qcon.registry:{[]
 rows:{[f]
   @[{[f]
      j:.j.k "\n" sv read0 `$":",f;
      name:j`name;
      procType:j`procType;
      params:$[`params in key j;j`params;()!()];
      host:$[`host in key params;params`host;"localhost"];
      $[`port in key j;
        enlist (name;procType;host;j`port);
        all `port1`port2 in key params;
        ((name;procType;host;params`port1);(name,".2";procType;host;params`port2));
        ()  / no top-level port and no port1/port2 (e.g. a config this tool doesn't know how to connect to) - skip
       ]
      };
     f;
     {[f;e] -1 "qcon: skipping ",f," (couldn't parse it: ",e,")"; ()}[f]
    ]
   } each .qcon.findConfigs[];
 rows:raze rows;
 if[0=count rows;:([] name:`$(); procType:`$(); host:`$(); port:`int$())];
 ([] name:`$rows[;0]; procType:`$rows[;1]; host:`$rows[;2]; port:"i"$rows[;3])
 };

//@func   | .qcon.printRegistry
//@desc
//`-list` output: every known process name/type/host:port, sorted.
//@desc
.qcon.pad:{[n;s] n sublist s,n#" "};

.qcon.printRegistry:{[]
 t:`procType`name xasc .qcon.registry[];
 -1 "Known processes (from ",.qcon.cfgDir,"):";
 {[row] -1 "  ",(.qcon.pad[28;string row`name])," ",(.qcon.pad[13;string row`procType])," :",(string row`host),":",string row`port} each 0!t;
 };

args:.Q.opt .z.X;

if[`list in key args;
   .qcon.printRegistry[];
   exit 0
  ];

if[not `name in key args;
   -1 "Usage: q scripts/qcon/qcon.q -name <processName> [-host <host>]   (or -list to see every known name)";
   exit 1
  ];

wantName:`$first args`name;
reg:.qcon.registry[];
match:select from reg where name=wantName;
if[0=count match;
   -1 "No process named '",(string wantName),"' found under ",.qcon.cfgDir;
   -1 "Run 'q scripts/qcon/qcon.q -list' to see every known name.";
   exit 1
  ];
row:first match;
host:$[`host in key args;first args`host;string row`host];
port:row`port;

-1 "Connecting to ",(string wantName)," (",(string row`procType),") at ",host,":",(string port)," ...";
.qcon.h:@[hopen;`$":",host,":",string port;
          {[host;port;e] -1 "Unable to connect to ",host,":",(string port),": ",e; exit 1}[host;port]
         ];
-1 "Connected. Type q expressions to run on the remote process; a bare '\\' exits.";

.z.pc:{exit 0};
.z.pi:{[x]
 $["\\\\\n"~x;exit 0;
   (3#x)~"\\c ";[value x;.Q.s .qcon.h x];
   .Q.s @[.qcon.h;x;{'x}]
  ]
 };
