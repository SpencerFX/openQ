//====================================================================
// modules/analytics/brokerTech/brokerTechSourceR.q
//
// Adapter that makes the expanded, two-platform retail HDB (C:/data/r,
// schemas/schema_retailR.q) look like schema_retail.q's original
// single-platform shape to brokerTech.q's UNCHANGED analytics - loaded
// straight after that file in retailR_hdb's cfg (cfg_proc/modules/
// retailR/hdb.json), it overrides brokerTech.q's four .brk.src.* window-
// pull functions; nothing else in brokerTech.q, or any caller of it,
// changes at all.
//
// Why an adapter instead of touching brokerTech.q's ~1000 lines of
// analytics: every one of those functions already takes `trades`/`equity`/
// `sig` as a plain parameter (never a bare global reference), so the only
// real seam is "how does a window of trade/equity rows, and the provider
// roster, get pulled out of the HDB in the first place" - exactly the four
// functions this file overrides. Same one-shim-at-the-boundary approach as
// modules/ingest/calendar's cast-from-strings symbol literals or
// eqOhlp.js's shared reader class: adapt the data to the proven code, not
// the other way round.
//
// The two platforms, and what's genuinely different about each:
//   mql      - the ORIGINAL mql5.com "Signals" scrape (schema_retail.q's
//              only source until now) - `trade_mql`/`equity_mql`/
//              `growth_mql`/`sig_mql`, unchanged column shape (sig_mql
//              gained 2 columns - broker, server - not used here, see
//              below). Has a real MT4/5 order-blotter concept: pending
//              orders that never fill (kind=`trade, cancelled=1) and
//              intraday equity samples.
//   fxbook   - myfxbook.com system pages - `trade_myfxbook`/
//              `equity_myfxbook`/`growth_myfxbook`/`sig_myfxbook`. No
//              order-blotter concept at all: every trade row IS a real
//              fill (no kind/cancelled columns exist on that platform),
//              equity is one EOD snapshot/day not an intraday curve, and
//              raw $ balance/equity are simply never populated (only
//              growthPct is - that platform's public pages surface %
//              gain, not the underlying dollar figures).
// The ingest pipeline already UNIONS both into `trade`/`equity`/`growth`
// (platform`+`acctId in place of a single signalId; verified row-for-row
// against trade_mql+trade_myfxbook before writing this - see
// econcal/brokertech migration notes) - this file's real work is just the
// signalId synthesis + the myfxbook backfill, not a second union pass.
//
// signalId synthesis: mql's `signalId` (sig_mql, ~1e5-1e6 range currently)
// and myfxbook's `systemId` (sig_myfxbook, ~1e6-1e7 range currently) are
// two independently-assigned counters from unrelated platforms - close
// enough in range today that a future collision is a real risk, not a
// theoretical one. FXBOOK_OFFSET (1e12) is added to every myfxbook id,
// putting it far outside any range either counter could plausibly reach,
// so the combined signalId is permanently collision-free and still a
// plain sortable long - a drop-in replacement for the original signalId
// everywhere brokerTech.q keys or joins on it.
//
// sig.name for myfxbook is `displayName` (e.g. "IC Markets FERRARI2009"),
// not `systemName`/`username` - it's the richest free-text field myfxbook
// exposes, and, usefully, the one most likely to carry a broker name the
// same way mql's sig.name sometimes does ("Scalp IC Markets ECN", ...) -
// so .brk.broker.tag's existing name-parsing (unchanged) picks up real
// broker attribution for myfxbook providers too, for free. mql's own new
// `broker` column (a controlled-vocabulary code like "ICMarketsSC", not
// directly comparable to .brk.broker.keywords' canonical names) is
// intentionally NOT wired in here - a genuine improvement over name-
// parsing, but a separate enhancement from this migration, not required
// for parity with what the dashboards already show.
//====================================================================
.oq.info.brokerTechSourceR.loaded:0b;

.brk.src.FXBOOK_OFFSET:1000000000000; // 1e12 - see header

//@func   | .brk.src.trade
//@param  | sDate | date
//@param  | eDate | date
//@desc
// Overrides brokerTech.q's default: the merged `trade` table's window,
// with signalId synthesized from (platform;acctId) and myfxbook's missing
// kind/cancelled/orderType backfilled (see header - it has no pending-
// order concept, so every row is a real, non-cancelled fill; its orderType
// is unknown but every fill maps onto the same `Buy`/`Sell "market" bucket
// .brk.exec.orderMix already recognises).
//@desc
.brk.src.trade:{[sDate;eDate]
  t:select date,tradeKey,platform,acctId,kind,action,orderType,symbol,openTime,closeTime,
      openPrice,closePrice,sl,tp,volume,commission,swap,profit,cancelled
    from trade where date within (sDate;eDate);
  t:update signalId:acctId+(platform=`fxbook)*.brk.src.FXBOOK_OFFSET from t;
  // NB: "col^fillval" (the ^ fill operator) raises 'nyi here when col comes
  // straight off a partitioned-table select (even with no attribute set,
  // confirmed via meta) - a kdb+ build limitation, not a type/logic bug.
  // The ternary form below works unconditionally, so use it for every
  // null-fill in this file rather than ^ - see q_kdb_gotchas.
  t:update kind:?[null kind;`trade;kind], cancelled:?[null cancelled;0;cancelled] from t;
  t:update orderType:?[(platform=`fxbook) and null orderType;
      `Buy`Sell[action=`sell]; orderType] from t;
  select date,tradeKey,signalId,kind,action,orderType,symbol,openTime,closeTime,
      openPrice,closePrice,sl,tp,volume,commission,swap,profit,cancelled from t};

//@func   | .brk.src.equity
//@param  | sDate | date
//@param  | eDate | date
//@desc
// Overrides brokerTech.q's default: the merged `equity` table's window,
// signalId synthesized the same way as .brk.src.trade. myfxbook rows carry
// a null balance/equity (see header) - propagates as null through
// .brk.perf.drawdown exactly like a real mql gap would, not a special case.
//@desc
.brk.src.equity:{[sDate;eDate]
  e:select date,platform,acctId,ts,balance,equity from equity where date within (sDate;eDate);
  e:update signalId:acctId+(platform=`fxbook)*.brk.src.FXBOOK_OFFSET from e;
  select date,signalId,ts,balance,equity from e};

//@func   | .brk.src.growth
//@param  | sDate | date
//@param  | eDate | date
//@desc
// Overrides brokerTech.q's default: the merged `growth` table's window,
// signalId synthesized the same way. Not currently pulled by the gateway
// (see brokerTech.js's own header - "Provider Growth" is an unbuilt
// dashboard idea), kept symmetric with trade/equity for when it is.
//@desc
.brk.src.growth:{[sDate;eDate]
  g:select date,platform,acctId,growthPct from growth where date within (sDate;eDate);
  g:update signalId:acctId+(platform=`fxbook)*.brk.src.FXBOOK_OFFSET from g;
  select date,signalId,growthPct from g};

//@func   | .brk.src.sig
//@desc
// Overrides brokerTech.q's default: sig_mql + sig_myfxbook unioned into
// schema_retail.q's original 9-column `sig` shape (signalId synthesized
// the same way as trade/equity/growth). Recomputed on every call rather
// than cached at load time - both source tables are a few thousand rows,
// cheap to union fresh, and this sidesteps any question of whether
// sig_mql/sig_myfxbook are guaranteed loaded yet by the time this file's
// own top-level statements would otherwise run (they aren't touched at
// load time at all here - only inside this function body, called long
// after the HDB has fully started).
//@desc
.brk.src.sig:{[]
  m:select signalId,mtVersion,name,authorLogin,authorName,accountType,url,firstSeen,lastSeen
    from sig_mql;
  f:select signalId:systemId+.brk.src.FXBOOK_OFFSET,
      mtVersion:0Nj, name:displayName, authorLogin:username, authorName:username,
      accountType:`myfxbook, url, firstSeen, lastSeen
    from sig_myfxbook;
  m,f};

//@func   | .brk.src.monthly
//@desc
// Overrides brokerTech.q's default: C:/data/r has no per-month-returns
// table on either platform (schema_retail.q's `monthly` doesn't exist
// here) - an empty stub in the original 5-column shape. Only ever
// consumed for a diagnostic row count in the gateway's SUITE query
// (.brk.perf.monthlyStats, the only real reader, isn't wired into any
// dashboard yet), so an always-empty table is a correct, not a degraded,
// answer for this source.
//@desc
.brk.src.monthly:{[] ([] signalId:`long$(); year:`long$(); month:`long$();
  returnPct:`float$(); yearlyPct:`float$())};

.oq.info.brokerTechSourceR.loaded:1b;
