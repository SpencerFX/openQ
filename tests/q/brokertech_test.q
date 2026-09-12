// Standalone brokerTech analytics tests - a synthetic fixture with
// known-shaped providers, asserting the library's core behaviour with no
// HDB, CEP or IPC. Run from the openQ root:
//   q tests/q/brokertech_test.q

system "l schemas/schema_retail.q";
system "l modules/analytics/brokerTech/brokerTech.q";
system "l modules/analytics/brokerTech/predictive.q";

now:2026.06.01D00:00:00.000000000;

// Build a `trade`-shaped executed-order table from parallel vectors.
// px is a (openPrice;closePrice) pair (commission/swap derived from vol -
// q lambdas cap at 8 params). act/ot/px items/vol/pnl broadcast to n.
mkTrades:{[sid;sym;act;ot;hold;px;vol;pnl]
  n:count ot;
  ([] date:`date$ot; tradeKey:`$string sid,'til n; signalId:n#sid; kind:n#`trade;
    action:n#act; orderType:n#?[act=`buy;`Buy;`Sell]; symbol:n#sym;
    openTime:ot; closeTime:ot+hold; openPrice:n#px 0; closePrice:n#px 1;
    sl:n#0f; tp:n#0f; volume:n#vol; commission:-0.3*n#vol; swap:-0.05*n#vol;
    profit:n#pnl; cancelled:n#0j)};

// --- provider 1: CLEAN winner - long holds, ~80% win, modest DD ----
i1:til 40;
p1:mkTrades[1001i;`EURUSD;
  ?[0=i1 mod 3;`sell;`buy];
  now+0D06:00:00*i1; 0D04:00:00;
  ((count i1)#1.10; 1.10+0.0010*?[0=i1 mod 5;-2f;1f]);
  0.10; ?[0=i1 mod 5;-60.0;35.0]];

// --- provider 2: SCALPER + one-sided (all buys, 20-second holds) ---
i2:til 60;
p2:mkTrades[1002i;`GBPUSD;
  `buy;
  now+0D00:02:00*i2; 0D00:00:20;
  (1.27;1.27002);
  0.05; ?[0=i2 mod 4;-3.5;2.0]];

// --- provider 3: MARTINGALE - lot size doubles on the trade *after* a
// loss (0b,-1_ shifts "was the previous trade a loss" onto this row) ---
i3:1+til 30;
loss3:0=i3 mod 3;
vol3:0.01*2 xexp sums 0b,-1_loss3;
p3:mkTrades[1003i;`XAUUSD;
  `buy;
  now+0D02:00:00*i3; 0D01:00:00;
  (2000.0; 2000.0+?[loss3;-5.0;3.0]);
  vol3; ?[loss3;-8.0*vol3%0.01;4.0*vol3%0.01]];

// --- provider 4: LOSING but not toxic - normal holds, net negative -
i4:til 40;
p4:mkTrades[1004i;`USDJPY;
  ?[0=i4 mod 2;`sell;`buy];
  now+0D05:00:00*i4; 0D03:00:00;
  (150.0; 150.0+0.05*?[0=i4 mod 3;1f;-1f]);
  1.0; ?[0=i4 mod 3;20.0;-30.0]];

trades:p1,p2,p3,p4;

// --- equity curves: p1 gentle up, p4 slow bleed, p5 (no trades) blow-up
mkEq:{[sid;eq] n:count eq;
  ([] date:`date$now+0D01:00:00*til n; signalId:n#sid;
    ts:now+0D01:00:00*til n; balance:n#10000f; equity:eq)};
j:til 200;
equ:(mkEq[1001i;10000f+30f*j-5f*j*0=j mod 7]),
    (mkEq[1004i;10000f-25f*j]),
    (mkEq[1005i;10000f*1f-j%180]);

// ================================================================
// 1. perf.bySignal
perf:.brk.perf.bySignal trades;
p1r:first select from perf where signalId=1001i;
if[not p1r[`nTrades]=40;'"perf: p1 trade count"];
if[not p1r[`netProfit]>0;'"perf: p1 should be net positive"];
if[not (first exec netProfit from perf where signalId=1004i)<0;'"perf: p4 should be net negative"];

// 2. tox.score - scalper & martingale must out-score the clean winner
tox:.brk.tox.score[trades;equ];
tget:{[t;sid] first exec toxScore from t where signalId=sid};
if[not tget[tox;1002i]>tget[tox;1001i];'"tox: scalper should score above clean winner"];
if[not tget[tox;1003i]>tget[tox;1001i];'"tox: martingale should score above clean winner"];
if[not (first exec martingaleScore from tox where signalId=1003i)>0.2;'"tox: martingale component too low"];
if[not (first exec oneSidedScore from tox where signalId=1002i)>0.9;'"tox: all-buy account should be ~1 one-sided"];
if[not (first exec scalpScore from tox where signalId=1002i)>0.5;'"tox: scalper scalpScore too low"];

// 3. book.recommend - winner -> A, losing non-toxic -> B
rec:.brk.book.recommend[trades;equ];
rget:{[r;sid] first exec route from r where signalId=sid};
if[not rget[rec;1001i]=`A;'"book: profitable client should route A, got ",string rget[rec;1001i]];
if[not rget[rec;1004i]=`B;'"book: losing non-toxic client should route B, got ",string rget[rec;1004i]];

// 4. book.optimise - split never worse than the best blanket policy
opt:.brk.book.optimise[trades;equ];
if[not opt[`upliftVsBestExtreme]>=-0.0001;'"book: recommended split should not lose vs best extreme"];

// 5. drawdown + alerts - the blow-up (p5) must breach DRAWDOWN
p5dd:first select from .brk.perf.drawdown equ where signalId=1005i;
if[not p5dd[`maxDDPct]<-40;'"drawdown: p5 should show a deep drawdown"];
al:.brk.alert.breaches[trades;equ];
if[not any (al[`signalId]=1005i)&al[`kind]=`DRAWDOWN;'"alert: p5 drawdown breach missing"];

// 6. expo.peakConcurrent - two deliberately overlapping lots (3 + 5 = 8)
ov:([] date:2#`date$now; tradeKey:`a`b; signalId:2#9001i; kind:2#`trade; action:2#`buy;
  orderType:2#`Buy; symbol:2#`TESTFX; openTime:(now;now+0D00:30:00);
  closeTime:(now+0D02:00:00;now+0D02:30:00); openPrice:2#1.0; closePrice:2#1.0;
  sl:2#0f; tp:2#0f; volume:3 5f; commission:2#-1f; swap:2#0f; profit:2#10f; cancelled:2#0j);
if[not 8f=first exec peakConcurrentLots from .brk.expo.peakConcurrent ov;'"peakConcurrent: overlap should sum to 8 lots"];

// 7. exec.cancelRates - half the orders cancelled -> 50%
co:ov,update cancelled:2#1j, tradeKey:`c`d from ov;
if[not 50f=first exec cancelRatePct from .brk.exec.cancelRates co where signalId=9001i;'"cancelRates: expected 50%"];

// 8. broker.* - name parsing + per-broker rollup
bTag:.brk.broker.tagName;
icm:`$"IC Markets";
if[not icm~bTag `$"Scalp IC Markets ECN";'"broker: IC Markets name parse"];
if[not `Pepperstone~bTag `$"R Factor Broker Papperstone";'"broker: Pepperstone typo -> canonical"];
if[not `FPMarkets~bTag `$"R Factor FPMarkets";'"broker: FPMarkets name parse"];
if[not `UNKNOWN~bTag `$"Just A Plain EA Name";'"broker: undisclosed name -> UNKNOWN"];
if[not `UNKNOWN~bTag `$"Magic Trader";'"broker: 'ic' mid-word must not match IC Markets"];

sigFix:([] signalId:1001 1002 1003 1004 1005i;
  name:(`$"Scalp IC Markets ECN";`$"NightVisionEA ICM";`$"Grid EA Pepperstone";`$"Plain Momentum EA";`$"XAU Bot");
  firstSeen:5#now; lastSeen:5#now+30);
bpnl:.brk.broker.pnl[trades;sigFix];
tags:bpnl`brokerTag;
if[not (sum bpnl`nTrades)=count select from trades where kind=`trade, cancelled=0;'"broker.pnl: nTrades must sum to the executed-trade count"];
if[not icm in tags;'"broker.pnl: IC Markets bucket missing (p1 -> IC Markets)"];
if[not `UNKNOWN in tags;'"broker.pnl: UNKNOWN bucket missing (p3/p4 undisclosed)"];
// p1 ("...IC Markets ECN") and p2 ("...ICM") both -> IC Markets, so that
// bucket's revenue must equal p1+p2's own per-signal revenue summed
icRow:first select from bpnl where brokerTag=icm;
icRev:sum exec totalRev from .brk.rev.bySignal select from trades where signalId in 1001 1002i;
if[not 2=icRow`nProviders;'"broker.pnl: IC Markets bucket should hold 2 providers"];
if[not (abs icRow[`totalRev]-icRev)<0.01;'"broker.pnl: IC Markets totalRev should equal p1+p2's summed totalRev"];

bros:.brk.broker.summary[trades;equ;sigFix];
if[not (count bros)=count distinct exec brokerTag from .brk.broker.tag sigFix;'"broker.summary: one row per distinct tag"];
ros:.brk.broker.roster sigFix;
if[not 2=first exec nProviders from ros where brokerTag=`UNKNOWN;'"broker.roster: p3+p4 -> 2 UNKNOWN providers"];

// 9. predictive.q - equityTrend direction on the existing equ fixture
// (1001 gently up, 1004 a steady bleed, 1005 an equity blow-up)
et:.brk.pred.equityTrend equ;
edir:{[t;sid] first exec direction from t where signalId=sid};
if[not edir[et;1001i]=`UP;'"pred.equityTrend: p1 (rising equity) should be UP, got ",string edir[et;1001i]];
if[not edir[et;1004i]=`DOWN;'"pred.equityTrend: p4 (steady bleed) should be DOWN, got ",string edir[et;1004i]];
if[not edir[et;1005i]=`DOWN;'"pred.equityTrend: p5 (blow-up) should be DOWN, got ",string edir[et;1005i]];

// 10. predictive.q - toxTrend runs clean on the multi-day trade fixture
// and produces a well-formed bucket count for a signal with enough
// calendar spread (p1 spans ~10 days - see mkTrades' ot for i1)
tt:.brk.pred.toxTrend[trades;equ];
if[not count tt;'"pred.toxTrend: expected at least one signal with >=2 buckets"];
if[not all tt[`nBuckets]>0;'"pred.toxTrend: nBuckets must be positive"];
if[not all (tt[`curToxScore]>=0) and tt[`curToxScore]<=1;'"pred.toxTrend: curToxScore out of [0;1]"];

// 11. predictive.q - blowupRisk returns a well-formed curve/scores dict;
// every calibration bucket's rate is a valid percentage
br:.brk.pred.blowupRisk[trades;equ];
if[not `curve`scores~key br;'"pred.blowupRisk: expected a `curve`scores dict"];
curve:br`curve;
if[count curve; if[not all (curve[`blowupRatePct]>=0) and curve[`blowupRatePct]<=100;
  '"pred.blowupRisk: blowupRatePct must be a percentage in [0;100]"]];
scores:br`scores;
if[count scores; if[not all (scores[`predictedBlowupProbPct]>=0) and scores[`predictedBlowupProbPct]<=100;
  '"pred.blowupRisk: predictedBlowupProbPct must be a percentage in [0;100]"]];

// 12. predictive.q - revenueForecast / brokerRevenueForecast: sane shape,
// no null slope/r2/emaLevel when there's data to fit
rf:.brk.pred.revenueForecast trades;
if[not rf[`nDays]=count distinct exec date from trades;'"pred.revenueForecast: nDays should match distinct trade dates"];
if[null rf`slopePerDay;'"pred.revenueForecast: slopePerDay should not be null with multi-day data"];
brf:.brk.pred.brokerRevenueForecast[trades;sigFix];
if[not (count brf)=count distinct tags;'"pred.brokerRevenueForecast: one row per distinct broker tag"];

// 13. predictive.q - summary unions every signal seen by its inputs and
// sorts worst-first by predictedBlowupProbPct
sm:.brk.pred.summary[trades;equ];
allIds:distinct raze (exec signalId from tt; exec signalId from et; exec signalId from br`scores);
if[not (asc sm`signalId)~asc allIds;'"pred.summary: should union every signalId from its inputs"];
if[not sm[`predictedBlowupProbPct]~desc sm`predictedBlowupProbPct;'"pred.summary: should be sorted worst-first"];

-1 "brokerTech analytics tests passed";
exit 0;
