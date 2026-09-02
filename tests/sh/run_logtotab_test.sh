#!/bin/bash
# tests/run_logtotab_test.sh
# Acceptance test for core/utils/logToTab.q: starts a dedicated "mon" TP+RDB
# pair running schemas/schema_mon.q (the exact same tp/rdb pipeline as the
# default demo stack, just pointed at a different schema), then starts a
# regular openQ process ("hostproc") that loads logToTab.q, connects to the
# mon TP, and logs a few messages. Verifies the rows land on the mon RDB's
# `logs` table with the right banner fields (process name, level, code,
# message), and that logging locally (the ring buffer in utils/log.q)
# still works unchanged alongside the forwarding.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
TESTS="$ROOT/tests"
LOGS="$TESTS/logs"
DATA="$ROOT/examples/data"
Q=/c/q/w64/q.exe

pass=0
fail=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "PASS: $2"; pass=$((pass+1))
  else
    echo "FAIL: $2"; fail=$((fail+1))
  fi
}

cleanup() { taskkill //F //IM q.exe > /dev/null 2>&1; }
trap cleanup EXIT

echo "=== resetting example data ==="
rm -rf "$DATA/tplogs_mon" "$DATA/hdb_mon" "$DATA/tplogs_lt_host"
mkdir -p "$DATA/tplogs_mon" "$DATA/tplogs_lt_host" "$LOGS"
cleanup
sleep 1

cd "$CORE"
echo "=== starting mon tp (schemas/schema_mon.q) ==="
"$Q" init.q -procType tp -name mon_tp -port 5020 -schema ../schemas/schema_mon.q -tplogdir "$DATA/tplogs_mon" -bmode 0 > "$LOGS/lt_mon_tp.log" 2>&1 &
sleep 1
echo "=== starting mon rdb ==="
"$Q" init.q -procType rdb -name mon_rdb -port 5021 -tpaddr :localhost:5020 -hdbroot "$DATA/hdb_mon" -schema ../schemas/schema_mon.q > "$LOGS/lt_mon_rdb.log" 2>&1 &
sleep 1

echo "=== starting a regular host process that will load logToTab.q ==="
"$Q" init.q -procType tp -name hostproc -port 5010 -tplogdir "$DATA/tplogs_lt_host" -bmode 0 > "$LOGS/lt_host.log" 2>&1 &
sleep 1

echo "=== loading logToTab.q into hostproc and logging some messages ==="
loadOut=$(timeout 10 "$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5010";
h "system \"l utils/logToTab.q\"";
-1 "logToTab loaded: ",string h ".util.logToTab.info.loaded";
h ".util.logToTab.connect[`:localhost:5020]";
-1 "connected to mon tp: ",string h "not null .util.logToTab.monHandle";
h ".util.logToTab.log[`INFO;`TS_I001;\"test info message\"]";
h ".util.logToTab.log[`ERROR;`TS_E001;\"test error message\"]";
-1 "local ring buffer count: ",string h "count .util.log.tab";
hclose h;
exit 0
EOF
)
echo "$loadOut"
echo "$loadOut" | grep -q "logToTab loaded: 1"
check $? "logToTab.q loaded into a running process without error"
echo "$loadOut" | grep -q "connected to mon tp: 1"
check $? "logToTab.q connected to the mon tickerplant"
echo "$loadOut" | grep -q "local ring buffer count: 2"
check $? "local .util.log.tab ring buffer still recorded both messages"

sleep 2
echo "=== checking mon rdb's logs table ==="
monOut=$(timeout 10 "$Q" -q < /dev/null 2>&1 <<'EOF'
\c 25 400
h:hopen `$":localhost:5021";
-1 "log count: ",string h "count logs";
show h "select from logs";
-1 "syms: ",", " sv string h "exec distinct sym from logs";
-1 "levels: ",", " sv string h "exec distinct level from logs";
-1 "codes: ",", " sv string h "exec distinct code from logs";
-1 "messages: ",", " sv h "exec message from logs";
hclose h;
exit 0
EOF
)
echo "$monOut"
echo "$monOut" | grep -q "log count: 2"
check $? "both log messages landed on the mon RDB's logs table"
echo "$monOut" | grep -q "syms: hostproc"
check $? "log rows are tagged with the publishing process's -name"
echo "$monOut" | grep -q "test info message"
check $? "INFO message text made it through"
echo "$monOut" | grep -q "test error message"
check $? "ERROR message text made it through"
echo "$monOut" | grep -q "TS_I001"
check $? "log code made it through"

echo ""
echo "=== logs (tail) ==="
for f in lt_mon_tp lt_mon_rdb lt_host; do
  echo "--- $f.log ---"
  tail -8 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
