// tests/q/report_check.q
// Connects to a live report_cep (:localhost:5080) and checks
// .report.latest structurally - printing one "CHECK:<name>:PASS"/
// "CHECK:<name>:FAIL" line per assertion for tests/sh/run_report_test.sh
// to grep. Deliberately avoids exact numeric expectations (timing across
// spread/markout/primeFinance's independent CEPs/RDBs makes those
// fragile) in favor of structural ones: right symbols present, no nulls
// where there shouldn't be any, and the one comparison guaranteed by the
// simulators' own hardcoded economics regardless of timing - GME is
// wider/worse than AAPL on every pillar.
h:hopen `:localhost:5080;
t:0!h "select from .report.latest";
hclose h;

chk:{[name;ok] -1 "CHECK:",name,":",$[ok;"PASS";"FAIL"]};

chk["nonzero_rows";0<count t];

syms:exec sym from t;
chk["has_aapl";`AAPL in syms];
chk["has_gme";`GME in syms];
chk["has_tsla";`TSLA in syms];
chk["has_nvda";`NVDA in syms];

aapl:first select from t where sym=`AAPL;
gme:first select from t where sym=`GME;

chk["aapl_spread_notnull";not null aapl`spreadCostBp];
chk["gme_spread_notnull";not null gme`spreadCostBp];
chk["gme_spread_worse";gme[`spreadCostBp]>aapl[`spreadCostBp]];

chk["aapl_markout_notnull";not null aapl`markoutBp];
chk["gme_markout_notnull";not null gme`markoutBp];
chk["gme_markout_worse";gme[`markoutBp]>aapl[`markoutBp]];

chk["aapl_impact_notnull";not null aapl`impactBp];
chk["gme_impact_notnull";not null gme`impactBp];
chk["gme_impact_worse";gme[`impactBp]>aapl[`impactBp]];

chk["aapl_financing_notnull";not null aapl`financingFeeBp];
chk["gme_financing_notnull";not null gme`financingFeeBp];
chk["gme_financing_worse";gme[`financingFeeBp]>aapl[`financingFeeBp]];

exit 0
