//====================================================================
// Directory: schemas/schema_retail.q
//
// About:
// Schema stubs matching an existing on-disk retail-brokerage HDB
// (C:/data/retail) - a MetaTrader "Signals" style copy-trading dataset:
// per-provider trade blotters, intraday equity curves, and headline
// growth/monthly-return stats, scraped over ~11 years (2015-2026) into
// date partitions. Same read-only integration shape as schemas/schema_efx.q
// (see the README's "Integrating an existing HDB" section): these tables
// are declared here only so .oq.hdb.loadHDB has something to reload
// against and so a query touching a date with no rows returns empty
// rather than erroring on an undefined global - nothing in openQ/core
// ever writes to these tables or this root.
//
// modules/analytics/brokerTech/ is the analytics layer built on top of
// this: brokerTech.q (pure batch functions - exposure, execution
// quality, client profitability, toxicity, A/B-book routing, revenue
// attribution, risk-threshold alerts) and run.q (loads this root
// read-only and prints the report).
//
// Table roles:
//   sig     - one row per signal provider (the "client account"):
//             identity, MT version, first/last seen. Not partitioned.
//   trade   - the fact table: one row per order (kind=`trade) or ledger
//             entry (kind=`balance). cancelled=1 => a pending order that
//             never executed. Partitioned by date (= scrape/collection
//             date), parted on signalId.
//   equity  - intraday (balance, equity) samples per provider - the
//             drawdown / equity-curve source. Partitioned, parted on signalId.
//   growth  - one running total-growth % per provider per scrape date.
//   monthly - per (provider, year, month) return %, plus that year's
//             running yearlyPct. Not partitioned.
//
// Namespaces:
//   (none of its own - .oq.schema.tables[] is the only convention this
//   file participates in, same as every other schema_*.q)
//====================================================================
.oq.schema.info.loaded:0b;

// Not partitioned - full column set including any key-like columns.
sig:([] signalId:`long$(); mtVersion:`long$(); name:`symbol$();
  authorLogin:`symbol$(); authorName:`symbol$(); accountType:`symbol$();
  url:`symbol$(); firstSeen:`timestamp$(); lastSeen:`timestamp$());

monthly:([] signalId:`long$(); year:`long$(); month:`long$();
  returnPct:`float$(); yearlyPct:`float$());

// Partitioned by date - the virtual `date` column is supplied by the
// partitioned-DB loader, so it's deliberately absent from the stub (same
// as schema_efx.q's own partitioned stubs).
trade:([] tradeKey:`symbol$(); signalId:`long$(); kind:`symbol$();
  action:`symbol$(); orderType:`symbol$(); symbol:`symbol$();
  openTime:`timestamp$(); closeTime:`timestamp$();
  openPrice:`float$(); closePrice:`float$(); sl:`float$(); tp:`float$();
  volume:`float$(); commission:`float$(); swap:`float$(); profit:`float$();
  cancelled:`long$(); comment:`symbol$(); collectedAt:`timestamp$());

equity:([] signalId:`long$(); ts:`timestamp$(); balance:`float$(); equity:`float$());

growth:([] signalId:`long$(); growthPct:`float$());

//@func   | .oq.schema.tables
//@return | 11 | List of table names in this HDB
//@desc
//The retail-brokerage archive's table set
//@desc
.oq.schema.tables:{[] `sig`monthly`trade`equity`growth};

.oq.schema.info.loaded:1b;
