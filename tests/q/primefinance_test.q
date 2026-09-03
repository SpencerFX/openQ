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

/ .prime.expo.build: two active borrows against PB (AAPL 100000@190,
/ NVDA 90000@900), one expired borrow that must be excluded, and one
/ lender (BANKA) with no borrows at all that must not appear
borrows:([] timestamp:now,now,now; client:`FUND1`FUND3`FUND1;
  sym:`AAPL`NVDA`TSLA; lender:`PB`PB`PB;
  qty:100000 90000 50000; feeBp:25 15 40f;
  expiry:(now+1D;now+1D;now-1D));  / TSLA borrow already expired
market:([] sym:`AAPL`NVDA; close:190 900f; ccy:`USD`USD);
lenders:([lender:`PB`BANKA] creditRating:`AAA`AA;
  creditLimit:500000000 250000000f; marginFactor:0.02 0.03);

/ NOTE: `exp` is a reserved q builtin (exponential function) - assigning
/ to it raises 'assign exactly like `desc`/`last`/`vs` do (see
/ q_kdb_gotchas memory) - `expo` sidesteps it.
expo:0!.prime.expo.build[borrows;lenders;market;now];
if[1<>count expo;'"exposure row count failed (expired borrow/no-data lender leaked in, or PB rows split unexpectedly)"];
if[`PB<>first expo`lender;'"exposure lender failed"];
/ AAPL 100000*190 + NVDA 90000*900 = 19,000,000 + 81,000,000 = 100,000,000
if[100000000f<>first expo`grossExposure;'"exposure gross notional failed"];
if[`AAA<>first expo`creditRating;'"exposure lender lookup (linked column) failed"];
/ 100,000,000 / 500,000,000 = 0.2 - well under limit
if[first expo`breach;'"exposure breach falsely flagged"];
if[(abs 0.2f-first expo`utilizationPct)>0.001;'"exposure utilization failed"];

/ a lender the reference table doesn't know about degrades to nulls, not an error
unknownLenderBorrow:([] timestamp:enlist now; client:enlist`FUND1;
  sym:enlist`AAPL; lender:enlist`NEWCP; qty:enlist 10000;
  feeBp:enlist 30f; expiry:enlist now+1D);
expo2:0!.prime.expo.build[unknownLenderBorrow;lenders;market;now];
if[not null first expo2`creditLimit;'"unrecognized-lender exposure should have a null creditLimit"];
if[first expo2`breach;'"unrecognized-lender exposure should not be flagged as a breach"];

-1 "prime finance analytics tests passed";
exit 0;
