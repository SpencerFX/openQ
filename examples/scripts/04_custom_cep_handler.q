//====================================================================
// 04_custom_cep_handler.q
//
// A minimal, heavily-commented template for writing your OWN CEP
// analytics, the same shape every real module's -cepscript uses (see
// modules/analytics/spread/cep.q, modules/analytics/markout/cep.q, etc.
// for the full production version of this pattern). This is the ONLY piece of
// core/ a module is ever allowed to customize - tp.q/rdb.q/idb.q/
// hdb.q are schema-agnostic and never change.
//
// What this example handler does: for every incoming `quote` row, it
// computes a simple mid price (bid+ask)/2 and publishes it into a new
// derived `mid` table - about as small as a real handler gets, but it
// exercises the exact same .oq.cep.addHandler/.u.updNL mechanism a
// production analytics handler (like .spread.onQuote) does.
//
// A REAL module also adds a generic per-table relay loop alongside its
// analytics handler ({.oq.cep.addHandler[x;.<mod>.relay;...]} each
// .oq.schema.tables[]) so rdb - which subscribes to the CEP, not the
// tickerplant, directly (idb doesn't subscribe to anything - see
// core/idb.q's header) - actually sees the raw rows too. Left out here
// to keep this example focused on the
// analytics-handler pattern alone; see any real module's cep.q for the
// relay loop.
//
// Prerequisite: the default pipeline's tickerplant running, e.g.:
//   ./scripts/startStop/startup.sh
//
// Run this AS A CEP, from core/ (cepscript paths are core-relative,
// matching every real module's cep.q):
//   cd core
//   q init.q -procType cep -name exampleCep -port 5099 \
//     -srcaddr :localhost:5010 -cepscript ../examples/scripts/04_custom_cep_handler.q
//
// Then, from another q session, publish a quote and query it back:
//   h:hopen `:localhost:5010
//   neg[h] (`upd;`quote;([] timestamp:enlist .z.p; sym:enlist `AAPL; bid:enlist 100f; ask:enlist 101f; bidSize:enlist 1f; askSize:enlist 1f; source:enlist `me))
//   neg[h][]; hclose h
//   ceph:hopen `:localhost:5099
//   ceph "select from mid"
//
// If you point -srcaddr at a long-lived tickerplant that already has a
// lot of history on disk, don't be surprised by a handful of "Handler
// failed for quote: type" lines during the initial replay - that's
// this handler meeting old rows shaped differently than schema.q's
// current quote, not a bug in the handler itself; a fresh tickerplant
// (or the one ./scripts/startStop/startup.sh just started) won't have any.
//====================================================================

// The derived output table this handler produces - like any openQ
// table, timestamp,sym must be its first two columns.
mid:([] timestamp:`timestamp$(); sym:`symbol$(); mid:`float$());

// .oq.cep.addHandler[table;handlerFn;name] registers handlerFn to run
// every time a batch of rows for `table` arrives. handlerFn's own
// signature is always {[t;x]} - t is the table name (rarely needed
// inside the handler itself), x is the batch of new rows.
.oq.cep.addHandler[`quote;{[t;x]
  out:select timestamp,sym,mid:(bid+ask)%2 from x;
  if[count out;
    // `mid` upsert makes the result queryable directly against THIS
    // CEP (try: h "select from mid" once it's running) - the same
    // "accumulate locally" pattern modules/analytics/primeFinance/
    // primeFinance.q's own
    // handlers use for their state tables (.prime.positions,:enlist
    // row, etc.), rather than something every module does.
    `mid upsert out;
    // .u.updNL separately publishes out as a new `mid` update to
    // whatever's subscribed to THIS cep - exactly the same call an
    // RDB/idb writer/another CEP would make to publish, since a CEP
    // looks exactly like a tickerplant to its own subscribers (see
    // README's "Modules" section on CEP chaining). Local accumulation
    // and downstream publishing are independent - a real module might
    // do either, both, or neither depending on whether anything needs
    // to query this CEP's own state versus just relay it onward.
    .u.updNL[`mid;out]];
 };`exampleMidCalc];

-1 "example CEP ready: publishing derived `mid` off every `quote` update";
