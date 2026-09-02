#!/bin/bash
# tests/sh/run_hdb2tplog_test.sh
# Acceptance test for the hdb2tplog module (modules/utils/hdb2tplog/hdb2tplog.q -
# see README's "hdb2tplog" section). No live processes: the module is a
# plain batch script that reads a static on-disk database and writes a
# tickerplant log. This test builds a tiny partitioned HDB (with one
# enum-typed sym column, like a real openQ HDB), runs the module against
# it, and replays the resulting log the same way core/rdb.q would
# (-11! + upd:insert) to confirm every row round-trips - column set,
# ordering, and per-partition aggregates. Also checks -batch 1 (one upd
# message per row), -part (single-partition export), and that the file
# loads clean as a plain library (no args).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/tests/logs"
WORK="$LOGS/hdb2tplog"
Q=/c/q/w64/q.exe

# q sees a win32 path; hand it one via the environment (bash would eat the
# backticks in an unquoted heredoc, so every q snippet below is quoted).
WORK_WIN="$(cd "$ROOT" && pwd -W 2>/dev/null || pwd)/tests/logs/hdb2tplog"
export H2T_WORK="$WORK_WIN"

pass=0
fail=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "PASS: $2"; pass=$((pass+1))
  else
    echo "FAIL: $2"; fail=$((fail+1))
  fi
}

rm -rf "$WORK"
mkdir -p "$WORK/hdb" "$LOGS"

echo "=== building a tiny partitioned HDB (3 date partitions, enum sym col) ==="
"$Q" -q < /dev/null 2>&1 <<'EOF'
w:getenv[`H2T_WORK];
n:1000;
mk:{[d;n] ([] timestamp:asc (`timestamp$d)+n?0D06:00:00.000000000; sym:n?`AUD`BUD`CAD`DUD; px:0.01*n?10000; sz:100*1+n?50i)};
{[w;d;n] (hsym `$ w,"/hdb/",(string d),"/trade/") set .Q.en[hsym `$ w,"/hdb"] mk[d;n]}[w;;n] each 2024.01.01 2024.01.02 2024.01.03;
-1 "partitions: ",", " sv string key hsym `$ w,"/hdb";
exit 0
EOF

echo "=== 1) whole table -> tplog, with -verify and an openQ -schema stub ==="
o1=$(cd "$ROOT" && "$Q" modules/utils/hdb2tplog/hdb2tplog.q -hdb "$WORK_WIN/hdb" -table trade -log "$WORK_WIN/trade.tplog" -schema schemas/schema_efx.q -batch 250 -verify -q < /dev/null 2>&1)
echo "$o1" | tee "$LOGS/hdb2tplog_1.log"
echo "$o1" | grep -q "wrote 3000 row(s)"
check $? "exported all 3000 rows"
echo "$o1" | grep -q "verify OK - replayed 3000 row(s)"
check $? "in-process verify round-trips the row count"
echo "$o1" | grep -qi "error\|'type\|'length\|'par"
[ $? -ne 0 ]
check $? "no error in output"

echo "=== 2) replay (core/rdb.q style: -11! + upd:insert) and cross-check ==="
o2=$("$Q" -q < /dev/null 2>&1 <<'EOF'
w:getenv[`H2T_WORK];
system "l ",w,"/hdb";
/ resolve the on-disk enum sym col so we compare like-for-like with the
/ log (which the module deliberately writes as plain symbols)
src:0!select c:count i, s:sum sz, mn:min timestamp, mx:max timestamp by sym from select sym:`$string sym, sz, timestamp from trade;
upd:{[t;x] if[not `rr in tables[]; rr::0#x]; rr::rr,x};
-11! hsym `$ w,"/trade.tplog";
rep:0!select c:count i, s:sum sz, mn:min timestamp, mx:max timestamp by sym from rr;
-1 "aggs match      : ",-3! src~rep;
-1 "cols (no date)  : ",-3! (cols[`trade] except `date)~cols rr;
-1 "timestamp sorted: ",-3! (asc rr`timestamp)~rr`timestamp;
-1 "sym is symbol   : ",-3! 11h=type rr`sym;
exit 0
EOF
)
echo "$o2" | tee "$LOGS/hdb2tplog_2.log"
echo "$o2" | grep -q "aggs match      : 1b"
check $? "replayed per-sym aggregates equal the source HDB"
echo "$o2" | grep -q "cols (no date)  : 1b"
check $? "replayed columns match on-disk columns (virtual partition col dropped)"
echo "$o2" | grep -q "timestamp sorted: 1b"
check $? "each batch was written in timestamp order"
echo "$o2" | grep -q "sym is symbol   : 1b"
check $? "enum sym column resolved to plain symbols in the log"

echo "=== 3) -batch 1 writes one upd message per row ==="
o3=$(cd "$ROOT" && "$Q" modules/utils/hdb2tplog/hdb2tplog.q -hdb "$WORK_WIN/hdb" -table trade -log "$WORK_WIN/perrow.tplog" -batch 1 -verify -q < /dev/null 2>&1)
echo "$o3" | tee "$LOGS/hdb2tplog_3.log"
echo "$o3" | grep -q "wrote 3000 row(s) in 3000 message(s)"
check $? "3000 rows -> 3000 messages"
o3b=$("$Q" -q < /dev/null 2>&1 <<'EOF'
w:getenv[`H2T_WORK];
c:0; n:0;
upd:{[t;x] c+:1; n+:count x};
m:-11! hsym `$ w,"/perrow.tplog";
-1 "msgs/calls/rows: ",("," sv string (m;c;n)),$[(m=c)&c=n;" OK";" MISMATCH"];
exit 0
EOF
)
echo "$o3b" | tee -a "$LOGS/hdb2tplog_3.log"
echo "$o3b" | grep -q "msgs/calls/rows: 3000,3000,3000 OK"
check $? "each message carries exactly one row on replay"

echo "=== 4) -part exports a single partition ==="
o4=$(cd "$ROOT" && "$Q" modules/utils/hdb2tplog/hdb2tplog.q -hdb "$WORK_WIN/hdb" -table trade -log "$WORK_WIN/day2.tplog" -part 2024.01.02 -verify -q < /dev/null 2>&1)
echo "$o4" | tee "$LOGS/hdb2tplog_4.log"
echo "$o4" | grep -q "1 partition(s): 2024.01.02 .. 2024.01.02"
check $? "-part restricted the export to the requested partition"
echo "$o4" | grep -q "wrote 1000 row(s)"
check $? "single partition = 1000 rows"

echo "=== 5) file loads clean as a plain library (no args) ==="
o5=$(cd "$ROOT" && "$Q" -q < /dev/null 2>&1 <<'EOF'
system "l modules/utils/hdb2tplog/hdb2tplog.q";
-1 "loaded: ",-3! .oq.info.h2t.loaded;
-1 "funcs: ",", " sv string asc key `.oq.h2t;
exit 0
EOF
)
echo "$o5" | tee "$LOGS/hdb2tplog_5.log"
echo "$o5" | grep -q "loaded: 1b"
check $? "sets .oq.info.h2t.loaded and defines the namespace without running"

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
