#!/bin/bash
# tests/run_massive_feedhandler_test.sh
# Verifies modules/ingest/massive/fh.q's message-handling pipeline: starts a
# real openQ TP and RDB, starts a core/fh.q process pointed at that TP with
# -fhscript modules/ingest/massive/fh.q, then feeds it the EXACT sample
# messages from the Massive WebSocket docs by calling .z.ws directly (this
# machine's kdb+ build doesn't support client-side ws(s):// hopen - see the
# README - so the actual socket connection can't be exercised here;
# everything downstream of receiving a text frame can be, and is).
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
rm -rf "$DATA/tplogs_massive"
mkdir -p "$DATA/tplogs_massive" "$LOGS"
cleanup
sleep 1

cd "$CORE"
echo "=== starting tp ==="
"$Q" init.q -procType tp -name tp0 -port 5010 -schema ../schemas/schema_efx.q -tplogdir "$DATA/tplogs_massive" -bmode 0 > "$LOGS/mf_tp.log" 2>&1 &
sleep 1
echo "=== starting rdb ==="
"$Q" init.q -procType rdb -name rdb0 -port 5011 -schema ../schemas/schema_efx.q -tpaddr :localhost:5010 -hdbroot "$DATA/hdb_massive" > "$LOGS/mf_rdb.log" 2>&1 &
sleep 1

echo "=== starting feed handler (WS connect will fail on this build - expected, see README) ==="
"$Q" init.q -procType fh -name mf0 -port 5018 -fhscript ../modules/ingest/massive/fh.q -apikey testkey -tpaddr :localhost:5010 > "$LOGS/mf_feed.log" 2>&1 &
sleep 1

echo "=== injecting the docs' sample messages directly via .z.ws ==="
injectOut=$(timeout 10 "$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5018";
statusMsg:"[{\"ev\":\"status\",\"status\":\"connected\",\"message\":\"Connected Successfully\"}]";
quoteMsg:"[{\"ev\":\"C\",\"p\":\"USD/CNH\",\"x\":44,\"a\":6.83366,\"b\":6.83363,\"t\":1536036818784}]";
aggMsg:"[{\"ev\":\"CA\",\"pair\":\"USD/EUR\",\"o\":0.8687,\"c\":0.86889,\"h\":0.86889,\"l\":0.8686,\"v\":20,\"s\":1539145740000,\"e\":1539145800000}]";
h (`.z.ws;statusMsg);
h (`.z.ws;quoteMsg);
h (`.z.ws;aggMsg);
-1 "injected ok";
hclose h;
exit 0
EOF
)
echo "$injectOut"
echo "$injectOut" | grep -q "injected ok"
check $? "feed handler process is reachable and .z.ws accepted the sample messages"

sleep 2
echo "=== checking RDB received the transformed fx_tick_massive/fx_m1_massive rows ==="
rdbOut=$(timeout 10 "$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5011";
-1 "fx_tick_massive count: ",string h "count fx_tick_massive";
show h "select from fx_tick_massive";
-1 "fx_m1_massive count: ",string h "count fx_m1_massive";
show h "select from fx_m1_massive";
hclose h;
exit 0
EOF
)
echo "$rdbOut"
echo "$rdbOut" | grep -q "fx_tick_massive count: 1"
check $? "the sample quote (C) event landed on the RDB as a single fx_tick_massive row"
echo "$rdbOut" | grep -q "6.83366"
check $? "quote ask field (a) mapped correctly"
echo "$rdbOut" | grep -q "6.83363"
check $? "quote bid field (b) mapped correctly"
echo "$rdbOut" | grep -q "44 44"
check $? "single exchange field (x) filled both ask_exchange and bid_exchange"
echo "$rdbOut" | grep -q "fx_m1_massive count: 1"
check $? "the sample aggregate (CA) event landed on the RDB as a single fx_m1_massive row"
echo "$rdbOut" | grep -q "0.8687 "
check $? "aggregate open field (o) mapped correctly"
echo "$rdbOut" | grep -q "0.86889 0.86889"
check $? "aggregate high/close fields (h/c) mapped correctly"
echo "$rdbOut" | grep -q "massive"
check $? "aggregate source tagged \`massive"

echo ""
echo "=== logs (tail) ==="
for f in mf_tp mf_rdb mf_feed; do
  echo "--- $f.log ---"
  tail -10 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
