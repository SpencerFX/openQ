//====================================================================
// Directory: core/utils/core.q
//
// About:
// Small generic utility belt used throughout: defensive type-checking,
// a logged GC wrapper, password-masking for connection strings, and a
// wrapped script loader.
//
// Namespaces:
//   .util.core.* - checkTypes, gc, obfus, osMove, osRmdir, osRmdirTree,
//                  ensureDir, toHsym, absPath, loadScript, minus22
//====================================================================
.util.core.info.loaded:0b;

//@func   | .util.core.checkTypes
//@param  | types  | 0 | List of allowed type lists, one per arg
//@param  | params | 0 | List of arg values to check
//@desc
//Signals an error if any param's type is not in its corresponding allowed-type list
//@desc
.util.core.checkTypes:{[types;params]
 bad:where not {type[y] in x}'[types;params];
 if[count bad;
    .util.log.exSig[`ERROR;`.util.core.checkTypes]"Argument(s) at position(s) ",(", " sv string bad)," have invalid type(s): ",", " sv string type each params bad
   ];
 };

//@func   | .util.core.gc
//@desc
//Runs garbage collection, logging before/after memory usage
//@desc
.util.core.gc:{[]
 before:.Q.w[]`used;
 .Q.gc[];
 after:.Q.w[]`used;
 .util.log.ex[`INFO;`.util.core.gc]"GC freed ",string[(before-after)%1024*1024]," MB";
 };

//@func   | .util.core.obfus
//@param  | conn | -11 | Connection sym, e.g. `:host:port:user:pass
//@return | -11 | Same connection sym with the password segment masked
//@desc
//Masks the password portion of a connection string before logging
//@desc
.util.core.obfus:{[conn]
 parts:":" vs string conn;
 if[4>count parts;:conn];
 `$":" sv (3#parts),enlist "***"
 };

//@func   | .util.core.osMove
//@param  | src  | -11 | Source hsym path
//@param  | dest | -11 | Destination hsym path
//@desc
//Atomically renames src to dest, using the right shell command for the OS
//@desc
.util.core.osMove:{[src;dest]
 srcS:1_string src;
 destS:1_string dest;
 cmd:$["w"=first string .z.o;"move \"",srcS,"\" \"",destS,"\"";"mv ",srcS," ",destS];
 @[system;cmd;{[e].util.log.exSig[`ERROR;`.util.core.osMove]"Failed to move ",e}];
 };

//@func   | .util.core.osRmdir
//@param  | dir | -11 | hsym directory path
//@desc
//Removes an (expected-empty) directory, using the right shell command for the OS - the
//counterpart to .util.core.osMove for a caller that moves a directory's contents out of it
//piece by piece (e.g. merging into an already-existing destination - see .oq.hk.saveHealth)
//rather than renaming the whole thing in one atomic move.
//@desc
.util.core.osRmdir:{[dir]
 dirS:1_string dir;
 cmd:$["w"=first string .z.o;"rd \"",dirS,"\"";"rmdir ",dirS];
 @[system;cmd;{[e].util.log.exSig[`ERROR;`.util.core.osRmdir]"Failed to remove ",e}];
 };

//@func   | .util.core.osRmdirTree
//@param  | dir | -11 | hsym directory path
//@desc
//Recursively removes dir and everything under it, using the right shell
//command for the OS - unlike .util.core.osRmdir (which expects dir to
//already be empty), this is for a caller that genuinely wants a whole
//subtree gone (e.g. idb.q's -idbroot segment directories, each holding a
//full set of per-table column files, at EOD - see .oq.idb.eod). No-op,
//not an error, if dir doesn't exist.
//@desc
.util.core.osRmdirTree:{[dir]
 dirS:1_string dir;
 cmd:$["w"=first string .z.o;"rd /s /q \"",dirS,"\"";"rm -rf ",dirS];
 @[system;cmd;{[e].util.log.exSig[`ERROR;`.util.core.osRmdirTree]"Failed to remove ",e}];
 };

//@func   | .util.core.ensureDir
//@param  | dir | -11 | hsym directory path
//@desc
//Creates dir (and any missing ancestors) if it doesn't already exist, via kdb+'s own
//set-auto-creates-parent-directories behavior - avoids needing an OS-specific mkdir.
//Unlike `set` on a data file, an OS-level `move`/`mv` into a not-yet-existing directory
//tree fails outright, so callers that shell out (e.g. .util.core.osMove) need this first.
//@desc
.util.core.ensureDir:{[dir]
 marker:`$(string dir),"/.keep";
 marker set ();
 @[hdel;marker;{}];
 };

//@func   | .util.core.toHsym
//@param  | path | 10 | File path, absolute or relative, with or without a leading colon
//@return | -11 | hsym-style symbol (guaranteed to start with a colon)
//@desc
//Normalizes a plain path string into the `:path form kdb+ file operations expect
//@desc
.util.core.toHsym:{[path]
 `$$[":"=first path;path;":",path]
 };

//@func   | .util.core.absPath
//@param  | path | 10 | File path, absolute or relative
//@return | 10 | path unchanged if already absolute, else joined with the
//               process's current working directory
//@desc
//Resolves a relative path once, at call time, to an absolute one. Needed
//anywhere a path gets handed to a REPEATED system"l" - loading an on-disk
//HDB root changes the process's working directory as a side effect (a
//kdb+ quirk, not documented as such), so a second system"l" against the
//same relative path silently resolves against the wrong directory and
//fails with "cannot find the path". A path used in system"l" only once
//(e.g. a schema file) doesn't need this - see .oq.hdb.init, the one
//caller that does, for why.
//@desc
.util.core.absPath:{[path]
 isAbs:("/"=first path) or (2<=count path) and ":"=path 1;
 $[isAbs;path;(system "cd"),"/",path]
 };

//@func   | .util.core.loadScript
//@param  | file | 10 | Path to script
//@desc
//Loads a script via system"l", logging and signaling on failure
//@desc
.util.core.loadScript:{[file]
 .util.log.ex[`INFO;`.util.core.loadScript]"Loading script: ",file;
 @[system;"l ",file;{[file;e].util.log.exSig[`ERROR;`.util.core.loadScript]"Failed to load ",file," with: ",e}[file]];
 };

//@func   | .util.core.minus22
//@param  | data | 0 | Any value
//@return | -7 | Approximate serialized byte size
//@desc
//Returns the -22! (serialized size) of a value, or 0Nj if it cannot be measured
//@desc
.util.core.minus22:{[data]
 @[-22!;data;{0Nj}]
 };

.util.core.info.loaded:1b;
