//====================================================================
// openQ Prime Finance schema
//====================================================================

.oq.schema.info.loaded:0b;

inventory:([] timestamp:`timestamp$();sym:`symbol$();lender:`symbol$();
  available:`long$();feeBp:`float$();termDays:`int$();
  recallRisk:`float$();counterpartyRisk:`float$();minLot:`long$());

locate:([] timestamp:`timestamp$();sym:`symbol$();locateID:`long$();client:`symbol$();
  requested:`long$();allocated:`long$();
  expiry:`timestamp$();priority:`int$();status:`symbol$());

position:([] timestamp:`timestamp$();sym:`symbol$();client:`symbol$();
  qty:`long$();avgPx:`float$());

borrow:([] timestamp:`timestamp$();sym:`symbol$();client:`symbol$();
  lender:`symbol$();qty:`long$();feeBp:`float$();expiry:`timestamp$());

recall:([] timestamp:`timestamp$();sym:`symbol$();lender:`symbol$();
  qty:`long$();severity:`symbol$();due:`timestamp$());

.oq.schema.tables:{[] `inventory`locate`position`borrow`recall};

.oq.schema.info.loaded:1b;
