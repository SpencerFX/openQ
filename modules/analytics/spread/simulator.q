//====================================================================
// Directory: modules/analytics/spread/simulator.q
//
// About:
// Publishes realistic spreadQuote rows onto a live spread_tp for the
// shared "desk" universe used across spread/markout/primefinance -
// symbols AAPL/TSLA/GME/NVDA (the same symbols
// modules/analytics/primeFinance/simulator.q already established) - so
// running all three modules' simulators together tells one coherent
// story, not three unrelated demos. See README's "Desk Risk & TCA"
// section.
//
// GME is deliberately quoted far wider than AAPL/TSLA/NVDA, matching
// its already-established identity elsewhere in that same universe as
// the hard-to-borrow, high-feeBp/recallRisk name in primefinance's
// inventory data - "illiquid name costs more to trade AND more to
// finance" is the point of the unified narrative, not a coincidence.
// The report aggregates by symbol only (see deskRisk.q, in the sibling
// modules/analytics/report/ directory) - no per-client breakdown.
//
// Run (needs a live spread_tp, e.g. via
// scripts/startStop/startupAllByModule.sh spread):
//   q modules/analytics/spread/simulator.q [-tpaddr :host:port]
// Default matches cfg_proc/modules/spread/tp.json's port.
//====================================================================

args:.Q.opt .z.x;
tpaddr:$[`tpaddr in key args;first args`tpaddr;":localhost:5055"];

tph:hopen `$tpaddr;

now:.z.p;

//---------------------------------------------------------------
// Per-symbol quote economics, price-fraction units matching
// spread.q's (its own sibling file) convention. GME is roughly 15-20x wider
// than AAPL across every component.
//---------------------------------------------------------------
symTab:([]
  sym:`AAPL`TSLA`GME`NVDA;
  refSprd:     0.00020 0.00040 0.00400 0.00030;
  baseSprd:    0.00010 0.00020 0.00200 0.00015;
  clientSprd:  0.00010 0.00015 0.00150 0.00012;
  volSprd:     0.00010 0.00020 0.00300 0.00015;
  smoothSprd:  0.00005 0.00010 0.00100 0.00007;
  fallbackSprd:0.00002 0.00003 0.00050 0.00003;
  alphaSprd:   0.00003 0.00005 0.00080 0.00004);

//---------------------------------------------------------------
// Final publish table, columns in schema_spread.q's exact order -
// upd zips incoming data against the schema's own column order
// positionally, so a mismatch here would silently swap values
//---------------------------------------------------------------
n:count symTab;
quotes:([]
  timestamp:n#now;
  sym:symTab`sym;
  aggression:n#`low;
  marketStatus:?[symTab[`sym]=`GME;`stressed;`normal];
  weight:n#1f;
  refSprd:symTab`refSprd;
  baseSprd:symTab`baseSprd;
  clientSprd:symTab`clientSprd;
  volSprd:symTab`volSprd;
  smoothSprd:symTab`smoothSprd;
  fallbackSprd:symTab`fallbackSprd;
  alphaSprd:symTab`alphaSprd);

tph (`upd;`spreadQuote;{quotes x} each cols quotes);
-1 "published ",(string n)," spreadQuote row(s) across ",
  (string count distinct quotes`sym)," symbols";

hclose tph;
-1 "simulation complete";
exit 0;
