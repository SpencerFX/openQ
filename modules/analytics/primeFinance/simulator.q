//====================================================================
// Directory: modules/analytics/primeFinance/simulator.q
//
// About:
// Drives a running primefinance module through a realistic sequence of
// events and prints what the CEP ends up holding. inventory/position/
// borrow/recall publish onto the real tp -> cep wire; locate requests are
// driven straight into the CEP over functional IPC (.prime.allocate/
// .prime.newLocate is never wired to an incoming event), same as a real
// OMS/allocation caller would reach a running CEP.
//
// Run (needs a live primefinance_tp + primefinance_cep, e.g. via
// scripts/startupAllByModule.sh primefinance):
//   q modules/analytics/primeFinance/simulator.q [-tpaddr :host:port] [-cepaddr :host:port]
// Defaults match cfg_proc/modules/primefinance/{tp,cep}.json's ports.
//====================================================================

args:.Q.opt .z.x;
tpaddr:$[`tpaddr in key args;first args`tpaddr;":localhost:5070"];
cepaddr:$[`cepaddr in key args;first args`cepaddr;":localhost:5074"];

tph:hopen `$tpaddr;
ceph:hopen `$cepaddr;

now:.z.p;

//---------------------------------------------------------------
// 1) Inventory: 4 symbols across 3 lenders each, varied economics
//---------------------------------------------------------------
syms:`AAPL`AAPL`AAPL`TSLA`TSLA`TSLA`GME`GME`NVDA`NVDA`NVDA;
invTbl:([]
  timestamp:(count syms)#now;
  sym:syms;
  lender:`PB`BANKA`BANKB`PB`BANKA`BANKC`PB`BANKB`PB`BANKA`BANKC;
  available:80000 40000 60000 30000 20000 15000 5000 3000 90000 50000 70000;
  feeBp:25 45 30 75 110 95 450 500 15 30 20f;
  termDays:1 5 2 1 3 5 1 1 1 5 2;
  recallRisk:.05 .10 .08 .05 .10 .30 .40 .55 .03 .08 .05;
  counterpartyRisk:.05 .10 .08 .05 .10 .20 .25 .30 .05 .10 .05;
  minLot:1000 1000 500 500 500 500 100 100 1000 1000 500);

tph (`upd;`inventory;{invTbl x} each cols invTbl);
-1 "published ",(string count invTbl)," inventory row(s)";

//---------------------------------------------------------------
// 2) Positions: a few clients short various names, some heavily so
//---------------------------------------------------------------
/ column order matches schema_primefinance.q's position table exactly -
/ upd zips positionally, so a mismatch here silently swaps values
posTbl:([]
  timestamp:5#now;
  sym:`AAPL`TSLA`GME`NVDA`NVDA;
  client:`FUND1`FUND1`FUND2`FUND3`FUND2;
  qty:-120000 -35000 -6000 -90000 -20000;
  avgPx:190 250 18 900 900f);

tph (`upd;`position;{posTbl x} each cols posTbl);
-1 "published ",(string count posTbl)," position row(s)";

//---------------------------------------------------------------
// 3) Locate requests - driven straight into the CEP over IPC, against
//    the live .prime.inventory the wire publish above just populated.
//---------------------------------------------------------------
ceph "runLocate:{[locateID;client;sym;requested;priority;constraints]",
  ".prime.newLocate[locateID;client;sym;requested;priority;.prime.inventory;constraints;.z.p+0D00:30:00]}";

constraints:([] lender:`PB`BANKA;maxQty:60000 30000);

-1 "";
-1 "locate results (.prime.newLocate, run on the CEP over IPC):";
-1 "  FUND1 / AAPL, requested 120000:";
show ceph(`runLocate;9001j;`FUND1;`AAPL;120000;95;constraints);
-1 "  FUND1 / TSLA, requested 35000:";
show ceph(`runLocate;9002j;`FUND1;`TSLA;35000;80;constraints);
-1 "  FUND2 / GME, requested 6000 (thin inventory - expect a gap):";
show ceph(`runLocate;9003j;`FUND2;`GME;6000;60;constraints);
-1 "  FUND3 / NVDA, requested 90000:";
show ceph(`runLocate;9004j;`FUND3;`NVDA;90000;70;constraints);

//---------------------------------------------------------------
// 3b) Borrows: realized borrows against two locates above, so
//     .prime.expo.build has real active exposure to show. Column order
//     matches schema_primefinance.q's borrow table exactly (upd zips positionally).
//---------------------------------------------------------------
borrowTbl:([]
  timestamp:2#now;
  sym:`AAPL`NVDA;
  client:`FUND1`FUND3;
  lender:`PB`PB;
  qty:100000 90000;
  feeBp:25 15f;
  expiry:2#now+1D);

tph (`upd;`borrow;{borrowTbl x} each cols borrowTbl);
-1 "published ",(string count borrowTbl)," borrow row(s)";

//---------------------------------------------------------------
// 4) Recall: pull back part of PB's AAPL reservation from FUND1's locate
//---------------------------------------------------------------
tph (`upd;`recall;(enlist now;enlist `AAPL;enlist `PB;enlist 20000j;enlist `HIGH;enlist now+0D00:15:00));
-1 "";
-1 "published 1 recall against PB/AAPL";

//---------------------------------------------------------------
// 5) Pull the CEP's resulting state back and show it
//---------------------------------------------------------------
-1 "";
-1 "=== CEP state after simulation ===";
-1 "";
-1 ".prime.inventory (relayed + recorded):";
show ceph "select from .prime.inventory";
-1 "";
-1 ".prime.positions (relayed + recorded):";
show ceph "select from .prime.positions";
-1 "";
-1 ".prime.locates (results of the newLocate calls above):";
show ceph "select from .prime.locates";
-1 "";
-1 ".prime.reservations (active holds from those allocations):";
show ceph "select from .prime.reservations";
-1 "";
-1 ".prime.alerts (LOCATE_GAP / RECALL / BUYIN, if any):";
show ceph "select from .prime.alerts";
-1 "";
-1 "coverage by client,sym (.prime.positionCoverage against live state):";
show ceph "0!.prime.positionCoverage[.prime.positions;.prime.locates;.z.p]";

/ cep.q's own market refresh already ran once at CEP boot, before the
/ borrows above existed - trigger it again now so exposure reflects them
/ without waiting for the next 5-minute timer tick.
ceph (`.primeMod.market.refresh;::);
-1 "";
-1 "lender exposure (.prime.exposure, rebuilt against the borrows just published):";
show ceph "select from .prime.exposure";

hclose tph;
hclose ceph;
-1 "";
-1 "simulation complete";
exit 0;
