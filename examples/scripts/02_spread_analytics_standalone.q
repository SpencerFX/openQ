//====================================================================
// 02_spread_analytics_standalone.q
//
// The domain analytics libraries under modules/analytics/*/*.q are pure
// batch functions with no IPC and no live state of their own - this
// script proves it by loading spread.q directly and running it against
// a hand-built table, with no tickerplant, CEP, or any other process
// running at all. The exact same functions used here are what
// modules/analytics/spread/cep.q calls in real time off a live quote
// feed (see .spread.onQuote).
//
// No prerequisites. Run from the repo root:
//   q examples/scripts/02_spread_analytics_standalone.q
//====================================================================

system "l modules/analytics/spread/spread.q";

//---------------------------------------------------------------
// A quoted spread is built from seven named components
// (.spread.componentCols) rather than a single bid/ask number - the
// same accounting a real pricing engine keeps for "why is this quote
// this wide right now".
//---------------------------------------------------------------
-1 "spread components: ",", " sv string .spread.componentCols;

quotes:([]
  time:2#.z.p;
  sym:`AAPL`GME;
  aggression:`low`low;
  marketStatus:`normal`stressed;
  weight:1 1f;
  refSprd:     0.00020 0.00400;
  baseSprd:    0.00010 0.00200;
  clientSprd:  0.00010 0.00150;
  volSprd:     0.00010 0.00300;
  smoothSprd:  0.00005 0.00100;
  fallbackSprd:0.00002 0.00050;
  alphaSprd:   0.00003 0.00080);

//---------------------------------------------------------------
// .spread.compose sums the named components into one totalSprd -
// GME's components are individually wider than AAPL's, so the total
// comes out roughly 20x wider too.
//---------------------------------------------------------------
composed:.spread.compose quotes;
-1 "";
-1 "=== composed (totalSprd added) ===";
show composed;

//---------------------------------------------------------------
// .spread.decompose melts each row into one row per component, with
// its bp contribution and % of the total - the shape a stacked-bar
// attribution chart would want.
//---------------------------------------------------------------
decomposed:.spread.decompose quotes;
-1 "";
-1 "=== decomposed (one row per component) - GME only ===";
show select from decomposed where sym=`GME;

//---------------------------------------------------------------
// .spread.waterfall shows the running build-up, component by
// component, from the reference spread up to the full quoted spread -
// cum_alphaSprd always equals totalSprd by construction.
//---------------------------------------------------------------
wf:.spread.waterfall quotes;
-1 "";
-1 "=== waterfall (cumulative build-up) ===";
show select sym,cum_refSprd,cum_baseSprd,cum_clientSprd,cum_alphaSprd,totalSprd from wf;

//---------------------------------------------------------------
// .spread.wavgBy weight-averages by any set of key columns - here,
// weighted by `weight (1 for both rows, so this is a plain average),
// grouped by sym.
//---------------------------------------------------------------
bySym:.spread.wavgBy[quotes;enlist `sym];
-1 "";
-1 "=== weighted-average by sym ===";
show 0!bySym;

exit 0
