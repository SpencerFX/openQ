#!/bin/bash
# tests/sh/run_report_test.sh
# Acceptance test for the report module (modules/analytics/report/cep.q +
# deskRisk.q - see README's "Desk Risk & TCA" section): starts
# spread/markout/primeFinance via the existing scripts/startupAllByModule.sh
# (each already has a complete cfg_proc/modules/<name>/ set - no reason to
# hand-roll individual init.q calls for a 6-process trio the way the
# single-pipeline tests above do), runs each module's own simulator once,
# then starts report LAST so its immediate at-startup refresh (see
# .report.refreshSafe[] at the bottom of modules/analytics/report/cep.q) picks up
# fresh data right away rather than waiting on its 1-minute timer.
# Verifies tests/q/report_check.q's structural checks: all four simulated
# symbols appear, no nulls on spread/markout/impact/financing for AAPL or
# GME, and GME - given deliberately worse economics in every simulator -
# actually comes out worse than AAPL on every pillar.
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

cleanup() {
  "$ROOT/scripts/shutdownAllByModule.sh" report > /dev/null 2>&1
  "$ROOT/scripts/shutdownAllByModule.sh" primeFinance > /dev/null 2>&1
  "$ROOT/scripts/shutdownAllByModule.sh" markout > /dev/null 2>&1
  "$ROOT/scripts/shutdownAllByModule.sh" spread > /dev/null 2>&1
}
trap cleanup EXIT

echo "=== resetting example data ==="
cleanup
rm -rf "$DATA/spread" "$DATA/markout" "$DATA/report"
mkdir -p "$LOGS"

echo "=== starting spread, markout, primeFinance ==="
"$ROOT/scripts/startupAllByModule.sh" spread
"$ROOT/scripts/startupAllByModule.sh" markout
"$ROOT/scripts/startupAllByModule.sh" primeFinance
sleep 2

echo "=== running each module's simulator ==="
"$Q" "$ROOT/modules/analytics/spread/simulator.q"
"$Q" "$ROOT/modules/analytics/markout/simulator.q"
"$Q" "$ROOT/modules/analytics/primeFinance/simulator.q" > /dev/null
sleep 2

echo "=== starting report (picks up fresh data on its immediate startup refresh) ==="
"$ROOT/scripts/startupAllByModule.sh" report
sleep 2

echo "=== checking .report.latest ==="
out=$("$Q" "$TESTS/q/report_check.q" -q < /dev/null 2>&1)
echo "$out"

for name in nonzero_rows has_aapl has_gme has_tsla has_nvda \
  aapl_spread_notnull gme_spread_notnull gme_spread_worse \
  aapl_markout_notnull gme_markout_notnull gme_markout_worse \
  aapl_impact_notnull gme_impact_notnull gme_impact_worse \
  aapl_financing_notnull gme_financing_notnull gme_financing_worse; do
  echo "$out" | grep -qx "CHECK:${name}:PASS"
  check $? "$name"
done

echo ""
echo "=== logs (tail) ==="
for f in spread_cep markout_cep primeFinance_cep report_cep; do
  echo "--- bymod_${f}.log ---"
  tail -10 "$ROOT/scripts/logs/bymod_${f}.log" 2>/dev/null
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
