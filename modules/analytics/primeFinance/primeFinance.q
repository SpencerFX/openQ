//====================================================================
// openQ Prime Finance / Position Location analytics
//
// Domain module for securities finance:
//   inventory -> locate -> reservation -> borrow -> position coverage
//             -> recall -> buy-in risk -> financing economics
//
// Deterministic, stateful allocator: lender caps, client priority,
// minimum lots, locate expiry, reservations, recall reduction, buy-in
// escalation. All domain state lives here, outside core/.
//====================================================================

// Schema tables + config live in state.q, its own sibling file - loaded
// here rather than by each external caller (cep.q, tests). .z.f can't be
// used to self-locate it: confirmed directly that .z.f inside a file
// reached via a NESTED system"l" still reports the OUTERMOST script's own
// path, not the file currently being loaded - so instead this tries both
// real callers' own relative conventions (cep.q runs from core/, tests
// run from the repo root) and falls back from one to the other.
@[system;"l modules/analytics/primeFinance/state.q";
  {[e] system "l ../modules/analytics/primeFinance/state.q"}];

/-----------------------------
/ Helpers
/-----------------------------

//@func  | .prime.clamp
//@param  | x | float
//@param  | lo | float
//@param  | hi | float
//@desc
// Clamps x into [lo;hi].
//@desc
.prime.clamp:{[x;lo;hi] lo|hi&x};

//@func  | .prime.coverageBucket
//@param  | x | float
//@desc
// Buckets a coverage ratio: FULL(>=1)/PARTIAL(>=0.8)/AT_RISK(>0)/UNLOCATED(0).
//@desc
.prime.coverageBucket:{[x]
  $[x>=1f;`FULL;x>=.8f;`PARTIAL;x>0f;`AT_RISK;`UNLOCATED]};

//@func  | .prime.borrowCost
//@param  | notional | float
//@param  | feeBp | float
//@param  | days | float
//@desc
// Annualized cost: notional*(feeBp/1e4)*(days/dayCount). Parenthesized -
// q has no operator precedence (strictly right-to-left).
//@desc
.prime.borrowCost:{[notional;feeBp;days]
  notional*(feeBp%1e4)*(days%.prime.cfg[`dayCount])};

//@func  | .prime.htbScore
//@param  | availabilityRatio | float
//@param  | utilization | float
//@param  | feeBp | float
//@param  | recallRisk | float
//@param  | rejectRate | float
//@desc
// Weighted sum of 5 risk signals (feeBp normalized/clamped to [0;1]
// first). Each term parenthesized - same right-to-left reason as borrowCost.
//@desc
.prime.htbScore:{[availabilityRatio;utilization;feeBp;recallRisk;rejectRate]
  (.25*(1f-availabilityRatio))
  +(.20*utilization)
  +(.25*.prime.clamp[feeBp%.prime.cfg[`feeNormBp];0f;1f])
  +(.20*recallRisk)
  +(.10*rejectRate)};

/-----------------------------
/ Borrow-fee calibration (feeBp vs. realized vol/ADV from real market data)
/-----------------------------
// Benchmarks each quoted feeBp against real realized vol/ADV (from
// eq_d1_yfinance, via cep.q's refresh) rather than just this book's own
// inventory - the way a real desk sanity-checks its rate card.
// expectedFeeBp is an explicit weighted formula, not a fitted model -
// there's no real observed-fee curve to fit against.

.prime.calib.cfg:`feeFloorBp`feeRangeBp`volWeight`liqWeight`richCheapThresholdBp!
  (15f;800f;0.5;0.5;25f);

//@func  | .prime.calib.percentileOf
//@param  | x   | float | value to rank
//@param  | ref | float list | reference distribution
//@desc
// Fraction of ref strictly below x (0..1). Null-safe: null x or empty
// ref both yield neutral 0.5.
//@desc
.prime.calib.percentileOf:{[x;ref]
  if[null x;:0.5];
  if[0=count ref;:0.5];
  (sum ref<x)%count ref};

//@func  | .prime.calib.expectedFeeBp
//@param  | volPctile | float | 0..1, real-vol percentile
//@param  | advPctile | float | 0..1, real-ADV percentile (higher = more liquid)
//@desc
// Model-implied fee: a floor plus a range scaled by vol percentile and
// illiquidity (1-advPctile), weighted per .prime.calib.cfg.
//@desc
.prime.calib.expectedFeeBp:{[volPctile;advPctile]
  blend:.prime.clamp[
    (.prime.calib.cfg[`volWeight]*volPctile)+(.prime.calib.cfg[`liqWeight]*(1f-advPctile));
    0f;1f];
  .prime.calib.cfg[`feeFloorBp]+.prime.calib.cfg[`feeRangeBp]*blend};

//@func  | .prime.calib.flag
//@param  | richCheapBp | float | feeBp - expectedFeeBp
//@desc
// RICH (fee above model), CHEAP (below), FAIR (within richCheapThresholdBp).
//@desc
.prime.calib.flag:{[richCheapBp]
  th:.prime.calib.cfg[`richCheapThresholdBp];
  $[richCheapBp>th;`RICH;richCheapBp<neg th;`CHEAP;`FAIR]};

//@func  | .prime.calib.build
//@param  | inventory | table | .prime.inventory-shaped (sym,lender,feeBp,...)
//@param  | market    | table | sym,vol,adv - real vol/ADV per sym (cep.q)
//@desc
// One row per (sym,lender): latest feeBp vs. real vol/ADV percentile and
// model-implied fee. Missing market data -> neutral 0.5 percentiles.
//@desc
.prime.calib.build:{[inventory;market]
  / `cols` is reserved (can't be a local name) - colNames avoids it
  colNames:`sym`lender`ccy`feeBp`vol`adv`volPctile`advPctile`expectedFeeBp`richCheapBp`flag;
  if[not count inventory;:0#flip colNames!(`symbol$();`symbol$();`symbol$();`float$();
    `float$();`float$();`float$();`float$();`float$();`float$();`symbol$())];
  latest:0!select feeBp:last feeBp by sym,lender from `timestamp xasc inventory;
  volRef:market`vol; advRef:market`adv;
  r:latest lj `sym xkey select sym,ccy,vol,adv from market;
  r:update
    volPctile:.prime.calib.percentileOf[;volRef] each vol,
    advPctile:.prime.calib.percentileOf[;advRef] each adv
  from r;
  r:update expectedFeeBp:.prime.calib.expectedFeeBp'[volPctile;advPctile] from r;
  r:update richCheapBp:feeBp-expectedFeeBp from r;
  colNames xcols update flag:.prime.calib.flag each richCheapBp from r};

/-----------------------------
/ Position mark-to-market (real close price from real market data)
/-----------------------------
// Marks each position to a real latest close (same `market` table
// .prime.calib.build uses), turning share counts into real $ P&L.

//@func  | .prime.risk.build
//@param  | positions | table | .prime.positions-shaped (client,sym,qty,avgPx,...)
//@param  | market    | table | sym,close - latest real close per sym (cep.q)
//@desc
// One row per (client,sym): currentPx/marketValue/unrealizedPnl (signed,
// correct for both long and short)/pnlPct/side. Missing market data ->
// null marks, not a fabricated number.
//@desc
.prime.risk.build:{[positions;market]
  colNames:`client`sym`ccy`qty`avgPx`currentPx`marketValue`unrealizedPnl`pnlPct`side;
  if[not count positions;:0#flip colNames!(`symbol$();`symbol$();`symbol$();`long$();
    `float$();`float$();`float$();`float$();`float$();`symbol$())];
  latest:0!select qty:last qty, avgPx:last avgPx by client,sym from `timestamp xasc positions;
  r:latest lj `sym xkey select sym,ccy,currentPx:close from market;
  r:update
    marketValue:qty*currentPx,
    unrealizedPnl:qty*(currentPx-avgPx),
    notional:abs qty*avgPx
  from r;
  / notional is its own update step so pnlPct's divide can reference it -
  / ?[cond;a;b] can't bind a name inline for reuse
  r:update pnlPct:?[0=notional;0Nf;unrealizedPnl%notional] from r;
  r:update side:?[qty<0;`SHORT;`LONG] from r;
  colNames xcols delete notional from r};

/-----------------------------
/ Short-interest concentration ("crowded shorts", real ADV from real market data)
/-----------------------------
// Symbol-level, cross-client view: how much of a name is the WHOLE book
// short, and how hard to unwind against real ADV - the "crowded short" lens.

// Days-to-cover thresholds (aggregate shortQty / real ADV)
.prime.crowd.cfg:`lowDTC`medDTC`highDTC!(1f;5f;15f);

//@func  | .prime.crowd.bucket
//@param  | daysToCover | float
//@desc
// LOW/MODERATE/HIGH/EXTREME by .prime.crowd.cfg; null -> UNKNOWN.
//@desc
.prime.crowd.bucket:{[daysToCover]
  $[null daysToCover;`UNKNOWN;
    daysToCover<=.prime.crowd.cfg[`lowDTC];`LOW;
    daysToCover<=.prime.crowd.cfg[`medDTC];`MODERATE;
    daysToCover<=.prime.crowd.cfg[`highDTC];`HIGH;
    `EXTREME]};

//@func  | .prime.crowd.build
//@param  | positions | table | .prime.positions-shaped (client,sym,qty,...)
//@param  | market    | table | sym,close,adv - real close/ADV per sym (cep.q)
//@desc
// One row per symbol with any short: shortQty, numClients, real
// shortValue/daysToCover, bucketed. Missing market data -> UNKNOWN bucket.
//@desc
.prime.crowd.build:{[positions;market]
  colNames:`sym`ccy`shortQty`numClients`close`adv`shortValue`daysToCover`bucket;
  / nested lambda can't see enclosing locals - colNames passed in explicitly
  emptyType:{[cn]0#flip cn!(`symbol$();`symbol$();`long$();`int$();
    `float$();`float$();`float$();`float$();`symbol$())};
  if[not count positions;:emptyType[colNames]];
  / collapse to latest row per (client,sym) first, else short-interest
  / inflates without bound as a snapshot stream
  latest:0!select qty:last qty by client,sym from `timestamp xasc positions;
  short:0!select shortQty:neg sum qty, numClients:`int$count distinct client
    by sym from latest where qty<0;
  if[not count short;:emptyType[colNames]];
  r:short lj `sym xkey select sym,ccy,close,adv from market;
  r:update shortValue:shortQty*close, daysToCover:shortQty%adv from r;
  colNames xcols update bucket:.prime.crowd.bucket each daysToCover from r};

/-----------------------------
/ Counterparty (lender) exposure and credit-limit monitoring
/-----------------------------
// How exposed is this book to each lender, marked to real prices, against
// a real credit limit - the other side of counterpartyRisk-based pricing.

//@func  | .prime.expo.build
//@param  | borrows | table | .prime.borrows-shaped (client,sym,lender,qty,feeBp,expiry,...)
//@param  | lenders | table | .prime.lenders-shaped, keyed by lender
//@param  | market  | table | sym,close,ccy - real latest close per sym (cep.q)
//@param  | now     | timestamp
//@desc
// One row per (lender,ccy) with an active borrow: grossExposure ($, at
// real close), credit fields via a keyed-table lj against .prime.lenders
// (a "linked column", not a true fkey - see .prime.lenders' header),
// marginRequirement, utilizationPct, headroom, breach. Unrecognized
// lender -> nulls, not an error.
//@desc
.prime.expo.build:{[borrows;lenders;market;now]
  colNames:`lender`ccy`grossExposure`creditRating`creditLimit`marginFactor`marginRequirement`utilizationPct`headroom`breach;
  emptyType:{[cn]0#flip cn!(`symbol$();`symbol$();`float$();`symbol$();
    `float$();`float$();`float$();`float$();`float$();`boolean$())};
  if[not count borrows;:emptyType[colNames]];
  active:select from borrows where expiry>now;
  if[not count active;:emptyType[colNames]];
  r:active lj `sym xkey select sym,close,ccy from market;
  r:0!select grossExposure:sum qty*close by lender,ccy from r where not null close;
  if[not count r;:emptyType[colNames]];
  r:r lj lenders;
  r:update marginRequirement:grossExposure*marginFactor from r;
  r:update utilizationPct:?[(0=creditLimit)|null creditLimit;0Nf;grossExposure%creditLimit] from r;
  r:update headroom:creditLimit-grossExposure from r;
  colNames xcols update breach:(not null utilizationPct) and utilizationPct>1f from r};

/-----------------------------
/ Inventory state
/-----------------------------

//@func  | .prime.reservedBy
//@param  | sym | symbol
//@param  | lender | symbol
//@param  | now | timestamp
//@desc
// Qty currently ACTIVE-reserved against one (sym,lender) line. Params
// re-bound to sy/ln first - a where-clause name binds to the table's own
// column, shadowing the param otherwise.
//@desc
.prime.reservedBy:{[sym;lender;now]
  sy:sym;ln:lender;
  exec sum qty from .prime.reservations
    where sym=sy,lender=ln,status=`ACTIVE,expiry>now};

//@func  | .prime.availableNow
//@param  | sym | symbol
//@param  | lender | symbol
//@param  | now | timestamp
//@desc
// Latest inventory snapshot's available qty, minus .prime.reservedBy.
// Returns 0 if there's no inventory line for this (sym,lender) at all.
//@desc
.prime.availableNow:{[sym;lender;now]
  sy:sym;ln:lender;
  r:select from .prime.inventory where sym=sy,lender=ln;
  if[not count r; :0j];
  lastAvail:last `timestamp xasc r;
  lastAvail[`available]-.prime.reservedBy[sym;lender;now]};

/-----------------------------
/ Ranking
/-----------------------------

//@func  | .prime.rankInventory
//@param  | r | table | candidate inventory rows for one symbol
//@param  | requested | long | unused currently (reserved for a future term)
//@param  | priority | int | higher reduces score, i.e. ranks better
//@desc
// Computes live free qty (available less reserved), drops zero-free
// rows, scores the rest on fee/scarcity/recall/counterparty risk/
// priority (weights from .prime.cfg). Lower score ranks better.
//@desc
.prime.rankInventory:{[r;requested;priority]
  if[not count r; :r];
  now:.z.p;
  r:update free:available from r;
  r:update reserved:{[s;l;n].prime.reservedBy[s;l;n]}[;;now]'[sym;lender] from r;
  r:update free:available-reserved from r;
  r:select from r where free>0;
  if[not count r; :r];
  maxFee:max .000001f|r[`feeBp];
  maxFree:max 1j|r[`free];
  update
    feeNorm:feeBp%.prime.cfg[`feeNormBp],
    scarcity:1f-free%maxFree,
    priorityAdj:priority%100f,
    score:.prime.cfg[`feeBpWeight]*(feeBp%maxFee)
      +.prime.cfg[`scarcityWeight]*(1f-free%maxFree)
      +.prime.cfg[`recallWeight]*recallRisk
      +.prime.cfg[`counterpartyWeight]*counterpartyRisk
      -.prime.cfg[`priorityWeight]*(priority%100f)
  from r};

/-----------------------------
/ Deterministic constrained allocation
/-----------------------------

//@func  | .prime.allocate
//@param  | locateID | long
//@param  | client | symbol
//@param  | sym | symbol
//@param  | requested | long
//@param  | inventory | table
//@param  | priority | int
//@param  | constraints | table | ([] lender;maxQty) - absent lender = no cap
//@desc
// Allocates `requested` across eligible lines, best-ranked first,
// respecting free qty, per-lender caps, and lot rounding. Persists a
// reservation per allocated line. No inventory -> LOCATE_UNAVAILABLE alert.
//@desc
.prime.allocate:{[locateID;client;sym;requested;inventory;priority;constraints]
  now:.z.p;
  sy:sym;
  r:select from inventory where sym=sy,available>0;
  if[not count r;
    .prime.alerts,:enlist(.z.p;`HIGH;`LOCATE_UNAVAILABLE;client;sym;requested;
      `$"No eligible inventory");
    :([] lender:`symbol$();allocated:0#0j;feeBp:0#0f;score:0#0f)];

  r:.prime.rankInventory[r;requested;priority];
  / no `score column means every line had zero free qty - same
  / LOCATE_UNAVAILABLE path as no inventory at all
  if[not `score in cols r;
    .prime.alerts,:enlist(.z.p;`HIGH;`LOCATE_UNAVAILABLE;client;sym;requested;
      `$"No free inventory (all reserved)");
    :([] lender:`symbol$();allocated:0#0j;feeBp:0#0f;score:0#0f)];
  r:`score xasc r;
  remaining:requested;
  used:();
  out:();
  i:0;
  / do[] has no early-exit (break isn't a q keyword) - each iteration's
  / work is guarded to become a no-op once remaining<=0 instead
  do[count r;
    if[remaining>0;
      lender:r[i;`lender];
      free:r[i;`free];
      cap:free;
      if[count constraints;
        / lndr, not lender: a where-clause `lender` binds to constraints'
        / own column, shadowing this local into a no-op self-comparison
        lndr:lender;
        c:select from constraints where lender=lndr;
        if[count c;cap:cap&first c[`maxQty]-sum
          $[count used;used[;0]=lender;0j]]];
      lot:r[i;`minLot];
      take:remaining&cap;
      if[lot>0;take:take-(take mod lot)];
      if[take>0;
        out,:enlist(lender;take;r[i;`feeBp];r[i;`score]);
        remaining-:take;
        used,:enlist(lender;take)]
     ];
    i+:1];

  / $[cond;a;b] is q's real ternary (if[] has no else); the true branch
  / is a niladic lambda since it needs several statements, with
  / everything it needs passed in explicitly (nested lambdas can't see
  / an enclosing function's locals)
  $[count out;
    {[out;locateID;client;sym;now]
      / plain , doesn't upsert row-tuples into a typed table - the
      / flip'd column list needs names first
      o:([] lender:`symbol$();allocated:`long$();feeBp:`float$();score:`float$())
        upsert flip `lender`allocated`feeBp`score!flip out;
      / `long$.z.p offset by row index keeps reservation IDs unique
      i:0;
      do[count o;
        reservationID:(`long$.z.p)+i;
        .prime.reservations,:enlist
          (.z.p;reservationID;locateID;client;sym;o[i;`lender];
           o[i;`allocated];now+.prime.cfg[`defaultLocateTTL];`ACTIVE);
        i+:1];
      o
     }[out;locateID;client;sym;now];
    ([] lender:`symbol$();allocated:0#0j;feeBp:0#0f;score:0#0f)]};

/-----------------------------
/ Locate lifecycle
/-----------------------------

//@func  | .prime.newLocate
//@param  | locateID | long
//@param  | client | symbol
//@param  | sym | symbol
//@param  | requested | long
//@param  | priority | int
//@param  | inventory | table
//@param  | constraints | table
//@param  | expiry | timestamp | null (0Np) -> now+defaultLocateTTL
//@desc
// Runs .prime.allocate, records the locate (LOCATED/PARTIAL/UNLOCATED),
// raises LOCATE_GAP if the allocation fell short.
//@desc
.prime.newLocate:{[locateID;client;sym;requested;priority;inventory;constraints;expiry]
  expTime:$[expiry~0Np;.z.p+.prime.cfg[`defaultLocateTTL];expiry];
  a:.prime.allocate[locateID;client;sym;requested;inventory;priority;constraints];
  qty:sum a`allocated;
  status:$[qty>=requested;`LOCATED;qty>0;`PARTIAL;`UNLOCATED];
  .prime.locates,:enlist(.z.p;locateID;client;sym;requested;qty;expTime;priority;status);
  if[qty<requested;
    .prime.alerts,:enlist(.z.p;`HIGH;`LOCATE_GAP;client;sym;requested-qty;
      `$"Locate partially covered")];
  a};

/-----------------------------
/ Release / expiry
/-----------------------------

//@func  | .prime.releaseLocate
//@param  | locateID | long
//@desc
// Marks still-ACTIVE reservations under this locate RELEASED (an
// explicit early release, as opposed to a natural expiry).
//@desc
.prime.releaseLocate:{[locateID]
  update status:`RELEASED from `.prime.reservations where locateID=locateID,status=`ACTIVE;
  };

//@func  | .prime.expireLocates
//@param  | now | timestamp
//@desc
// Marks past-due ACTIVE reservations EXPIRED, then EXPIREs any locate
// left only with those. Call periodically (see .prime.sweep).
//@desc
.prime.expireLocates:{[now]
  expired:select from .prime.reservations where status=`ACTIVE,expiry<=now;
  if[count expired;
    update status:`EXPIRED from `.prime.reservations where status=`ACTIVE,expiry<=now;
    lids:`long$distinct expired[`locateID];
    update status:`EXPIRED from `.prime.locates where locateID in lids,status in `LOCATED`PARTIAL];
  };

/-----------------------------
/ Position coverage
/-----------------------------

//@func  | .prime.positionCoverage
//@param  | positions | table
//@param  | locates | table
//@param  | now | timestamp
//@desc
// Per (client,sym) short: shortQty, locatedQty (live LOCATED/PARTIAL
// allocations), coverage ratio, bucket. No matching locate -> locatedQty
// 0 via 0^ fill, not null.
//@desc
.prime.positionCoverage:{[positions;locates;now]
  / positions is a snapshot stream - resolve to latest row per (client,sym)
  / before filtering to shorts, else shortQty inflates without bound
  latest:0!select qty:last qty by client,sym from `timestamp xasc positions;
  p:select shortQty:neg sum qty by client,sym from latest where qty<0;
  l:select locatedQty:sum allocated by client,sym
    from locates where expiry>now,allocated>0,status in `LOCATED`PARTIAL;
  r:p lj l;
  r:update locatedQty:0^locatedQty,
    coverage:?[shortQty=0;0f;locatedQty%shortQty] from r;
  update bucket:.prime.coverageBucket each coverage from r};

/-----------------------------
/ Recalls and buy-ins
/-----------------------------

//@func  | .prime.applyRecall
//@param  | lender | symbol
//@param  | sym | symbol
//@param  | qty | long
//@param  | severity | symbol
//@param  | due | timestamp
//@desc
// Records the recall, then cuts into this lender/sym's ACTIVE
// reservations oldest-first up to `qty`, alerting per reservation
// touched. Notification only - doesn't release/resize reservations.
//@desc
.prime.applyRecall:{[lender;sym;qty;severity;due]
  .prime.recalls,:enlist(.z.p;lender;sym;qty;severity;due);
  ln:lender;sy:sym;
  active:select from .prime.reservations
    where lender=ln,sym=sy,status=`ACTIVE,expiry>.z.p;
  remaining:qty;
  i:0;
  do[count active;
    if[remaining>0;
      cutQty:remaining&active[i;`qty];
      remaining-:cutQty;
      if[cutQty>0;
        .prime.alerts,:enlist(.z.p;`HIGH;`RECALL;lender;sym;cutQty;
          `$"Reserved inventory affected by recall")]
     ];
    i+:1];
  };

//@func  | .prime.raiseBuyin
//@param  | client | symbol
//@param  | sym | symbol
//@param  | qty | long
//@param  | due | timestamp
//@param  | reason | symbol
//@desc
// Records a buy-in escalation (status OPEN) and raises a CRITICAL alert -
// last resort when a short can't be covered in time.
//@desc
.prime.raiseBuyin:{[client;sym;qty;due;reason]
  .prime.buyins,:enlist(.z.p;client;sym;qty;due;`OPEN;reason);
  .prime.alerts,:enlist(.z.p;`CRITICAL;`BUYIN;client;sym;qty;
    `$"Short position requires buy-in action")};

/-----------------------------
/ Real-time housekeeping
/-----------------------------

//@func  | .prime.sweep
//@param  | now | timestamp
//@desc
// Periodic maintenance (call off a timer): expires stale locates/
// reservations, raises a buy-in per borrow expired since last sweep,
// prunes alerts older than a day.
//@desc
.prime.sweep:{[now]
  .prime.expireLocates now;
  expired:select from .prime.borrows where expiry<=now;
  if[count expired;
    / nested lambda can't see .prime.sweep's `now` local - passed in explicitly
    {[now;r]
      .prime.raiseBuyin[r[`client];r[`sym];r[`qty];
        now+.prime.cfg[`buyinGrace];`BORROW_EXPIRED]
     }[now] each 0!expired];
  delete from `.prime.alerts where (now-timestamp)>1D;
  };
