#!/bin/bash
# tests/run_cep_analytics_test.sh
# Verifies openQ/modules/analytics/spread/spread.q and markOutImpact.q can be loaded as
# libraries into a cep.q process and actually ingest data: starts a TP and
# a CEP running tests/cep_analytics_handler.q (which loads both libraries
# and adapts generic quote/trade ticks into each library's real-time
# ingest calls), publishes sample ticks, then queries the CEP's internal
# state to confirm each library actually recorded something.
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
rm -rf "$DATA/tplogs_cep_analytics"
mkdir -p "$DATA/tplogs_cep_analytics" "$LOGS"

cleanup
sleep 1

cd "$CORE"
echo "=== starting tp ==="
"$Q" init.q -procType tp -name tp0 -port 5010 -tplogdir "$DATA/tplogs_cep_analytics" -bmode 0 > "$LOGS/cepa_tp.log" 2>&1 &
sleep 1
echo "=== starting cep (loading analytics libraries) ==="
"$Q" init.q -procType cep -name cep0 -port 5014 -srcaddr :localhost:5010 -cepscript "$TESTS/q/cep_analytics_handler.q" > "$LOGS/cepa_cep.log" 2>&1 &
sleep 2

echo "=== publishing sample quotes and trades ==="
"$Q" "$TESTS/q/publish.q" -q < /dev/null
sleep 1

echo "=== checking CEP ingested data into both analytics libraries ==="
out=$(timeout 10 "$Q" "$TESTS/q/cep_analytics_check.q" -q < /dev/null 2>&1)
echo "$out"
echo "$out" | grep -q "INGESTION CHECK OK"
check $? "spread.q and markOutImpact.q both ingested ticks via the CEP"

echo ""
echo "=== logs (tail) ==="
for f in cepa_tp cepa_cep; do
  echo "--- $f.log ---"
  tail -10 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
