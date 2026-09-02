// Example scenario for the stateful locate engine.
// Run:
//   q tests/q/primefinance_scenario.q

system "l modules/analytics/primeFinance/primeFinance.q";

now:.z.p;
.prime.inventory:([] timestamp:(now+0D00:00:01*til 6);
  sym:`TSLA`TSLA`TSLA`TSLA`TSLA`TSLA;
  lender:`PB`BANKA`BANKB`PB`BANKA`BANKB;
  available:50000 30000 40000 25000 25000 20000;
  feeBp:75 110 95 80 115 105f;
  termDays:1 3 5 1 3 5;
  recallRisk:.05 .10 .20 .08 .12 .25;
  counterpartyRisk:.05 .10 .15 .05 .10 .20;
  minLot:1000 1000 1000 1000 1000 1000);

constraints:([] lender:`PB`BANKA`BANKB;maxQty:50000 30000 40000);

alloc:.prime.newLocate[
  9001j;`ALPHA;`TSLA;90000;95;
  .prime.inventory;constraints;now+0D00:30:00];

-1 "allocation:";
show alloc;

-1 "coverage after locate:";
p:([] timestamp:enlist now;client:enlist`ALPHA;sym:enlist`TSLA;qty:enlist -90000;avgPx:enlist 300f);
show .prime.positionCoverage[p;.prime.locates;now];

-1 "simulating recall...";
.prime.applyRecall[`BANKB;`TSLA;15000;`HIGH;now+0D00:10:00];
show .prime.alerts;

-1 "simulating expired borrow...";
.prime.borrows:([]timestamp:enlist now;client:enlist`ALPHA;sym:enlist`TSLA;
  lender:enlist`PB;qty:enlist 20000;feeBp:enlist 150f;expiry:enlist now-0D00:01:00);
.prime.sweep now;
show .prime.buyins;
exit 0;
