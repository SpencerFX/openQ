//====================================================================
// 05_table_health_scan.q
//
// Runs core/housekeeping.q's .oq.hk.scanHDB against an on-disk HDB and
// persists the result via .oq.hk.saveHealth, one date partition at a
// time, into -monroot - a genuine on-disk record of table health/
// counts/size over time, the same partitioned-HDB shape every other
// table in this repo is saved with (core/save.q's own .oq.save.eod).
// Detached and disk-only, the same shape as core/eod.q/modules/
// backtest/run.q - no live tp/rdb/hdb needs to be running at all;
// .oq.hk.scanHDB never loads the target hdbroot's data into memory
// either (see .oq.hk.priv.partitionStats's own header) - it only reads
// each partition's timestamp column directly, which is what makes a
// whole-archive run below feasible at all.
//
// Defaults to schemas/schema_efx_bars.q (the EFX archive's bar-level
// tables only, not its two tick-level ones) - point -schema at the
// full schemas/schema_efx.q instead only if you deliberately want the
// tick tables included and are prepared for it to take a great deal
// longer (tens of millions of rows/day, vs these three tables' much
// smaller per-day volume - see .oq.hk.priv.partitionStats's header for
// why this scales with real data volume, by design).
//
// If -sDate/-eDate are omitted, scans the archive's OWN observed date
// range (oldest to newest date directory actually present under
// -hdbroot) rather than some arbitrary default window - this is what
// makes "the whole record" mode below actually mean the whole thing,
// without wastefully iterating empty calendar dates outside it.
//
// -savetab lets separate scans land as distinct tables side by side
// under the same -monroot, e.g. `tableHealth` for the bar-level
// schema and `tableHealthTick` for the tick-level one.
//
// Run from the repo root, like every other examples/scripts/*.q file:
//   q examples/scripts/05_table_health_scan.q \
//     -hdbroot C:/data/db1/efx -schema schemas/schema_efx_bars.q \
//     -monroot C:/data/db1/mon -savetab tableHealth -name efx
// (add -sDate/-eDate to bound it to a smaller window instead of the
// archive's full history)
//====================================================================

system "l core/utils/log.q";
system "l core/utils/core.q";
system "l core/housekeeping.q";
system "l core/save.q";

args:.Q.opt .z.x;
opt:{[args;k;def] $[k in key args;first args k;def]};

hdbroot: `$":",opt[args;`hdbroot;"C:/data/db1/efx"];
schema:   opt[args;`schema;"schemas/schema_efx_bars.q"];
monroot: `$":",opt[args;`monroot;"C:/data/db1/mon"];
savetab:  `$opt[args;`savetab;"tableHealth"];
name:     `$opt[args;`name;"efx"];

.util.core.loadScript schema;
allDates:.oq.hk.priv.allDates hdbroot;
if[not count allDates;'"no date partitions found under ",string hdbroot];

sDate:$[`sDate in key args;"D"$first args`sDate;first allDates];
eDate:$[`eDate in key args;"D"$first args`eDate;last allDates];

-1 "Scanning ",(string hdbroot)," for ",(string sDate)," to ",(string eDate)," (schema: ",schema,")";
-1 "This reads every on-disk partition's timestamp column once per table - see the file header before pointing this at a tick-level schema.";

health:.oq.hk.scanHDB[hdbroot;schema;sDate;eDate;name];

-1 "";
-1 "=== whole-table summary ===";
show 0!select rowCountTotal:first rowCountTotal,partitionCnt:first partitionCnt,
  oldestDate:first oldestDate,newestDate:first newestDate by tab from health;

-1 "";
-1 "Saving ",(string count health)," row(s) across ",(string count distinct health`date)," date partition(s) to ",(string monroot)," as `",(string savetab);
.oq.hk.saveHealth[health;monroot;savetab];
-1 "Done. Query it back later with, e.g.: system \"l ",(1_string monroot),"\"; select from ",(string savetab)," where date=<d>";

exit 0
