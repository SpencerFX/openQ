//====================================================================
// Directory: core/idb.q
//
// About:
// idb writer, redesigned along the lines of a real kdb+tick deployment's
// TmpHDBWriter: it no longer subscribes to the tickerplant itself at
// all. The pipeline is now:
//
//   fh -> tp -> rdb_1 or rdb_2 (exactly one active - see core/rdb.q's
//         header for the active/standby pair) <- idb, which drives the
//         pivot between them and PULLS (queries) the just-demoted rdb's
//         frozen in-memory tables rather than buffering ticks of its own.
//
// On every -checkpointfreq tick, .oq.idb.pivotAndHarvest:
//   1. asks both rdbs which one is ACTUALLY active right now
//      (.oq.idb.whichActive) - never assumed or cached, so idb restarting
//      independently of the rdb pair, or an operator calling
//      .oq.rdb.activate/standby directly (both are plain IPC-callable
//      verbs), can never leave idb pivoting the wrong instance;
//   2. promotes the real standby to active (.oq.rdb.activate - live
//      ticks start landing there from this instant on, replaying
//      anything missed since it was last active);
//   3. demotes the real old active to standby (.oq.rdb.standby) - its
//      in-memory tables are now a complete, FROZEN snapshot of
//      everything since the previous pivot, no longer changing;
//   4. queries that frozen snapshot table by table and writes it down
//      as the next sequentially-numbered segment directory under
//      -idbroot (0, 1, 2, ... - see .oq.idb.nextSegment), via the exact
//      same stage-then-atomically-publish path (.oq.save.eod) every
//      other EOD write in this repo uses - an int segment number is
//      just as valid a "partition value" there as a date is, since
//      nothing in save.q's low-level primitives actually cares which.
//
// Promoting BEFORE demoting (not the other way around) means there's
// never a gap where NEITHER instance is subscribed - the tradeoff is a
// brief window where both are, so a handful of ticks arriving in that
// exact instant could in principle land in both the just-frozen segment
// and the newly-active instance's next one. No deduplication is built
// for that here (deliberately - see this repo's own "illustrative core,
// not an exhaustive production reproduction" scope elsewhere, e.g.
// core/housekeeping.q's header); the alternative (demote-first) trades
// that rare duplicate for an unrecoverable gap if anything is published
// in between, which is worse.
//
// -idbroot only ever holds the CURRENT trading day's segments - unlike
// the old design's root/date/table layout, there's no date in a segment
// path (segments are pivot-numbered, not dated), so .oq.idb.eod resets
// it after promoting everything into the real dated HDB partition,
// ready for tomorrow's segment 0.
//
// Namespaces:
//   .oq.idb.*   - rdb pivot/harvest cycle, segment numbering, EOD
//                 promotion, and .init - the full startup sequence
//====================================================================
.oq.info.idb.loaded:0b;

// This idb's two fixed connections - one per rdb address (-rdbaddr/
// -rdbaddr2) - never swapped or relabeled. WHICH of the two is currently
// active is deliberately never cached/assumed here: it's asked fresh
// every cycle (.oq.idb.whichActive) rather than tracked as local state
// that could silently drift out of sync with reality - e.g. if idb
// itself restarts mid-day while the rdb pair keeps running, or if an
// operator calls .oq.rdb.activate/standby directly (both are plain
// IPC-callable verbs - see core/rdb.q's header) without going through
// idb at all. A cached "idb thinks X is active" label has no way to
// notice either of those; asking each rdb directly always reflects
// whatever's actually true at that instant.
.oq.idb.h1:0Ni;
.oq.idb.h2:0Ni;
.oq.idb.addr1:`;
.oq.idb.addr2:`;

//@func   | .oq.idb.connect
//@param  | addr | -11 | `:host:port to (re)connect to
//@param  | cur  | -6  | Current handle for this address, 0Ni if not connected
//@return | -6 | A live handle to addr, or 0Ni on failure
//@desc
//Returns cur unchanged if it's still live, otherwise (re)opens it
//@desc
.oq.idb.connect:{[addr;cur]
 if[not null cur;:cur];
 @[.util.ipc.hopen;(addr;5000);{[a;e].util.log.ex[`ERROR;`.oq.idb.connect]"Failed to connect to ",(string a)," with: ",e;0Ni}[addr]]
 };

//@func   | .oq.idb.whichActive
//@param  | h1 | -6 | Handle to .oq.idb.addr1
//@param  | h2 | -6 | Handle to .oq.idb.addr2
//@return | -7h | 1 if addr1 is currently active, 2 if addr2 is, 0N if neither/unknown
//@desc
//Asks both rdbs directly which one is active RIGHT NOW, rather than
//trusting a locally-cached label - see this file's .oq.idb.h1/h2 comment
//for why that matters. Treats "both say active" or "both say standby" as
//an inconsistent state (0N) rather than guessing - that shouldn't happen
//in normal operation (see core/rdb.q's header), but silently picking one
//would be worse than refusing to pivot for a cycle.
//@desc
.oq.idb.whichActive:{[h1;h2]
 a1:@[h1;".oq.rdb.active";{[e]0b}];
 a2:@[h2;".oq.rdb.active";{[e]0b}];
 $[a1 and not a2;1h;a2 and not a1;2h;0Nh]
 };

//@func   | .oq.idb.nextSegment
//@param  | root | -11 | Intraday segment root (-idbroot)
//@return | -7 | The next sequential segment number to write - 0 if root is empty/missing
//@desc
//Segments are numbered 0,1,2,... under root, one per harvest cycle -
//same "highest existing + 1, else 0" idiom a real kdb+tick TmpHDBWriter
//uses for its own segment directories.
//@desc
.oq.idb.nextSegment:{[root]
 found:@[key;root;`$()];
 found:found where found like "[0-9]*";
 $[0=count found;0;1+max "I"$string found]
 };

//@func   | .oq.idb.pivotAndHarvest
//@desc
//Timer callback: the full pivot-and-harvest cycle described in this
//file's header. Asks both rdbs which is actually active right now
//(.oq.idb.whichActive - never assumed/cached), promotes the real
//standby, demotes the real old active, pulls the old active's now-frozen
//tables over IPC, writes them as the next segment, then tells that same
//(now-frozen, no longer subscribed) instance to flush its own memory
//now that everything in it is durable - .oq.rdb.flush, the exact verb
//idb already used to trim rdb memory in the old independent-subscriber
//design, just called remotely here instead of over the tp-driven notify
//path. Clearing idb's own LOCAL pulled copies isn't enough on its own:
//they're one-shot query results, not the remote rdb's actual in-memory
//tables, so skipping the remote .oq.rdb.flush call would leave the
//harvested rdb's memory growing forever even though everything in it is
//already safely on disk.
//@desc
.oq.idb.pivotAndHarvest:{[]
 .oq.idb.h1:.oq.idb.connect[.oq.idb.addr1;.oq.idb.h1];
 .oq.idb.h2:.oq.idb.connect[.oq.idb.addr2;.oq.idb.h2];
 if[any null (.oq.idb.h1;.oq.idb.h2);
    .util.log.ex[`WARN;`.oq.idb.pivotAndHarvest]"Can't pivot - one or both rdb handles unavailable";
    :(::)
   ];
 which:.oq.idb.whichActive[.oq.idb.h1;.oq.idb.h2];
 if[null which;
    .util.log.ex[`ERROR;`.oq.idb.pivotAndHarvest]"Can't pivot - both rdbs report the same active/standby state (expected exactly one active)";
    :(::)
   ];
 activeH:$[which=1h;.oq.idb.h1;.oq.idb.h2];
 standbyH:$[which=1h;.oq.idb.h2;.oq.idb.h1];

 @[standbyH;(`.oq.rdb.activate;::);{[e].util.log.ex[`ERROR;`.oq.idb.pivotAndHarvest]"Failed to activate standby: ",e}];
 @[activeH;(`.oq.rdb.standby;::);{[e].util.log.ex[`ERROR;`.oq.idb.pivotAndHarvest]"Failed to stand down old active: ",e}];

 tabs:.oq.schema.tables[];
 {[h;t] t set @[h;"select from ",string t;{[t;e].util.log.ex[`ERROR;`.oq.idb.pivotAndHarvest]"Failed to harvest ",(string t),": ",e;0#value t}[t]]}[activeH] each tabs;

 seg:.oq.idb.nextSegment[.oq.idb.root];
 .oq.save.eod[tabs;seg;.oq.idb.root];
 .util.log.ex[`INFO;`.oq.idb.pivotAndHarvest]"Harvested segment ",(string seg)," from ",(string $[which=1h;.oq.idb.addr1;.oq.idb.addr2])," (",(", " sv {(string x),":",string count value x} each tabs),")";
 {[h;t] @[h;(`.oq.rdb.flush;t;.z.p);{[t;e].util.log.ex[`ERROR;`.oq.idb.pivotAndHarvest]"Failed to flush harvested rdb's ",(string t),": ",e}[t]]}[activeH] each tabs;
 {delete from x; update `g#sym from x}each tabs;
 };

//@func   | .oq.idb.eod
//@param  | dt | -14 | Date to promote (typically .z.d)
//@desc
//End-of-day promotion: runs one final pivot-and-harvest (so whatever's
//currently active isn't left stranded past midnight), unions every
//segment written today per table (.oq.save.readSegments), publishes the
//combined set through the normal sorted/enumerated/attributed EOD
//pipeline into the real HDB root, then clears -idbroot so tomorrow's
//first harvest starts at segment 0 again.
//@desc
.oq.idb.eod:{[dt]
 .oq.idb.pivotAndHarvest[];
 tabs:.oq.schema.tables[];
 {[dt;t] t set .oq.save.readSegments[t;.oq.idb.root]}[dt] each tabs;
 .oq.save.eod[tabs;dt;.oq.idb.hdbRoot];
 // clear every table global's reference to the just-read segment files
 // (and gc) BEFORE trying to remove those segment directories - on
 // Windows, a file this process still has memory-mapped (via the `get`s
 // inside .oq.save.readSegments a moment ago) can't be deleted out from
 // under it until q actually releases the mapping
 {[tab] delete from tab; update `g#sym from tab} each tabs;
 .util.core.gc[];
 // -idbroot also holds a `sym` enumeration FILE (.Q.en, from every
 // .oq.save.eod write this session has done into it), sitting right
 // alongside the numbered segment DIRECTORIES - not filtering it out
 // here means .util.core.osRmdirTree tries `rd /s /q` (remove-DIRECTORY)
 // on a plain file, which fails outright on Windows (confirmed directly:
 // "Failed to remove os", kdb+'s generic system-call-failed message) and,
 // since osRmdirTree's own failure handler re-signals, aborts this each
 // loop - potentially leaving OTHER, real segment directories un-cleared
 // too, depending on iteration order. Same numeric-name filter
 // .oq.idb.nextSegment already uses to tell segments apart from anything
 // else that might be sitting in -idbroot.
 segs:@[key;.oq.idb.root;`$()];
 segs:segs where segs like "[0-9]*";
 {[root;s] .util.core.osRmdirTree .Q.dd[root;s]} [.oq.idb.root] each segs;
 .util.log.ex[`INFO;`.oq.idb.eod]"Promoted ",(string dt)," to HDB root ",(string .oq.idb.hdbRoot),"; -idbroot cleared for tomorrow's segment 0";
 };

//@func   | .oq.idb.init
//@desc
//Full startup sequence for an idb process: points it at its own intraday
//segment root and the real HDB root, records the pair's two addresses
//(-rdbaddr/-rdbaddr2) - deliberately NOT which one is active; that's
//asked fresh every cycle, see .oq.idb.whichActive - then registers the
//pivot-and-harvest timer. Reads its own params from .util.start.CLP so
//callers (init.q/initFromCfg.q) don't need to know which CLI params an
//idb needs.
//@desc
.oq.idb.init:{[]
 .oq.idb.root:.util.core.toHsym .util.start.CLP[`idbroot][`val];
 .oq.idb.hdbRoot:.util.core.toHsym .util.start.CLP[`hdbroot][`val];
 .oq.idb.addr1:`$.util.start.CLP[`rdbaddr][`val];
 .oq.idb.addr2:`$.util.start.CLP[`rdbaddr2][`val];
 if[null .oq.idb.addr2;.util.log.exSig[`ERROR;`.oq.idb.init]"-rdbaddr2 is required - idb now pivots between an active/standby rdb pair, see core/rdb.q's header"];
 //note: `timespan$str casts str's characters elementwise (not what we want here);
 //"N"$str parses it as a timespan literal, same idiom as .util.start.castRow's "*" pType
 freq:"N"$.util.start.CLP[`checkpointfreq][`val];
 .oq.idb.info.timer.checkpoint:.util.timer.add[.z.p+freq;0Wp;freq;`.oq.idb.pivotAndHarvest;`REL;"idb pivot-and-harvest"];
 .util.log.ex[`INFO;`.oq.idb.init]"idb writer started: ",(string .util.start.CLP[`name][`val])," (pair: ",(string .oq.idb.addr1),"/",(string .oq.idb.addr2),")";
 };

.oq.info.idb.loaded:1b;
