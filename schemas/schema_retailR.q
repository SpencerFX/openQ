// schemas/schema_retailR.q
//
// Schema stubs for the EXPANDED retail-brokerage HDB (C:/data/r) - the
// same MetaTrader "Signals" copy-trading dataset schema_retail.q already
// covers (now split out as trade_mql/equity_mql/growth_mql/sig_mql -
// unchanged shape, plus 2 new sig columns: broker, server), UNIONED with a
// second platform, myfxbook (trade_myfxbook/equity_myfxbook/
// growth_myfxbook/sig_myfxbook - a different column shape entirely, no
// MT-style pending-order/cancel concept), and pre-merged by the ingest
// pipeline into three combined tables this schema actually declares:
// `trade`, `equity`, `growth` (a `platform`+`acctId` pair in place of a
// single mql-only `signalId`). Also present on disk but NOT declared here
// (mirrors schema_efx_bars.q's "narrower than the full archive" stance -
// nothing below reads them): the per-platform trade_mql/trade_myfxbook/
// equity_mql/equity_myfxbook/growth_mql/growth_myfxbook splits (superseded
// by the merged tables below, kept on disk for anyone who wants the raw
// per-platform feed) and snap_mql/snap_myfxbook (rich pre-aggregated daily
// provider snapshots - 50+ columns of stats the platforms compute
// themselves - not consumed by anything here yet, a natural next
// analytics source).
//
// modules/analytics/brokerTech/brokerTechSourceR.q is the adapter that
// makes this expanded, two-platform shape look like schema_retail.q's
// original single-platform one to the UNCHANGED modules/analytics/
// brokerTech/brokerTech.q analytics: it overrides that file's `.brk.src.*`
// window-pull functions to synthesize a collision-free `signalId` from
// (platform;acctId), backfill myfxbook's missing kind/cancelled/orderType
// (it has no pending-order concept - every row is a real fill), and union
// sig_mql + sig_myfxbook into the same 9-column `sig` shape schema_retail.q
// declared. See that file's header for the full mql<->myfxbook column
// mapping and why.
.oq.schema.info.retailR.loaded:0b;

// Partitioned, pre-merged across both platforms by the ingest pipeline -
// same trade fact-table role as schema_retail.q's `trade`, plus platform/
// acctId (the merge key) and a handful of myfxbook-native columns
// (username/systemName/ticket/pips/gainPct/durationSec) that are simply
// blank on mql rows.
trade:([] platform:`symbol$(); acctId:`long$(); tradeKey:`symbol$(); kind:`symbol$();
  action:`symbol$(); orderType:`symbol$(); symbol:`symbol$();
  openTime:`timestamp$(); closeTime:`timestamp$();
  openPrice:`float$(); closePrice:`float$(); sl:`float$(); tp:`float$();
  volume:`float$(); commission:`float$(); swap:`float$(); profit:`float$();
  cancelled:`long$(); comment:`symbol$(); collectedAt:`timestamp$();
  username:`symbol$(); systemName:`symbol$(); ticket:`symbol$();
  pips:`float$(); gainPct:`float$(); durationSec:`long$());

// Intraday for mql, one EOD snapshot per day for myfxbook (ts = midnight of
// `date` on those rows) - balance/equity are also simply null for every
// myfxbook row (that platform's public pages don't expose the raw $
// figures, only growthPct - see `growth` below).
equity:([] platform:`symbol$(); acctId:`long$(); ts:`timestamp$();
  balance:`float$(); equity:`float$());

growth:([] platform:`symbol$(); acctId:`long$(); growthPct:`float$());

// Not partitioned - provider identity, one platform each (see the header:
// these two are unioned into a `sig`-shaped table by
// brokerTechSourceR.q's .brk.src.sig, not declared as a merged table here
// since nothing on disk merges them the way trade/equity/growth are).
sig_mql:([] signalId:`long$(); mtVersion:`long$(); name:`symbol$();
  authorLogin:`symbol$(); authorName:`symbol$(); accountType:`symbol$();
  url:`symbol$(); firstSeen:`timestamp$(); lastSeen:`timestamp$();
  broker:`symbol$(); server:`symbol$());

sig_myfxbook:([] systemId:`long$(); username:`symbol$(); systemName:`symbol$();
  displayName:`symbol$(); url:`symbol$(); firstSeen:`timestamp$(); lastSeen:`timestamp$());

//@func   | .oq.schema.tables
//@return | 11 | This schema's declared table set (see header for what's on disk but omitted)
.oq.schema.tables:{[] `trade`equity`growth`sig_mql`sig_myfxbook};

.oq.schema.info.retailR.loaded:1b;
