//====================================================================
// openQ Prime Finance / Position Location analytics
//
// Domain module for securities finance:
//   inventory -> locate -> reservation -> borrow -> position coverage
//             -> recall -> buy-in risk -> financing economics
//
// The allocator is deterministic and stateful. It supports:
//   * lender caps
//   * client priority
//   * minimum lot sizes
//   * locate expiry
//   * inventory reservations
//   * recall reduction
//   * buy-in escalation
//
// All domain state is kept outside core/ so openQ remains untouched.
//====================================================================

/-----------------------------
/ State
/-----------------------------
// per-lender availability and borrow economics
.prime.inventory:([] timestamp:`timestamp$(); sym:`symbol$(); lender:`symbol$();
  available:`long$(); feeBp:`float$(); termDays:`int$();
  recallRisk:`float$(); counterpartyRisk:`float$(); minLot:`long$());

// active/expired/released holds against a locate's allocation
.prime.reservations:([] timestamp:`timestamp$(); reservationID:`long$();
  locateID:`long$(); client:`symbol$(); sym:`symbol$(); lender:`symbol$();
  qty:`long$(); expiry:`timestamp$(); status:`symbol$());

// one row per locate request, with its resulting allocation status
.prime.locates:([] timestamp:`timestamp$(); locateID:`long$(); client:`symbol$();
  sym:`symbol$(); requested:`long$(); allocated:`long$(); expiry:`timestamp$();
  priority:`int$(); status:`symbol$());

// client positions (negative qty is short)
.prime.positions:([] timestamp:`timestamp$(); client:`symbol$();
  sym:`symbol$(); qty:`long$(); avgPx:`float$());

// realized borrows against a client's short position
.prime.borrows:([] timestamp:`timestamp$(); client:`symbol$(); sym:`symbol$();
  lender:`symbol$(); qty:`long$(); feeBp:`float$(); expiry:`timestamp$());

// lender-initiated recalls of previously-reserved inventory
.prime.recalls:([] timestamp:`timestamp$(); lender:`symbol$(); sym:`symbol$();
  qty:`long$(); severity:`symbol$(); due:`timestamp$());

// buy-in escalations raised against an uncovered short
.prime.buyins:([] timestamp:`timestamp$(); client:`symbol$(); sym:`symbol$();
  qty:`long$(); due:`timestamp$(); status:`symbol$(); reason:`symbol$());

// operational alerts raised by the functions below
.prime.alerts:([] timestamp:`timestamp$(); severity:`symbol$(); kind:`symbol$();
  client:`symbol$(); sym:`symbol$(); qty:`long$(); message:`symbol$());

// Borrow-fee calibration result, one row per (sym,lender) inventory line -
// see .prime.calib.build below. Declared empty here so a dashboard query
// against it before the first refresh (see cep.q's .primeMod.calib.refresh)
// returns zero rows instead of erroring on an undefined global. `ccy` is
// the sym's real trading currency (USD/HKD/JPY - see cep.q's
// .primeMod.market.ccyMap) - feeBp/expectedFeeBp/richCheapBp are basis
// points (a rate, not a $ amount) so they compare validly across
// currencies without conversion; only $ fields elsewhere (positionRisk,
// crowding) need the tag to avoid being silently summed cross-currency.
.prime.calibration:([] sym:`symbol$(); lender:`symbol$(); ccy:`symbol$();
  feeBp:`float$(); vol:`float$(); adv:`float$(); volPctile:`float$();
  advPctile:`float$(); expectedFeeBp:`float$(); richCheapBp:`float$();
  flag:`symbol$());

// Position mark-to-market, one row per (client,sym) position - see
// .prime.risk.build below. Same "declared empty" rationale as
// .prime.calibration - see cep.q's .primeMod.market.refresh for the
// periodic real-price refresh that populates it. marketValue/
// unrealizedPnl are in `ccy (the sym's real local currency) - this repo
// has no real FX-rate feed, so they are NOT converted to a common
// currency; see cep.q's header on how consumers are expected to handle
// that (never sum across ccy).
.prime.positionRisk:([] client:`symbol$(); sym:`symbol$(); ccy:`symbol$();
  qty:`long$(); avgPx:`float$(); currentPx:`float$(); marketValue:`float$();
  unrealizedPnl:`float$(); pnlPct:`float$(); side:`symbol$());

// Short-interest concentration, one row per symbol with at least one short
// position anywhere in the book - see .prime.crowd.build below. Same
// "declared empty" rationale as .prime.calibration/.prime.positionRisk.
// shortValue is in `ccy, same no-FX-conversion caveat as .prime.positionRisk.
.prime.crowding:([] sym:`symbol$(); ccy:`symbol$(); shortQty:`long$();
  numClients:`int$(); close:`float$(); adv:`float$(); shortValue:`float$();
  daysToCover:`float$(); bucket:`symbol$());

// Configuration: scoring weights (feeBp/scarcity/recall/counterparty/
// priority), fee normalization, default locate TTL, buy-in grace period,
// and the day-count basis borrow cost is annualized against
.prime.cfg:`feeBpWeight`scarcityWeight`recallWeight`counterpartyWeight`priorityWeight`feeNormBp`defaultLocateTTL`buyinGrace`dayCount!(0.40;0.20;0.20;0.10;0.10;1000f;0D00:30:00;0D00:05:00;360f);

/-----------------------------
/ Helpers
/-----------------------------

//@func  | .prime.clamp
//@param  | x | float
//@param  | lo | float
//@param  | hi | float
//@desc
// Clamps x into the closed range [lo;hi].
//@desc
.prime.clamp:{[x;lo;hi] lo|hi&x};

//@func  | .prime.coverageBucket
//@param  | x | float
//@desc
// Buckets a coverage ratio (locatedQty%shortQty, see
// .prime.positionCoverage) into a plain-language risk category:
// FULL (>=1), PARTIAL (>=0.8), AT_RISK (>0), or UNLOCATED (0).
//@desc
.prime.coverageBucket:{[x]
  $[x>=1f;`FULL;x>=.8f;`PARTIAL;x>0f;`AT_RISK;`UNLOCATED]};

//@func  | .prime.borrowCost
//@param  | notional | float
//@param  | feeBp | float
//@param  | days | float
//@desc
// Annualized borrow cost: notional * (feeBp/1e4) * (days/dayCount),
// dayCount from .prime.cfg. q has no arithmetic operator precedence
// (strictly right-to-left), so without the parens below this reduces to
// notional*(feeBp%(1e4*(days%dayCount))) instead of the intended
// notional*(feeBp/1e4)*(days/dayCount).
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
// "Hard to borrow" score: a weighted sum of five independent risk
// signals - low availability, high utilization, high fee (normalized
// against .prime.cfg`feeNormBp and clamped to [0;1]), recall risk, and
// historical reject rate. Each weight*term product is parenthesized
// because q has no arithmetic operator precedence (strictly
// right-to-left) - without it this cascades into one long right-to-left
// chain instead of five independent products summed together, the same
// class of bug .prime.borrowCost avoids above.
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
// .prime.htbScore above already encodes "harder to borrow costs more", but
// entirely from THIS book's own inventory (fee normalized against a config
// constant, availability relative only to other lines on the same sym) -
// it has no idea whether a name is genuinely volatile or thinly traded in
// the real market. These functions benchmark each quoted feeBp against real
// realized volatility and ADV (sourced from the eq_d1_yfinance HDB by
// cep.q's .primeMod.calib.refresh, over every symbol actually trading in
// the lookback window - not just this book's handful of names) - the way a
// real stock-loan desk sanity-checks its own rate card.
//
// There's no real fee data to fit an "expected fee" curve against (feeBp is
// a rate the desk/lender SETS, not something observed in the market), so
// .prime.calib.expectedFeeBp is an explicit weighted formula, same spirit
// as .prime.htbScore, not a statistically fitted model - it's a calibration
// benchmark, not a market-observed curve.

.prime.calib.cfg:`feeFloorBp`feeRangeBp`volWeight`liqWeight`richCheapThresholdBp!
  (15f;800f;0.5;0.5;25f);

//@func  | .prime.calib.percentileOf
//@param  | x   | float | value to rank
//@param  | ref | float list | reference distribution
//@desc
// Fraction of ref strictly below x (0..1). Null-safe both ways: a null x
// (sym missing from the real-market reference table) or an empty ref both
// yield a neutral 0.5 rather than a divide-by-zero or a spurious 0 - q's
// null-sorts-lowest rule would otherwise make `ref<0n` come back all 0b,
// silently scoring a missing sym at the 0th percentile instead of unknown.
//@desc
.prime.calib.percentileOf:{[x;ref]
  if[null x;:0.5];
  if[0=count ref;:0.5];
  (sum ref<x)%count ref};

//@func  | .prime.calib.expectedFeeBp
//@param  | volPctile | float | 0..1, this sym's realized-vol percentile within the real market
//@param  | advPctile | float | 0..1, this sym's ADV percentile within the real market (higher = more liquid)
//@desc
// Model-implied borrow fee: a floor (roughly general-collateral territory)
// plus a range scaled by a blend of volatility percentile and illiquidity
// (1-advPctile) - both push the expected fee up, weighted per
// .prime.calib.cfg. Deliberately linear/explicit, not fitted (see this
// section's header comment).
//@desc
.prime.calib.expectedFeeBp:{[volPctile;advPctile]
  blend:.prime.clamp[
    (.prime.calib.cfg[`volWeight]*volPctile)+(.prime.calib.cfg[`liqWeight]*(1f-advPctile));
    0f;1f];
  .prime.calib.cfg[`feeFloorBp]+.prime.calib.cfg[`feeRangeBp]*blend};

//@func  | .prime.calib.flag
//@param  | richCheapBp | float | feeBp - expectedFeeBp
//@desc
// RICH: quoted fee is above what real vol/ADV would imply (lender charging
// more than the model expects). CHEAP: below. FAIR: within
// .prime.calib.cfg`richCheapThresholdBp of the model-implied fee either way.
//@desc
.prime.calib.flag:{[richCheapBp]
  th:.prime.calib.cfg[`richCheapThresholdBp];
  $[richCheapBp>th;`RICH;richCheapBp<neg th;`CHEAP;`FAIR]};

//@func  | .prime.calib.build
//@param  | inventory | table | .prime.inventory-shaped (sym,lender,feeBp,...)
//@param  | market    | table | sym,vol,adv - realized vol (annualized %) and
//        average daily volume per sym over the reference window, for every
//        symbol actually trading in it (see cep.q's .primeMod.calib.refresh
//        - sourced from the real eq_d1_yfinance HDB, not just this book's
//        own names, so percentiles below are ranked against the real
//        market)
//@desc
// One row per (sym,lender) inventory line: that line's latest feeBp, its
// sym's real vol/ADV and percentile rank within `market`, the model-implied
// expectedFeeBp, and how rich/cheap the actual quote is against it. A sym
// absent from `market` (no recent real trading data - a data gap, or a
// symbol not covered by the real feed) still gets a row, at neutral 0.5
// percentiles (.prime.calib.percentileOf), rather than silently vanishing.
//@desc
.prime.calib.build:{[inventory;market]
  / NOTE: `cols` is a reserved word in q (cannot be assigned to, even as a
  / local inside a lambda - fails with 'assign) despite looking like an
  / ordinary builtin function name; colNames avoids it.
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
// .prime.positions.avgPx is the entry price a position was booked at - on
// its own it says nothing about current risk. These functions mark each
// position to a REAL latest close (same `market` reference table cep.q's
// .primeMod.market.refresh already pulls from eq_d1_yfinance for
// .prime.calib.build above, extended with a `close column - one HDB round
// trip serves both features), turning raw share counts into actual $
// exposure and P&L - the "coverage" view already on screen has neither.

//@func  | .prime.risk.build
//@param  | positions | table | .prime.positions-shaped (client,sym,qty,avgPx,...)
//@param  | market    | table | sym,close - latest real close per sym (see
//        cep.q's .primeMod.market.refresh); vol/adv columns, if present,
//        are simply ignored here
//@desc
// One row per (client,sym) position: currentPx (real latest close, null if
// the sym isn't in `market`), marketValue (qty*currentPx - signed, negative
// for a net-short position), unrealizedPnl (qty*(currentPx-avgPx) - this
// single signed formula is correct for BOTH long and short: a short's qty
// is already negative, so a price drop still comes out as a positive
// P&L without a separate branch), pnlPct (unrealizedPnl over the
// original notional, abs qty*avgPx), and side (LONG/SHORT from the sign of
// qty). A sym missing from `market` gets null currentPx/marketValue/
// unrealizedPnl/pnlPct rather than a fabricated number - there's no
// sensible "neutral" P&L the way there was a neutral percentile.
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
  / `?[cond;a;b]` can't bind a name inline for reuse (no "notional:" inside
  / the condition slot the way an update-context column assignment can) -
  / notional above is its own update step so pnlPct's divide can reference it
  r:update pnlPct:?[0=notional;0Nf;unrealizedPnl%notional] from r;
  r:update side:?[qty<0;`SHORT;`LONG] from r;
  colNames xcols delete notional from r};

/-----------------------------
/ Short-interest concentration ("crowded shorts", real ADV from real market data)
/-----------------------------
// .prime.positionCoverage (further below) already answers "is THIS
// client's short located" per (client,sym). Concentration is a different,
// symbol-level question: aggregated across EVERY client, how much of this
// name is the whole book short, and how hard would unwinding all of it be
// against real trading volume - the classic "crowded short" / squeeze-risk
// lens a real desk watches across its full book, not one client at a time.
// Uses the same real `market` reference table (sym,close,adv,vol) cep.q's
// .primeMod.market.refresh already pulls from eq_d1_yfinance for
// .prime.calib.build/.prime.risk.build above - one HDB round trip serves
// all three.

// Days-to-cover thresholds (aggregate shortQty / real ADV) - how many
// average trading days it would take to unwind the WHOLE book's short in
// a name if every share had to trade through normal daily volume. There's
// no real short-interest-vs-float data available here (that needs shares
// outstanding, which eq_d1_yfinance doesn't carry) - ADV is the best real
// liquidity denominator available, and days-to-cover against ADV is
// itself a standard real desk metric, not a stand-in for a better one.
.prime.crowd.cfg:`lowDTC`medDTC`highDTC!(1f;5f;15f);

//@func  | .prime.crowd.bucket
//@param  | daysToCover | float
//@desc
// LOW/MODERATE/HIGH/EXTREME by .prime.crowd.cfg's thresholds; a null
// daysToCover (sym missing from `market`, or zero real ADV) buckets
// UNKNOWN rather than being coerced into any real bucket.
//@desc
.prime.crowd.bucket:{[daysToCover]
  $[null daysToCover;`UNKNOWN;
    daysToCover<=.prime.crowd.cfg[`lowDTC];`LOW;
    daysToCover<=.prime.crowd.cfg[`medDTC];`MODERATE;
    daysToCover<=.prime.crowd.cfg[`highDTC];`HIGH;
    `EXTREME]};

//@func  | .prime.crowd.build
//@param  | positions | table | .prime.positions-shaped (client,sym,qty,...)
//@param  | market    | table | sym,close,adv - real latest close and
//        average daily volume per sym (see cep.q's .primeMod.market.refresh)
//@desc
// One row per symbol with at least one short position anywhere in the
// book: aggregate shortQty (positive magnitude, same neg-sum-qty
// convention .prime.positionCoverage already uses below) and numClients
// (distinct clients short it - platform-wide exposure to that name's
// squeeze risk, not just concentration among lenders), real shortValue
// ($, via close) and daysToCover (shortQty/adv), bucketed
// (.prime.crowd.bucket). A sym missing from `market` still gets a row, at
// null close/adv/shortValue/daysToCover and bucket UNKNOWN.
//@desc
.prime.crowd.build:{[positions;market]
  colNames:`sym`ccy`shortQty`numClients`close`adv`shortValue`daysToCover`bucket;
  / NOTE: a nested lambda does NOT see its enclosing function's locals (see
  / .prime.allocate's own comment on this same q quirk) - colNames must be
  / passed in explicitly, not referenced as if it were a captured closure
  emptyType:{[cn]0#flip cn!(`symbol$();`symbol$();`long$();`int$();
    `float$();`float$();`float$();`float$();`symbol$())};
  if[not count positions;:emptyType[colNames]];
  short:0!select shortQty:neg sum qty, numClients:`int$count distinct client
    by sym from positions where qty<0;
  if[not count short;:emptyType[colNames]];
  r:short lj `sym xkey select sym,ccy,close,adv from market;
  r:update shortValue:shortQty*close, daysToCover:shortQty%adv from r;
  colNames xcols update bucket:.prime.crowd.bucket each daysToCover from r};

/-----------------------------
/ Inventory state
/-----------------------------

//@func  | .prime.reservedBy
//@param  | sym | symbol
//@param  | lender | symbol
//@param  | now | timestamp
//@desc
// Total quantity currently reserved (status `ACTIVE, not yet expired as
// of now) against one (sym,lender) inventory line. Both params are
// deliberately re-bound to differently-named locals (sy/ln) before the
// where-clause: inside select/exec, a bare column name (here sym/lender)
// binds to the queried table's OWN column, silently shadowing an outer
// variable/param of the same name and turning an intended filter into a
// no-op self-comparison (see .prime.allocate's constraints filter for
// the same fix).
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
// Currently-free quantity for one (sym,lender) inventory line: the most
// recent inventory snapshot's available quantity, minus whatever's
// already reserved against it (.prime.reservedBy). Returns 0 if there's
// no inventory line for this (sym,lender) at all.
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
//@param  | r | table
//@param  | requested | long
//@param  | priority | int
//@desc
//   r: candidate inventory rows for one symbol (see .prime.allocate)
//   requested: quantity the locate is asking for (currently unused in
//        the scoring itself - reserved for a future size-aware term)
//   priority: the requesting client's priority (higher reduces score,
//        i.e. ranks better)
// Computes each row's live free quantity (available, less whatever's
// already reserved per .prime.reservedBy), drops rows with none left,
// then scores the remainder as a weighted combination of normalized
// fee, scarcity (1 - free%maxFree), recall risk, counterparty risk, and
// a priority discount - weights from .prime.cfg. Lower score ranks
// better (see .prime.allocate's `score xasc). Returns the scored/
// filtered table, or the original (empty) r unchanged if there was
// nothing to rank.
//@desc
.prime.rankInventory:{[r;requested;priority]
  if[not count r; :r];
  now:.z.p;
  r:update free:available from r;
  / reserved quantities are calculated per (sym,lender) row below
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
//@param  | constraints | table
//@desc
//   constraints: a table with optional lender/limit rows, e.g.
//        ([] lender:`L1`L2; maxQty:50000 100000) - a lender absent from
//        this table has no cap applied
// Deterministically allocates `requested` units of `sym` across
// eligible inventory lines, best-ranked first (.prime.rankInventory),
// respecting each lender's live free quantity, any per-lender cap in
// `constraints`, and each line's minimum lot size (allocations are
// rounded down to a lot multiple). Persists a reservation row per
// allocated (lender,qty) pair, each held for .prime.cfg`defaultLocateTTL
// from now. If no eligible inventory exists at all, raises a
// LOCATE_UNAVAILABLE alert and returns an empty allocation table
// unchanged. Returns a `lender`allocated`feeBp`score table, one row per
// lender actually allocated against.
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
  / rankInventory returns early (no `score column) when every candidate
  / line has zero free qty after live reservations - treat that as "nothing
  / allocatable right now", same LOCATE_UNAVAILABLE path as no inventory at all
  if[not `score in cols r;
    .prime.alerts,:enlist(.z.p;`HIGH;`LOCATE_UNAVAILABLE;client;sym;requested;
      `$"No free inventory (all reserved)");
    :([] lender:`symbol$();allocated:0#0j;feeBp:0#0f;score:0#0f)];
  r:`score xasc r;
  remaining:requested;
  used:();
  out:();
  i:0;
  / q's do[] loop has no early-exit statement (break is not a q keyword -
  / referencing it just signals 'break, an undefined variable), so instead
  / of trying to stop the loop once remaining<=0, every iteration's real
  / work is guarded so it becomes a no-op from that point on
  do[count r;
    if[remaining>0;
      lender:r[i;`lender];
      free:r[i;`free];
      cap:free;
      if[count constraints;
        / lndr, not lender: inside the where-clause `lender` binds to
        / constraints' own lender COLUMN, silently shadowing this outer
        / local of the same name and turning the filter into a no-op
        / self-comparison (lender=lender is always true) if reused here
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

  / q's if[] has no else branch (and isn't an expression that yields a
  / value either way) - $[cond;trueExpr;falseExpr] is the real ternary.
  / The true branch needs several statements, so it's a niladic lambda
  / defined and called inline; a nested lambda doesn't see an enclosing
  / function's locals, so everything it needs is passed in explicitly.
  $[count out;
    {[out;locateID;client;sym;now]
      / plain `,` doesn't upsert a list of row-tuples into a typed table
      / the way it might look like it should - the flip'd column list
      / needs its own column names before it can be upserted in
      o:([] lender:`symbol$();allocated:`long$();feeBp:`float$();score:`float$())
        upsert flip `lender`allocated`feeBp`score!flip out;
      / persist reservations atomically from the CEP's single q thread;
      / `long$.z.p` (nanosecond epoch) offset by row index keeps IDs
      / unique even when several reservations are created in one call
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
//@param  | expiry | timestamp
//@desc
//   expiry: the locate's own expiry; null (0Np) defaults to now plus
//        .prime.cfg`defaultLocateTTL
// Runs .prime.allocate, records the resulting locate (status `LOCATED/
// `PARTIAL/`UNLOCATED depending on how much of `requested` was actually
// allocated) into .prime.locates, and raises a LOCATE_GAP alert if the
// allocation fell short. Returns .prime.allocate's own
// `lender`allocated`feeBp`score result.
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
// Marks every still-`ACTIVE` reservation under this locate as
// `RELEASED` (an explicit early release, as opposed to a natural
// expiry - see .prime.expireLocates).
//@desc
.prime.releaseLocate:{[locateID]
  update status:`RELEASED from `.prime.reservations where locateID=locateID,status=`ACTIVE;
  };

//@func  | .prime.expireLocates
//@param  | now | timestamp
//@desc
// Marks every `ACTIVE` reservation whose expiry has passed as
// `EXPIRED`, then marks any locate that only had `LOCATED`/`PARTIAL`
// status through those reservations as `EXPIRED` too. Call periodically
// (see .prime.sweep) so coverage/allocation state stays current without
// waiting for the next locate/reservation event to notice.
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
// For every (client,sym) with a short position, computes shortQty
// (magnitude of the short), locatedQty (sum of still-live, non-expired
// `LOCATED`/`PARTIAL` locate allocations), coverage (locatedQty%
// shortQty, 0 if shortQty is 0), and bucket (.prime.coverageBucket).
// A (client,sym) with no matching locate at all gets locatedQty:0 via
// the 0^ fill after the left join, not a null. Returns one row per
// (client,sym) short position.
//@desc
.prime.positionCoverage:{[positions;locates;now]
  p:select shortQty:neg sum qty by client,sym from positions where qty<0;
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
// Records the recall (.prime.recalls), then walks this lender/sym's
// still-`ACTIVE`, non-expired reservations oldest-first, cutting into
// each until `qty` has been accounted for, raising a RECALL alert per
// reservation actually affected. Does not itself release or resize the
// affected reservations - it's a notification of what the recall
// touches, not a mutation of reservation state.
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
// Records a buy-in escalation (.prime.buyins, status `OPEN) and raises
// a CRITICAL BUYIN alert - the last resort when a short can't be
// covered in time (see .prime.sweep for the one caller, triggered by an
// expired borrow).
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
// Periodic maintenance, call off a timer: expires stale locates/
// reservations (.prime.expireLocates), raises a buy-in for every borrow
// that's expired since the last sweep (.prime.raiseBuyin), and prunes
// .prime.alerts older than a day so it doesn't grow unbounded.
//@desc
.prime.sweep:{[now]
  .prime.expireLocates now;
  expired:select from .prime.borrows where expiry<=now;
  if[count expired;
    / a nested lambda doesn't see .prime.sweep's `now` local - pass it in
    / explicitly (same quirk as .prime.allocate's inline $[] branch)
    {[now;r]
      .prime.raiseBuyin[r[`client];r[`sym];r[`qty];
        now+.prime.cfg[`buyinGrace];`BORROW_EXPIRED]
     }[now] each 0!expired];
  delete from `.prime.alerts where (now-timestamp)>1D;
  };
