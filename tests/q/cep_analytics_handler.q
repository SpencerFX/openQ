// tests/cep_analytics_handler.q
// Example CEP deployment script (see -cepscript in config.q): loads the
// spread build-up/attribution and markout/impact analytics libraries
// (openQ/modules/analytics/spread/spread.q, modules/analytics/markout/
// markOutImpact.q - general-purpose, not specific to this CEP) and
// adapts openQ/core's generic quote/trade ticks
// into the shape each library expects, feeding their real-time ingest
// entrypoints as ticks arrive. Uses bracket indexing (row[`col]) throughout
// rather than backtick-chained (row`col) - q parses strictly right-to-left
// with no operator precedence, so e.g. row`bid+row`ask silently parses as
// row[(`bid+row[`ask])] (adding a symbol to a float) instead of the
// intended (row[`bid])+(row[`ask]); brackets remove the ambiguity.
system "l ../modules/analytics/spread/spread.q";
system "l ../modules/analytics/markout/markOutImpact.q";

// quote -> .spread.onQuote (component build-up is synthetic here: a real
// pricing engine would already know each component; this demo just splits
// the observed bid/ask spread across them so the ingest path is exercised
// with realistic-shaped numbers) + .markout.onRate / .impact.onBook (both
// treat the quote mid as the reference rate feed they match trades/orders against)
.oq.cep.addHandler[`quote;{[t;x]
  {[row]
    mid:(row[`bid]+row[`ask])%2;
    total:row[`ask]-row[`bid];
    q:`sym`aggression`marketStatus`time`weight`refSprd`baseSprd`clientSprd`volSprd`smoothSprd`fallbackSprd`alphaSprd!
      (row[`sym];`low;`normal;row[`timestamp];1f;0.4*total;0.2*total;0.1*total;0.15*total;0.05*total;0.05*total;0.05*total);
    .spread.onQuote q;
    .markout.onRate `sym`time`mid!(row[`sym];row[`timestamp];mid);
    .impact.onBook `sym`time`mid!(row[`sym];row[`timestamp];mid);
   } each 0!x;
 };`analyticsIngestQuote];

// trade -> .markout.onTrade (client deal markout) + .impact.onOrder (order
// impact) - both need an ID column the generic trade schema doesn't have,
// synthesized here from the row's timestamp
.oq.cep.addHandler[`trade;{[t;x]
  {[row]
    .markout.onTrade `tradeID`tradeTime`tradeRate`sym!(`long$row[`timestamp];row[`timestamp];row[`price];row[`sym]);
    .impact.onOrder `orderID`orderTime`orderRate`sym`side!(`long$row[`timestamp];row[`timestamp];row[`price];row[`sym];row[`side]);
   } each 0!x;
 };`analyticsIngestTrade];
