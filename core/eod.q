//====================================================================
// Directory: core/eod.q
//
// About:
// Standalone EOD promotion: unlike idb.q's own .oq.idb.eod (which first
// runs one final pivot-and-harvest of whatever's currently active before
// promoting - see core/idb.q's header for the pivot/harvest design), this
// process has no live rdb pair to pivot at all - it's detached from any
// running tp/rdb/idb. It just reads whichever segments an idb writer has
// already durably harvested to disk (.oq.save.readSegments, per table,
// unioning every 0,1,2,... segment currently under -idbroot) and promotes
// them into the real HDB through the exact same sorted/enumerated/
// attributed/atomic-publish pipeline every other EOD path uses
// (.oq.save.eod) - so a reload-polling hdb.q sees the new partition
// appear the normal way, no different from an idb-driven EOD.
//
// Because it only reads what's already harvested, run this after you're
// confident the idb writer pointed at -idbroot has taken its final
// pivot-and-harvest for the day - whatever's still live in the currently-
// active rdb at the moment this runs won't be included (it'll show up in
// whichever day's EOD actually promotes it once harvested). Unlike
// .oq.idb.eod, this does NOT clear -idbroot afterward - it's a read-only
// promotion path (same guarantee tests/sh/run_efx_test.sh documents for
// -hdb elsewhere), so a second promote of an already-published date would
// collide with .oq.save.publish's atomic rename; nothing here coordinates
// against running it twice for the same date.
//
// A one-shot batch job, not a long-running server: .oq.eod.init runs the
// promotion once for -eodDate (or today) and exits, the same lifecycle a
// cron-triggered EOD job would have - it's deliberately not part of
// scripts/startupAll*.sh's always-on process set.
//
// Namespaces:
//   .oq.eod.*   - loads one idb writer's checkpointed segments for a date
//                 and promotes them to the real HDB, and .init - the full
//                 startup sequence
//====================================================================
.oq.info.eod.loaded:0b;

//@func   | .oq.eod.run
//@param  | dt | -14 | Date to promote everything currently harvested as
//@desc
//Loads every schema table's harvested segments from -idbroot (unioning
//every 0,1,2,... segment currently there - see .oq.save.readSegments),
//sets them as the working global (the same convention .oq.save.saveTable
//reads from - tabName IS the table's global variable), and promotes them
//through .oq.save.eod into -hdbroot as dt's partition
//@desc
.oq.eod.run:{[dt]
 tabs:.oq.schema.tables[];
 {[t] t set .oq.save.readSegments[t;.oq.eod.idbRoot]} each tabs;
 .oq.save.eod[tabs;dt;.oq.eod.hdbRoot];
 .util.log.ex[`INFO;`.oq.eod.run]"Promoted ",(string dt)," from ",(string .oq.eod.idbRoot)," to HDB root ",string .oq.eod.hdbRoot;
 };

//@func   | .oq.eod.init
//@desc
//Full startup sequence for an eod process: points it at the idb staging
//root to read from and the real HDB root to promote into, runs
//.oq.eod.run once for -eodDate (today, .z.d, if not given), then exits -
//see the module header for why this is a one-shot job rather than a
//server. Reads its own params from .util.start.CLP so callers (init.q/
//initFromCfg.q) don't need to know which CLI params an eod process needs.
//@desc
.oq.eod.init:{[]
 .oq.eod.idbRoot:.util.core.toHsym .util.start.CLP[`idbroot][`val];
 .oq.eod.hdbRoot:.util.core.toHsym .util.start.CLP[`hdbroot][`val];
 dtStr:.util.start.CLP[`eodDate][`val];
 dt:$[count dtStr;"D"$dtStr;.z.d];
 .oq.eod.run[dt];
 .util.log.ex[`INFO;`.oq.eod.init]"eod process finished: ",string .util.start.CLP[`name][`val];
 exit 0;
 };

.oq.info.eod.loaded:1b;
