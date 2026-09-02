//====================================================================
// Directory: modules/analytics/markout/simulator.q
//
// About:
// Publishes a trade+order per symbol, then a short sequence of rate
// ticks over the following few minutes, onto a live markout_tp - for
// the same "desk" universe primefinance's simulator already established
// (AAPL/TSLA/GME/NVDA), using the SAME trade rates as primefinance's own
// simulated positions' avgPx, so the numbers agree across modules, not
// just the symbols. The report aggregates by symbol only (see deskRisk.q
// in the sibling modules/analytics/report/ directory) - no per-client
// breakdown. See README's "Desk Risk & TCA" section.
//
// This module's own cep.q's .markoutMod.onRate feeds the same `rate`
// wire table to BOTH .markout.onRate and .impact.onBook, so one rate
// stream drives both analyses - no separate `book` table exists.
//
// GME (thin/illiquid, matching its already-established identity as the
// hard-to-borrow name in primefinance's inventory data) is given a much
// larger post-trade price drift than AAPL/TSLA/NVDA, so "the market
// moves further against us on the illiquid name" is coherent with the
// wider spreads modules/analytics/spread/simulator.q gives it and the
// worse borrow economics primefinance already has for it.
//
// The rate ticks are timestamped explicitly (not wall-clock .z.p) far
// enough past markOutImpact.q's (its own sibling file) grid points -
// .impact.gridSecs tops out at 60s, .markout.gridSecs includes an exact
// 300s (5 min) point - so both the live CEP's real-time completion AND
// a later batch .markout.calc/.impact.calc re-run against the raw RDB
// data (which is what deskRisk.q actually does - see
// modules/analytics/report/cep.q) have real matched data at both
// points, without any real wall-clock wait.
//
// Run (needs a live markout_tp, e.g. via
// scripts/startupAllByModule.sh markout):
//   q modules/analytics/markout/simulator.q [-tpaddr :host:port]
// Default matches cfg_proc/modules/markout/tp.json's port.
//====================================================================

args:.Q.opt .z.x;
tpaddr:$[`tpaddr in key args;first args`tpaddr;":localhost:5030"];

tph:hopen `$tpaddr;

now:.z.p;

//---------------------------------------------------------------
// Trades + orders: one per symbol, rate matching primefinance's own
// simulated position avgPx for the same symbol
//---------------------------------------------------------------
syms:`AAPL`TSLA`GME`NVDA;
rates:190 250 18 900f;

trades:([]
  timestamp:4#now;
  sym:syms;
  tradeID:7001 7002 7003 7004;
  price:rates);

orders:([]
  timestamp:4#now;
  sym:syms;
  orderID:8001 8002 8003 8004;
  price:rates;
  side:4#`buy);

tph (`upd;`trade;{trades x} each cols trades);
-1 "published ",(string count trades)," trade row(s)";
tph (`upd;`order;{orders x} each cols orders);
-1 "published ",(string count orders)," order row(s)";

//---------------------------------------------------------------
// Rate ticks over the next few minutes - AAPL/TSLA/NVDA drift only
// slightly from their trade rate; GME drifts hard (illiquid name, wide
// market moves). Last tick lands 0.5s BEFORE the exact 300s (5-minute)
// grid point deskRisk.q (in the sibling modules/analytics/report/
// directory) reads for markout: .markout.calc
// asof-joins each grid's target time against rate (aj matches the
// latest tick at-or-before the target, never a later one), and only
// accepts a match within 2 seconds of that target before flagging it
// stale (see .markout.calc's own `stale` check) - so the tick has to
// land just before 300s, not after it.
//---------------------------------------------------------------
offsets:0D00:00:01 0D00:00:30 0D00:01:05 0D00:04:59.500;
driftMag:.05 .10 1.20 .50f; / GME (1.20) drifts ~12x AAPL's .05

mkRateTicks:{[now;offsets;sym;rate;mag]
  n:count offsets;
  steps:1+til n;
  ([] timestamp:now+offsets; sym:n#sym; mid:rate+mag*steps%n)
 };

/ each doesn't splat a tuple into separate function args - index into
/ the four parallel vectors explicitly rather than zipping them first
rateTicks:raze {[now;offsets;syms;rates;driftMag;i]
  mkRateTicks[now;offsets;syms i;rates i;driftMag i]
 }[now;offsets;syms;rates;driftMag] each til count syms;

tph (`upd;`rate;{rateTicks x} each cols rateTicks);
-1 "published ",(string count rateTicks)," rate tick(s) across ",
  (string count syms)," symbols, spanning ",(string last offsets)," past each trade";

hclose tph;
-1 "simulation complete";
exit 0;
