//====================================================================
// Directory: core/save.q
//
// About:
// EOD save-down: writes a date partition to a staging directory, then
// atomically renames it into place under the HDB root once every table is
// fully written - so a polling/reloading HDB (hdb.q) never sees a half
// written partition. Historically the RDB<->HDB boundary in any kdb+ system.
//
// Namespaces:
//   .oq.save.*  - low-level column read/write/append primitives, EOD
//                 sort/enumerate/attribute/publish, and the incremental
//                 intra-day checkpoint path idb.q uses
//====================================================================
.oq.info.save.loaded:0b;

//@func   | .oq.save.stageDir
//@param  | root | -11 | HDB root
//@param  | dt   | -14 | Date
//@return | -11 | Staging directory path for this date
//@desc
//The temp directory a date partition is written to before being published
//@desc
.oq.save.stageDir:{[root;dt] `$(string root),".stage_",string dt};

//@func   | .oq.save.writeCols
//@param  | data | 98  | Data to write (already enumerated/sorted as the caller wants it on disk)
//@param  | dir  | -11 | Destination directory (e.g. root/dt/tabName, or a staging equivalent)
//@desc
//Low-level primitive: (over)writes every column of data to dir and writes its .d file.
//No sort, no enumeration, no attribute - callers decide those; this just puts columns on disk.
//@desc
.oq.save.writeCols:{[data;dir]
 {[dir;data;c] .Q.dd[dir;c] set data c} [dir;data] each cols data;
 (`$(string dir),"/.d") set cols data;
 };

//@func   | .oq.save.saveTable
//@param  | tabName | -11 | Table name (also the global variable holding the data)
//@param  | dt      | -14 | Date partition
//@param  | stage   | -11 | Staging directory (see .oq.save.stageDir)
//@param  | root    | -11 | HDB root - .Q.en enumerates every symbol column against root/sym
//@desc
//EOD write: sorts by sym, enumerates all symbol columns, writes the staging partition, and
//applies the parted attribute to sym - safe here because the whole day's data is written in
//one sorted pass. (Contrast .oq.save.checkpoint, which writes incrementally through the day
//and deliberately does NOT sort/attribute - see its header.)
//@desc
.oq.save.saveTable:{[tabName;dt;stage;root]
 .util.log.ex[`INFO;`.oq.save.saveTable]"Saving ",(string tabName)," for ",string dt;
 data:.Q.en[root;`sym xasc value tabName];
 //stage is already date-specific (see .oq.save.stageDir); don't nest another date dir under it -
 //publish() renames stage -> root/dt as a whole, so writing straight to stage/tabName here becomes root/dt/tabName
 dir:.Q.dd[stage;tabName];
 .oq.save.writeCols[data;dir];
 .Q.dd[dir;`sym] set `p#get .Q.dd[dir;`sym];
 .util.log.ex[`INFO;`.oq.save.saveTable]"Saved ",(string count data)," row(s) to ",string dir;
 };

//@func   | .oq.save.appendCols
//@param  | data | 98  | Data to append (already enumerated)
//@param  | dir  | -11 | Existing directory previously written by .oq.save.writeCols/checkpoint
//@desc
//Appends every column of data onto an already-existing on-disk table in place -
//the efficient path for repeated intra-day checkpoints, versus rewriting the
//whole (growing) partition from scratch each time
//@desc
.oq.save.appendCols:{[data;dir]
 {[dir;data;c] @[dir;c;,;data c]} [dir;data] each cols data;
 };

//@func   | .oq.save.checkpoint
//@param  | tabName | -11 | Table name (also the global variable holding the data)
//@param  | dt      | -14 | Date partition (today, typically)
//@param  | root    | -11 | Staging root data is checkpointed under (e.g. .oq.idb.root)
//@desc
//Intra-day checkpoint: writes tabName's current in-memory rows straight to root/dt/tabName,
//creating it on the first checkpoint of the day and appending on every one after. Deliberately
//no sort/no attribute (each checkpoint's rows are only locally, not globally, sorted by sym -
//applying a parted attribute here would be incorrect); a later EOD pass re-reads, sorts, and
//attributes properly before publishing to the real HDB - see .oq.idb.eod.
//@desc
.oq.save.checkpoint:{[tabName;dt;root]
 data:.Q.en[root;value tabName];
 dir:.Q.dd[root;(dt;tabName)];
 isNew:0=count @[key;dir;0#`];
 $[isNew;.oq.save.writeCols[data;dir];.oq.save.appendCols[data;dir]];
 .util.log.ex[`INFO;`.oq.save.checkpoint]"Checkpointed ",(string count data)," row(s) of ",(string tabName)," to ",string dir;
 };

//@func   | .oq.save.readCheckpointed
//@param  | tabName | -11 | Table name
//@param  | dt      | -14 | Date
//@param  | root    | -11 | Root the data was checkpointed under (e.g. an idb's -idbroot)
//@return | 98 | The on-disk checkpointed rows for tabName/dt, or an empty table if none yet
//@desc
//Reads back what .oq.save.checkpoint has written for a table/date without going through
//system"l" - loading the root wholesale would clobber a live process's in-memory table of
//the same name if this is called from inside one (e.g. idb.q's own .oq.idb.eod, combining
//this with whatever's still buffered); a standalone eod.q process calling this has no such
//buffer to worry about and just uses the result directly - see .oq.eod.run.
//
//De-enumerates every symbol column immediately, right here, rather than
//handing back the raw on-disk enum (type 20h-76h) representation .Q.en
//wrote - confirmed as a REAL, previously-latent corruption bug, not just
//theoretical: a symbol column written via .Q.en against one root (e.g.
//this checkpoint's own root) is left encoded relative to THAT root's
//`sym` domain; .Q.en treats any ALREADY-enum-typed column as "already
//done" and skips re-enumerating it (a genuine, documented .Q.en
//short-circuit), so a caller that reads this raw and later hands it to
//.Q.en again against a DIFFERENT root (e.g. idb.q's .oq.idb.eod reading
//-idbroot's segments, then publishing into the real, much larger, shared
//-hdbroot) gets the raw integer codes copied straight through UNCHANGED -
//silently wrong once resolved against the new root's differently-ordered
//domain (confirmed directly: eq_m1_yfinance's exchange column showed
//garbage strings like "SAV"/"DBCAU" - actually -idbroot-domain indices
//0/1 - being misresolved against the shared eq_d1_yfinance/eq_m1_yfinance
//-hdbroot's own, much bigger `sym` domain). De-enumerating HERE, immediately
//after the raw get - while THIS root's own `sym` domain is still the
//correct one active in this process (nothing else has called .Q.en
//against a different root in between) - fixes it: `$string forces full
//resolution to a plain type 11h symbol vector with no domain reference
//left at all, so it can never be misresolved again regardless of what
//other root a caller's own .Q.en call touches afterward.
//@desc
.oq.save.readCheckpointed:{[tabName;dt;root]
 dir:.Q.dd[root;(dt;tabName)];
 if[0=count @[key;dir;0#`];:0#value tabName];
 dCols:@[get;`$(string dir),"/.d";{`$()}];
 flip dCols!{[dir;c] v:get .Q.dd[dir;c]; $[(type v) within 20 76h;`$string v;v]}[dir] each dCols
 };

//@func   | .oq.save.readSegments
//@param  | tabName | -11 | Table name
//@param  | root    | -11 | Intraday segment root (e.g. idb.q's -idbroot)
//@return | 98 | tabName's rows across every segment currently under root, in segment order
//@desc
//Reads back every int-numbered segment directory (0,1,2,... - see idb.q's
//header for what writes them) under root and unions them into one table.
//Segments are sequential harvest cycles within a single trading day, not
//dates, so - unlike .oq.save.readCheckpointed's single dt - there's no
//date to pass in: root only ever holds "today"'s segments (eod.q's own
//EOD resets it - see .oq.idb.eod). Reuses .oq.save.readCheckpointed one
//segment at a time - its dt param is only ever used for string-building a
//directory name, so an int segment number works exactly like a date does.
//@desc
.oq.save.readSegments:{[tabName;root]
 segs:@[key;root;`$()];
 segs:segs where segs like "[0-9]*";
 if[0=count segs;:0#value tabName];
 segs:asc "I"$string segs;
 raze .oq.save.readCheckpointed[tabName;;root] each segs
 };

//@func   | .oq.save.eod
//@param  | tabs    | 11  | Table names to save
//@param  | dt      | -14 | Date partition
//@param  | root    | -11 | HDB root
//@desc
//Stages every table for the given date, then atomically publishes the whole partition
//@desc
.oq.save.eod:{[tabs;dt;root]
 stage:.oq.save.stageDir[root;dt];
 //no explicit mkdir needed - set auto-creates missing parent directories
 .oq.save.saveTable[;dt;stage;root] each tabs;
 .oq.save.publish[stage;root;dt];
 };

//@func   | .oq.save.publish
//@param  | stage | -11 | Staging directory holding the fully-written partition
//@param  | root  | -11 | HDB root
//@param  | dt    | -14 | Date being published
//@desc
//Publishes stage's table subdirectories into place as (part of) the live
//date partition, one table at a time - NOT a single whole-directory move
//of stage onto dest, which only works when dest doesn't exist yet at all.
//Two or more tables can share one HDB root and its date partitions (e.g.
//eq_d1_yfinance and eq_m1_yfinance both live under C:/data/db1/eq) - the
//first of them to ever publish a given date creates dest, so every
//publish after that for a DIFFERENT table on the SAME date hits an
//already-existing dest. A plain OS-level move/rename onto an existing
//directory fails outright on Windows (confirmed directly: this is not
//hypothetical - it broke the very first time two tables on this root
//had genuinely overlapping dates). Publishing table-by-table sidesteps
//that entirely: only the tables actually in `stage` are touched, so a
//sibling table already published under the same date is left alone.
//@desc
.oq.save.publish:{[stage;root;dt]
 dest:.Q.dd[root;`$string dt];
 //root/dest may not exist yet (e.g. this HDB's very first EOD) - an
 //OS-level move, unlike kdb+'s own `set`, won't auto-create missing
 //parent directories
 .util.core.ensureDir[root];
 .util.core.ensureDir[dest];
 {[stage;dest;tabName]
   old:.Q.dd[dest;tabName];
   //replace, don't merge with, whatever this table's own prior publish
   //(if any) left at dest/tabName - same "fully rewritten, not appended
   //to" contract every other EOD path in this repo already has
   if[not ()~key old;.util.core.osRmdirTree old];
   .util.core.osMove[.Q.dd[stage;tabName];old];
  }[stage;dest] each key stage;
 .util.core.osRmdirTree stage;
 .util.log.ex[`INFO;`.oq.save.publish]"Published partition ",string dest;
 };

//@func   | .oq.save.notifyReload
//@param  | handles | -6h | HDB handles to notify
//@desc
//Asks already-connected HDB processes to reload immediately, rather than waiting for their poll timer
//@desc
.oq.save.notifyReload:{[handles]
 {@[.util.ipc.async[x];(`.oq.hdb.loadHDB;::);{[e].util.log.ex[`WARN;`.oq.save.notifyReload]"Failed to notify HDB to reload: ",e}]} each handles;
 };

//@func   | .oq.save.eodToday
//@param  | dt | -14 | Date to save down (typically .z.d)
//@desc
//Convenience wrapper run on the RDB: saves every schema table for dt to .oq.save.hdbRoot,
//then flushes those rows from memory now that they're durable on disk
//@desc
.oq.save.eodToday:{[dt]
 tabs:.oq.schema.tables[];
 .oq.save.eod[tabs;dt;.oq.save.hdbRoot];
 maxTime:`timestamp$dt+1;
 .oq.rdb.flush[;maxTime] each tabs;
 };

.oq.info.save.loaded:1b;
