//====================================================================
// Directory: core/utils/start.q
//
// About:
// Command-line parameter registration/parsing, e.g. -procType rdb -port 5011.
// Other scripts register the params they need via .util.start.add before
// .util.start.refresh[] is called (done once, at the bottom of this file).
//
// Namespaces:
//   .util.start.* - param registration, type-casting/defaulting, and the
//                   required-param check every process boots through
//====================================================================
.util.start.info.loaded:0b;

.util.start.time:.z.p;

//Raw command line params as passed (symbol!string list)
.util.start.params:((enlist `)!enlist ""),.Q.opt[.z.X];

//@func   | .util.start.add
//@param  | name       | -11 | The name of the parameter
//@param  | required   | -1  | Is the parameter required
//@param  | pType      | -10 | The q type char to cast the value to, e.g. "I"
//@param  | atom       | -1  | Is the parameter a single value (vs a list)
//@param  | setDefault | -1  | Whether to apply a default when not passed
//@param  | default    | 0   | Default value to use if setDefault and not passed
//@desc
//Register a command line parameter definition
//@desc
.util.start.add:{[name;required;pType;atom;setDefault;default]
 `.util.start.CLPSettings upsert (name;required;pType;atom;setDefault;enlist default);
 };

.util.start.CLPSettings:([name:`symbol$()] required:`boolean$(); pType:`char$(); atom:`boolean$(); setDefault:`boolean$(); default:());

//@func   | .util.start.process
//@desc
//Casts passed parameters against their registered types, applies defaults for missing ones
//@desc
//pType "*" means "leave as raw string(s), no cast" - used for free-text params like file paths
.util.start.castRow:{[pT;isAtom;pv]
 v:$[isAtom;first pv;pv];
 $["*"=pT;v;pT$v]
 };
.util.start.process:{
 .util.start.CLP:update passedVal:.util.start.params[name] from .util.start.CLPSettings;
 .util.start.CLP:update val:.util.start.castRow'[pType;atom;passedVal] from .util.start.CLP;
 .util.start.CLP:update val:first each default from .util.start.CLP where setDefault,{or'[x~\:enlist "";0=count each x]}[passedVal];
 };

//@func   | .util.start.CLPCheckMissing
//@desc
//Signals an error if any required command line parameters are missing
//@desc
.util.start.CLPCheckMissing:{
 missing:reqList where not (reqList:exec name from .util.start.CLPSettings where required) in key .util.start.params;
 if[not 0~count missing;.util.log.exSig[`ERROR;`.util.start.CLPCheckMissing]"Required command line argument(s) missing: ",", " sv string missing];
 };

//@func   | .util.start.refresh
//@desc
//Process command line parameters and error if any required are missing
//@desc
.util.start.refresh:{
 .util.start.process[];
 .util.start.CLPCheckMissing[];
 };

.util.start.add[`procType;1b;"S";1b;0b;`];
.util.start.add[`name;1b;"S";1b;0b;`];
.util.start.add[`port;0b;"I";1b;1b;0i];
.util.start.add[`logLevel;0b;"S";1b;1b;`INFO];

// Registered generically here (not core/config.q) so they always exist in
// .util.start.CLP regardless of role - .util.start.resolveInstancePort
// below indexes them unconditionally for every process, and a keyed-table
// lookup on a name .util.start.add never registered would error, not
// return null. Only -procType rdb ever sets port1/port2 to something
// nonzero (see core/rdb.q's header for the dual-instance rdb design) -
// every other role just carries the 0i/0i/1i defaults, inert.
.util.start.add[`port1;0b;"I";1b;1b;0i];
.util.start.add[`port2;0b;"I";1b;1b;0i];
.util.start.add[`instance;0b;"I";1b;1b;1i];

//@func   | .util.start.resolveInstancePort
//@desc
//For a dual-instance role launched with -port1/-port2/-instance instead
//of a single -port (currently only -procType rdb - see core/rdb.q):
//resolves this process's real listen port from whichever of port1/port2
//-instance selects, and appends "_<instance>" to -name so the two
//instances register as distinct gateway servers and log under distinct
//names. Must run after .util.start.refresh (so port1/port2/instance/name
//are already parsed) and before init.q's/initFromCfg.q's own \p bind
//(which reads .util.start.CLP[`port]). A no-op when port1 and port2 are
//both left at their 0i default - safe to call unconditionally for every
//role, not just rdb.
//@desc
.util.start.resolveInstancePort:{[]
 if[0<.util.start.CLP[`port1][`val]|.util.start.CLP[`port2][`val];
    inst:.util.start.CLP[`instance][`val];
    .util.start.CLP[`port;`val]:$[inst=2;.util.start.CLP[`port2][`val];.util.start.CLP[`port1][`val]];
    .util.start.CLP[`name;`val]:`$(string .util.start.CLP[`name][`val]),"_",string inst;
   ];
 };

.util.start.info.loaded:1b;
