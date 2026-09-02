//====================================================================
// Directory: modules/analytics/report/deskRisk.q
//
// About:
// Unifies three independent analytics libraries - spread.q (quoted
// spread build-up, modules/analytics/spread/), markOutImpact.q (trade
// markout / order impact, modules/analytics/markout/), and
// primeFinance.q (securities-lending financing/coverage,
// modules/analytics/primeFinance/) - into one "Desk Risk & TCA" report,
// by symbol: what it costs to trade a name (spread), how the market
// moved against the desk afterward (markout/impact), and whether the
// resulting position can actually be financed (primefinance). See
// README's "Desk Risk & TCA" section.
//
// This is general-purpose the same way the three libraries it wraps
// are: every function here takes already-fetched tables as explicit
// arguments and does no IPC of its own - modules/analytics/report/
// cep.q is the only thing that knows where spread/markout/primefinance's
// data actually live and pulls it. None of the three underlying
// libraries are modified - all reuse is via their existing pure batch
// functions (.spread.wavgBy, .markout.calc, .impact.calc,
// .prime.positionCoverage, .prime.coverageBucket).
//
// Deliberately symbol-only, not client-level: none of the three wire
// schemas carry a client-attributable dimension spread/markout could
// group by (primeFinance's position/locate tables do have `client`, but
// .deskRisk.coverageBySym rolls that up to sym before combining, so
// every piece of the final report shares the same grain).
//
// Loaded from core/ (this file is only ever loaded by
// modules/analytics/report/cep.q, via `system "l
// ../modules/analytics/report/deskRisk.q"`, matching how every other
// module's cep.q loads its own analytics library) - so its own internal
// loads are core-relative too.
//====================================================================
system "l ../modules/analytics/spread/spread.q";
system "l ../modules/analytics/markout/markOutImpact.q";
system "l ../modules/analytics/primeFinance/primeFinance.q";

.oq.info.deskRisk.loaded:0b;

//@func   | .deskRisk.spreadBySym
//@param  | quotes | 98 | spreadQuote-shaped table (timestamp,sym,aggression,marketStatus,weight,+7 components)
//@return | 98 | sym,spreadCostBp
//@desc
//Weighted-average quoted spread per symbol, in bp. Reuses .spread.wavgBy
//(compose + weighted-average by arbitrary keys) unchanged.
//@desc
.deskRisk.spreadBySym:{[quotes]
  t:0!.spread.wavgBy[quotes;enlist `sym];
  select sym,spreadCostBp:1e4*totalSprd from t
 };

//@func   | .deskRisk.markoutBySym
//@param  | trades | 98 | trade-shaped table (timestamp,sym,tradeID,price)
//@param  | rate   | 98 | rate-shaped table (timestamp,sym,mid)
//@return | 98 | sym,markoutBp
//@desc
//Markout at the 5-minute grid point (.markout.gridSecs' exact 300s
//point), averaged by symbol, in bp. .markout.calc's own final select
//narrows to tradeID/grids/markoutVal/matchedTime/stale (sym doesn't
//survive), so sym is rejoined afterward from the original trades table.
//@desc
.deskRisk.markoutBySym:{[trades;rate]
  t:0!select tradeID,sym,tradeTime:timestamp,tradeRate:price from trades;
  r:0!select sym,time:timestamp,mid from rate;
  res:.markout.calc[t;r];
  flat:ungroup 0!res;
  flat:flat lj `tradeID xkey select tradeID,sym from t;
  sel:select from flat where grids=300,not stale;
  0!select markoutBp:1e4*avg markoutVal by sym from sel
 };

//@func   | .deskRisk.impactBySym
//@param  | orders | 98 | order-shaped table (timestamp,sym,orderID,price,side)
//@param  | rate   | 98 | rate-shaped table (timestamp,sym,mid) - same feed markout uses
//@return | 98 | sym,impactBp
//@desc
//Order impact at the 60-second grid point (.impact.gridSecs' last
//point), averaged by symbol, in bp. Unlike .markout.calc, .impact.calc's
//final statement is an update (no narrowing select), so sym survives
//the call automatically - no rejoin needed here.
//@desc
.deskRisk.impactBySym:{[orders;rate]
  o:0!select orderID,sym,side,orderTime:timestamp,orderRate:price from orders;
  bk:0!select sym,time:timestamp,mid from rate;
  res:.impact.calc[o;bk];
  sel:select from res where offsetSec=60;
  0!select impactBp:1e4*avg impact by sym from sel
 };

//@func   | .deskRisk.financingBySym
//@param  | inventory    | 98 | inventory-shaped table (timestamp,sym,lender,available,feeBp,...)
//@param  | reservations | 98 | .prime.reservations-shaped table
//@return | 98 | sym,financingFeeBp
//@desc
//Qty-weighted average borrow fee across active reservations, by symbol -
//the latest feeBp per (sym,lender) at the time this is called, joined
//to whichever lenders are actually reserved against. An approximation:
//a lender's feeBp can move after a reservation is made; this reports
//today's rate for whoever's currently holding the position, not the
//rate actually locked in at allocation time.
//@desc
.deskRisk.financingBySym:{[inventory;reservations]
  latestInv:0!select feeBp:last feeBp by sym,lender from inventory;
  active:select from reservations where status=`ACTIVE;
  joined:active lj `sym`lender xkey latestInv;
  0!select financingFeeBp:wavg[qty;feeBp] by sym from joined
 };

//@func   | .deskRisk.coverageBySym
//@param  | positions | 98 | position-shaped table (timestamp,client,sym,qty,avgPx)
//@param  | locates   | 98 | locate-shaped table
//@param  | now       | -12 | as-of timestamp
//@return | 98 | sym,shortQty,locatedQty,coverage,bucket
//@desc
//.prime.positionCoverage is client,sym-keyed (primeFinance's own
//position/locate tables carry client) - rolled up to sym alone here so
//it shares the same grain as the rest of this report.
//@desc
.deskRisk.coverageBySym:{[positions;locates;now]
  raw:0!.prime.positionCoverage[positions;locates;now];
  agg:0!select shortQty:sum shortQty, locatedQty:sum locatedQty by sym from raw;
  agg:update coverage:?[shortQty=0;0f;locatedQty%shortQty] from agg;
  update bucket:.prime.coverageBucket each coverage from agg
 };

//@func   | .deskRisk.report
//@param  | d | 99 | dict with keys quotes/trades/orders/rate/positions/
//               locates/inventory/reservations/now (one q lambda can
//               only take 8 named params, and this needs 9 - see the
//               dict-argument idiom below)
//@return | 98 | sym,spreadCostBp,markoutBp,impactBp,financingFeeBp,shortQty,locatedQty,coverage,bucket
//@desc
//One row per symbol seen anywhere across the five inputs - left-joined
//onto that full symbol set so a symbol missing from one domain (e.g. no
//trade yet) shows nulls there rather than being silently dropped.
//@desc
.deskRisk.report:{[d]
  s:.deskRisk.spreadBySym[d`quotes];
  m:.deskRisk.markoutBySym[d`trades;d`rate];
  i:.deskRisk.impactBySym[d`orders;d`rate];
  f:.deskRisk.financingBySym[d`inventory;d`reservations];
  c:.deskRisk.coverageBySym[d`positions;d`locates;d`now];
  allSyms:distinct raze (exec sym from s;exec sym from m;exec sym from i;exec sym from f;exec sym from c);
  base:([] sym:allSyms);
  base:base lj `sym xkey s;
  base:base lj `sym xkey m;
  base:base lj `sym xkey i;
  base:base lj `sym xkey f;
  base:base lj `sym xkey c;
  0!base
 };

.oq.info.deskRisk.loaded:1b;
