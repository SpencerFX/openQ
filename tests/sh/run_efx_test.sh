#!/bin/bash
# tests/run_efx_test.sh
# Verifies openQ integrates with an existing, real on-disk EFX historical
# HDB (tick + 1min/daily bars, 2009.09.25-2026.05.22, tens of millions of
# rows/day) rather than a fixture openQ generated itself. Strictly
# READ-ONLY: this script (and everything it starts) only ever loads and
# queries EFX_ROOT - nothing in openQ/core ever calls a save/checkpoint/EOD
# function against it, and this test doesn't either. Starts a dedicated HDB
# process against the real archive plus a gateway in front of it, and
# checks both a direct HDB query and a gateway-routed query return the
# same, correct, non-empty result for a real historical window.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
TESTS="$ROOT/tests"
LOGS="$TESTS/logs"
Q=/c/q/w64/q.exe
EFX_ROOT="${EFX_ROOT:-C:/data/db1/efx}"

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

if [ ! -d "$EFX_ROOT" ]; then
  echo "SKIP: EFX_ROOT ($EFX_ROOT) not found on this machine - nothing to test"
  exit 0
fi

mkdir -p "$LOGS"
cleanup
sleep 1

cd "$CORE"
echo "=== starting read-only HDB against the real EFX archive ==="
"$Q" init.q -procType hdb -name efxhdb -port 5016 -hdbroot "$EFX_ROOT" -schema ../schemas/schema_efx.q > "$LOGS/efx_hdb.log" 2>&1 &
sleep 3
echo "=== starting a gateway in front of it ==="
"$Q" init.q -procType gw -name gwefx -port 5017 -hdbaddr :localhost:5016 > "$LOGS/efx_gw.log" 2>&1 &
sleep 3

echo "=== direct HDB query: fx_tick_massive, aud_cad, one hour ==="
directOut=$(timeout 20 "$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5016";
sTime:2026.05.22D00:00:00.000000000;
eTime:2026.05.22D01:00:00.000000000;
res:h (`.oq.query.query;`fx_tick_massive;`;sTime;eTime;`aud_cad;`);
-1 "row count: ",string count res;
-1 "cols: ",", " sv string cols res;
hclose h;
exit 0
EOF
)
echo "$directOut"
echo "$directOut" | grep -q "row count: 8815"
check $? "direct HDB query returns the expected row count for a real historical window"
echo "$directOut" | grep -q "cols: timestamp, sym, ask, bid, ask_exchange, bid_exchange"
check $? "direct HDB query returns the real on-disk column set unchanged"

echo "=== same query, routed through the gateway ==="
gwOut=$(timeout 20 "$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5017";
sTime:2026.05.22D00:00:00.000000000;
eTime:2026.05.22D01:00:00.000000000;
neg[h] (`.oq.gw.query;`fx_tick_massive;`;sTime;eTime;`aud_cad;`);
res:h[];
-1 "error: ",string res`error;
-1 "row count: ",string count res`data;
hclose h;
exit 0
EOF
)
echo "$gwOut"
echo "$gwOut" | grep -q "error: 0"
check $? "gateway-routed query succeeds"
echo "$gwOut" | grep -q "row count: 8815"
check $? "gateway-routed query returns the same row count as the direct query"

echo ""
echo "=== logs (tail) ==="
for f in efx_hdb efx_gw; do
  echo "--- $f.log ---"
  tail -6 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
