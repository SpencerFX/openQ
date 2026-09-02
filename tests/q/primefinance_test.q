// Standalone analytics tests.
// Run from the openQ root:
//   q tests/q/primefinance_test.q

system "l modules/analytics/primeFinance/primeFinance.q";

now:.z.p;
invTbl:([] timestamp:(now+0D00:00:01*til 3);
  sym:`AAPL`AAPL`AAPL;
  lender:`PB`LENDER_A`LENDER_B;
  available:50000 30000 50000;
  feeBp:35 42 38f;
  termDays:1 5 2;
  recallRisk:.05 .10 .30;
  counterpartyRisk:.05 .10 .20;
  minLot:1000 1000 1000);

constraints:([] lender:`PB`LENDER_A;maxQty:40000 30000);

a:.prime.allocate[1001j;`FUND1;`AAPL;70000;invTbl;90;constraints];
if[70000j<>sum a[`allocated];'"allocation failed"];

pos:([] timestamp:now;client:`FUND1`FUND1`FUND2;
  sym:`AAPL`TSLA`AAPL;qty:-100000 -50000 -25000;avgPx:200 300 200);

loc:([] timestamp:now;locateID:1 2 3;client:`FUND1`FUND1`FUND2;
  sym:`AAPL`TSLA`AAPL;requested:100000 50000 25000;
  allocated:100000 25000 10000;
  expiry:(now+1D),(now+1D),(now+1D);
  priority:90 80 70;status:`LOCATED`PARTIAL`PARTIAL);

/ positionCoverage returns a table keyed by client,sym (from its own
/ `select ... by client,sym`) - unkey it before indexing rows by position
covResult:0!.prime.positionCoverage[pos;loc;now];
if[covResult[0;`bucket]<>`FULL;'"coverage full failed"];
/ FUND1/TSLA is 25000 located of 50000 short = 0.5 coverage, which
/ .prime.coverageBucket's own thresholds (>=.8 for PARTIAL) bucket as
/ AT_RISK, not PARTIAL
if[covResult[1;`bucket]<>`AT_RISK;'"coverage partial failed"];
if[covResult[2;`bucket]<>`AT_RISK;'"coverage risk failed"];

cost:.prime.borrowCost[1000000f;125f;30f];
if[(abs cost-1041.6667)>0.01;'"borrow cost failed"];

score:.prime.htbScore[.1f;.9f;850f;.8f;.2f];
if[not score>0.5f;'"htb score failed"];

-1 "prime finance analytics tests passed";
exit 0;
