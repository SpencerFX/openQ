#!/bin/bash
# tests/run_pipeline_test.sh
# End-to-end acceptance test for openQ/core: starts tp/rdb (an active/
# standby pair - see core/rdb.q's header)/hdb/gw, publishes sample ticks,
# queries via the gateway (RDB path), runs an EOD save-down, then queries
# again (HDB path) and checks the row count is preserved.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
TESTS="$ROOT/tests"
LOGS="$TESTS/logs"
DATA="$ROOT/examples/data"
Q=/c/q/w64/q.exe
mkdir -p "$LOGS"

pass=0
fail=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "PASS: $2"
    pass=$((pass+1))
  else
    echo "FAIL: $2"
    fail=$((fail+1))
  fi
}

cleanup() {
  taskkill //F //IM q.exe > /dev/null 2>&1
}
trap cleanup EXIT

echo "=== resetting example data ==="
rm -rf "$DATA/tplogs" "$DATA/hdb"
mkdir -p "$DATA/tplogs" "$DATA/hdb"

cleanup
sleep 1

cd "$CORE"
echo "=== starting tp ==="
"$Q" init.q -procType tp -name tp0 -port 5010 -tplogdir "$DATA/tplogs" -bmode 0 > "$LOGS/tp.log" 2>&1 &
sleep 1
echo "=== starting rdb (active/standby pair) ==="
"$Q" init.q -procType rdb -name rdb0 -port1 5011 -port2 5100 -instance 1 -tpaddr :localhost:5010 -hdbroot "$DATA/hdb" > "$LOGS/rdb_1.log" 2>&1 &
"$Q" init.q -procType rdb -name rdb0 -port1 5011 -port2 5100 -instance 2 -tpaddr :localhost:5010 -hdbroot "$DATA/hdb" > "$LOGS/rdb_2.log" 2>&1 &
sleep 1
echo "=== starting hdb ==="
"$Q" init.q -procType hdb -name hdb0 -port 5012 -hdbroot "$DATA/hdb" > "$LOGS/hdb.log" 2>&1 &
sleep 1
echo "=== starting gw ==="
"$Q" init.q -procType gw -name gw0 -port 5013 -rdbaddr :localhost:5011 -hdbaddr :localhost:5012 > "$LOGS/gw.log" 2>&1 &
sleep 2

echo "=== publishing sample ticks ==="
"$Q" "$TESTS/q/publish.q" -q < /dev/null
sleep 1

echo "=== querying via gateway (RDB path) ==="
out1=$("$Q" "$TESTS/q/query_client.q" -q < /dev/null 2>&1)
echo "$out1"
echo "$out1" | grep -q "QUERY OK: 20 row(s)"
check $? "pre-EOD query returns 20 rows from RDB"

echo "=== verifying rdb_2 (standby) never received any of it ==="
standbycount=$("$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5100";
show h "count quote";
hclose h;
exit 0
EOF
)
echo "rdb_2 (standby) quote row count: $standbycount"
echo "$standbycount" | grep -qx "0"
check $? "standby rdb never subscribed, so it got none of the published data"

echo "=== running EOD save-down ==="
out2=$("$Q" "$TESTS/q/eod_client.q" -q < /dev/null 2>&1)
echo "$out2"
echo "$out2" | grep -q "eod done"
check $? "EOD save-down completed"
sleep 1

echo "=== querying via gateway (HDB path, post-EOD) ==="
out3=$("$Q" "$TESTS/q/query_client.q" -q < /dev/null 2>&1)
echo "$out3"
echo "$out3" | grep -q "QUERY OK: 20 row(s)"
check $? "post-EOD query still returns 20 rows (now from HDB)"

echo "=== verifying RDB was actually flushed (data now lives on HDB, not RDB) ==="
rdbcount=$("$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5011";
show h "count quote";
hclose h;
exit 0
EOF
)
echo "RDB quote row count post-EOD: $rdbcount"
echo "$rdbcount" | grep -qx "0"
check $? "RDB quote table is empty post-EOD (data moved to HDB)"

echo ""
echo "=== logs (tail) ==="
for f in tp rdb_1 rdb_2 hdb gw; do
  echo "--- $f.log ---"
  tail -5 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
