//====================================================================
// Directory: modules/analytics/primeFinance/state.q
//
// About:
// All of primeFinance.q's schema tables and config, split out so the
// domain library (primeFinance.q, its own sibling file) is pure
// functions/logic over already-declared state. Loaded by primeFinance.q
// itself, not directly by cep.q/tests.
//====================================================================

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

// Borrow-fee calibration, one row per (sym,lender) inventory line - see
// .prime.calib.build. Declared empty so a dashboard query before the
// first refresh (cep.q) gets zero rows, not an error. ccy tags feeBp
// fields as basis-points (currency-comparable as-is); $ fields elsewhere
// need it to avoid cross-currency summing.
.prime.calibration:([] sym:`symbol$(); lender:`symbol$(); ccy:`symbol$();
  feeBp:`float$(); vol:`float$(); adv:`float$(); volPctile:`float$();
  advPctile:`float$(); expectedFeeBp:`float$(); richCheapBp:`float$();
  flag:`symbol$());

// Position mark-to-market, one row per (client,sym) - see .prime.risk.build.
// marketValue/unrealizedPnl are in ccy, never converted (no real FX feed) -
// see cep.q's header.
.prime.positionRisk:([] client:`symbol$(); sym:`symbol$(); ccy:`symbol$();
  qty:`long$(); avgPx:`float$(); currentPx:`float$(); marketValue:`float$();
  unrealizedPnl:`float$(); pnlPct:`float$(); side:`symbol$());

// Short-interest concentration, one row per symbol with a short somewhere
// in the book - see .prime.crowd.build. shortValue is in ccy, same
// no-FX-conversion caveat as positionRisk.
.prime.crowding:([] sym:`symbol$(); ccy:`symbol$(); shortQty:`long$();
  numClients:`int$(); close:`float$(); adv:`float$(); shortValue:`float$();
  daysToCover:`float$(); bucket:`symbol$());

// Scoring weights, fee normalization, locate TTL, buy-in grace, day-count basis
.prime.cfg:`feeBpWeight`scarcityWeight`recallWeight`counterpartyWeight`priorityWeight`feeNormBp`defaultLocateTTL`buyinGrace`dayCount!(0.40;0.20;0.20;0.10;0.10;1000f;0D00:30:00;0D00:05:00;360f);

// Lender/counterparty reference data (credit rating, credit limit,
// margin factor) - see .prime.expo.build. A plain keyed table, not a
// true kdb+ fkey column: a fkey's referential-integrity check would
// hard-error a live borrow from an unseeded lender. Seeded by cep.q.
.prime.lenders:([lender:`symbol$()] creditRating:`symbol$();
  creditLimit:`float$(); marginFactor:`float$());

// Aggregate financing exposure per (lender,ccy) - see .prime.expo.build.
// Same "declared empty" rationale as calibration/positionRisk/crowding.
.prime.exposure:([] lender:`symbol$(); ccy:`symbol$();
  grossExposure:`float$(); creditRating:`symbol$(); creditLimit:`float$();
  marginFactor:`float$(); marginRequirement:`float$();
  utilizationPct:`float$(); headroom:`float$(); breach:`boolean$());
