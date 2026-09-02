#!/bin/bash
# tests/run_cep_test.sh
# Acceptance test for cep.q: starts a tickerplant and a CEP process that
# subscribes to it and computes a derived `spread` table from `quote`
# updates, publishes sample quotes, then subscribes directly to the CEP's
# own output (same protocol an RDB uses against a TP) and checks the
# derived rows arrive.
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
rm -rf "$DATA/tplogs_cep"
mkdir -p "$DATA/tplogs_cep" "$LOGS"

cleanup
sleep 1

cd "$CORE"
echo "=== starting tp ==="
"$Q" init.q -procType tp -name tp0 -port 5010 -tplogdir "$DATA/tplogs_cep" -bmode 0 > "$LOGS/cep_tp.log" 2>&1 &
sleep 1
echo "=== starting cep ==="
"$Q" init.q -procType cep -name cep0 -port 5014 -srcaddr :localhost:5010 -cepscript "$TESTS/q/cep_spread_handler.q" > "$LOGS/cep.log" 2>&1 &
sleep 2

echo "=== subscribing to the CEP's derived spread output (in the background, before publishing) ==="
timeout 10 "$Q" "$TESTS/q/cep_subscriber_client.q" -q < /dev/null > "$LOGS/cep_subscriber_client.log" 2>&1 &
sub_pid=$!
sleep 1

echo "=== publishing sample quotes ==="
"$Q" "$TESTS/q/publish.q" -q < /dev/null

wait "$sub_pid"
out=$(cat "$LOGS/cep_subscriber_client.log")
echo "$out"
echo "$out" | grep -q "received 20 spread row(s)"
check $? "CEP publishes 20 derived spread rows for 20 published quotes"

echo ""
echo "=== logs (tail) ==="
for f in cep_tp cep; do
  echo "--- $f.log ---"
  tail -8 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
