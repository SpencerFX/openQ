//====================================================================
// Directory: core/hdb.q
//
// About:
// HDB: loads the on-disk partitioned database and periodically checks for a
// newly-written date partition, reloading to pick it up - the standard
// "poll for new partition, system"l ." pattern used by most kdb+ HDBs.
//
// Namespaces:
//   .oq.hdb.*   - load/reload, missing-table integrity check, and .init -
//                 the full startup sequence
//====================================================================
.oq.info.hdb.loaded:0b;

.oq.hdb.root:`:hdb;

//@func   | .oq.hdb.loadedDates
//@return | -14h | Dates currently loaded, empty if none
//@desc
//Safe accessor for the `date` partition-domain variable, which doesn't exist until a partition has ever loaded
//@desc
.oq.hdb.loadedDates:{[] @[get;`date;{`date$()}]};

//@func   | .oq.hdb.loadHDB
//@desc
//(Re)loads the on-disk partitioned database from .oq.hdb.root.
//schema.q must already be loaded first: it defines each table as an empty in-memory
//stub, which system"l" then transparently replaces with the on-disk partitioned
//version wherever one exists - so querying a table with no data on disk yet
//returns zero rows instead of erroring on an undefined variable.
//@desc
.oq.hdb.loadHDB:{[]
 .util.log.ex[`INFO;`.oq.hdb.loadHDB]"Loading HDB from ",string .oq.hdb.root;
 @[system;"l ",1_string .oq.hdb.root;{[e].util.log.exSig[`ERROR;`.oq.hdb.loadHDB]"Failed to load HDB: ",e}];
 // .Q.chk: backfill an empty splay for any table missing from a partition.
 // A single HDB root can legitimately hold more than one table family
 // written over different date ranges - e.g. C:/data/db1/mon carries the
 // mon module's `logs`/`pidstats` in recent partitions AND the
 // table-health archive's `tableHealth`/`tableHealthTick` in older ones
 // (both are "monitoring" data and share one root by design). Without the
 // backfill, an unbounded `select from pidstats` walks into an old
 // partition that has no `pidstats` directory and fails with a bare OS
 // "path not found"; likewise any cross-range scan of the other tables.
 // Stock kx tick/hdb.q runs .Q.chk here for the same reason. Failure-
 // tolerant - a chk problem must not stop the HDB from serving what did
 // load.
 //
 // Then reload: kx `\l` builds the table list from the NEWEST partition
 // only, so a table family missing from the most recent partition (here
 // `tableHealth`/`tableHealthTick`, whose last scan predates the mon
 // module's own partitions) never gets registered at all by the first
 // load - it isn't in `tables[]`, and querying it errors with a bare
 // `'tableHealth`. .Q.chk has just given the newest partition an (empty)
 // directory for every such table, so a second `\l` picks them all up.
 // Reloading is idempotent and cheap once the dirs exist (the reload
 // timer does the same `\l` every minute), so it runs unconditionally.
 @[.Q.chk;.oq.hdb.root;{[e].util.log.ex[`WARN;`.oq.hdb.loadHDB]".Q.chk (missing-partition backfill) failed: ",e}];
 @[system;"l ",1_string .oq.hdb.root;{[e].util.log.ex[`WARN;`.oq.hdb.loadHDB]"Reload after .Q.chk failed: ",e}];
 .util.log.ex[`INFO;`.oq.hdb.loadHDB]"HDB load complete, tables: ",(.Q.s1 tables[]),", dates: ",.Q.s1 .oq.hdb.loadedDates[];
 };

//@func   | .oq.hdb.checkMissingTables
//@return | -1 | 1b if the newest partition is missing a table present in the previous one
//@desc
//Compares the table set of the two most recent date partitions
//@desc
.oq.hdb.checkMissingTables:{[]
 dts:"D"$string key .oq.hdb.root;
 if[2>count dts;:0b];
 dts:desc dts;
 newest:key .Q.dd[.oq.hdb.root;first dts];
 prevTabs:key .Q.dd[.oq.hdb.root;dts 1];
 missing:prevTabs except newest;
 if[count missing;.util.log.ex[`WARN;`.oq.hdb.checkMissingTables]"Newest partition missing table(s): ",", " sv string missing];
 0<count missing
 };

//@func   | .oq.hdb.initReloadTimer
//@desc
//Starts a timer that checks for a new date partition once a minute
//@desc
.oq.hdb.initReloadTimer:{[]
 .oq.hdb.reloadTimerID:.util.timer.add[.z.p;0Wp;0D00:01:00;`.oq.hdb.checkReload;`DEF;"hdb reload check"];
 };

//@func   | .oq.hdb.checkReload
//@desc
//Timer callback: if a date newer than the newest loaded partition has appeared on disk, reload
//@desc
.oq.hdb.checkReload:{[]
 onDisk:"D"$string key .oq.hdb.root;
 if[0=count onDisk;:(::)];
 loaded:.oq.hdb.loadedDates[];
 loaded:$[0=count loaded;0Nd;max loaded];
 if[(max onDisk)>loaded;
    .util.log.ex[`INFO;`.oq.hdb.checkReload]"New date partition detected, reloading";
    .oq.hdb.loadHDB[]
   ];
 };

//@func   | .oq.hdb.init
//@desc
//Full startup sequence for an hdb process: points .oq.hdb.root at its
//configured root, loads it, and starts the once-a-minute reload check.
//Reads its own params from .util.start.CLP so callers
//(init.q/initFromCfg.q) don't need to know which CLI params an hdb needs.
//
//-hdbroot is resolved to an absolute path (.util.core.absPath) before
//being stored, not just hsym-normalized - loadHDB's system"l" against a
//relative root changes the process's own working directory as a side
//effect, so any LATER reload (checkReload's timer, or a manual trigger)
//against the same still-relative root would silently resolve against the
//wrong directory and fail. Resolving once, here, before the first load
//ever runs, means every subsequent reload keeps working correctly.
//@desc
.oq.hdb.init:{[]
 .oq.hdb.root:.util.core.toHsym .util.core.absPath .util.start.CLP[`hdbroot][`val];
 .oq.hdb.loadHDB[];
 .oq.hdb.initReloadTimer[];
 .util.log.ex[`INFO;`.oq.hdb.init]"HDB started: ",string .util.start.CLP[`name][`val];
 };

.oq.info.hdb.loaded:1b;
