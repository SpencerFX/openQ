// tests/cep_analytics_check.q - connects to a running CEP and inspects its
// internal analytics-library state to confirm ingestion actually happened.
h:hopen `$":localhost:5014";

spreadCount:h "count .spread.latest[]";
markoutCount:h "(count .markout.pending)+count .markout.completed";
impactCount:h "(count .impact.pending)+count .impact.completed";

-1 "spread.latest rows: ",string spreadCount;
-1 "markout pending+completed rows: ",string markoutCount;
-1 "impact pending+completed rows: ",string impactCount;

-1 "sample spread.latest row:";
show h "1#.spread.latest[]";
-1 "sample composed spread (compose adds totalSprd):";
show h ".spread.compose 1#.spread.latest[]";

hclose h;

ok:(spreadCount>0) and (markoutCount>0) and (impactCount>0);
if[not ok;-1 "INGESTION CHECK FAILED";exit 1];
-1 "INGESTION CHECK OK";
exit 0
