#!/bin/bash
# tests/sh/run_backtest_test.sh
# Acceptance test for the backtest module (modules/backtest/backtest.q +
# modules/backtest/run.q - see README's "Backtesting" section). Strictly
# read-only against the real EFX archive, same guarantee run_efx_test.sh
# already documents - never calls a save/checkpoint/EOD function against
# it. Skips itself (not a failure) if the archive isn't present on the
# machine running the tests, exactly like run_efx_test.sh does for the
# same archive - set EFX_ROOT to point it elsewhere. Runs each example
# alpha with the pipeline's own defaults (portfolio=direction,
# risk=none, execution=immediate) - sma, meanrev, and candle (a
# modules/analytics/candle/candle.q pattern wrapped via .bt.alphas.candlePattern) -
# then one run with every stage overridden to a non-default choice at
# once, all against a single real day already confirmed to have
# 1-minute bar data (aud_cad, 2020.01.15) -
# checking the printed report for the expected stats fields, a non-zero
# bar count, and no errors. The last run is what actually proves the
# four pipeline stages compose together, not just that each works alone.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/tests/logs"
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

if [ ! -d "$EFX_ROOT" ]; then
  echo "SKIP: EFX_ROOT ($EFX_ROOT) not found on this machine - nothing to test"
  exit 0
fi

mkdir -p "$LOGS"

echo "=== running sma strategy against aud_cad, 2020.01.15 ==="
smaOut=$(cd "$ROOT" && "$Q" modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy sma -fastN 5 -slowN 20 -q < /dev/null 2>&1)
echo "$smaOut" | tee "$LOGS/backtest_sma.log"

echo "$smaOut" | grep -q "^Loaded [1-9][0-9]* bar(s) for aud_cad"
check $? "sma: loaded a non-zero bar count"
echo "$smaOut" | grep -q "^totalReturn"
check $? "sma: stats include totalReturn"
echo "$smaOut" | grep -q "^sharpe"
check $? "sma: stats include sharpe"
echo "$smaOut" | grep -q "^maxDrawdown"
check $? "sma: stats include maxDrawdown"
echo "$smaOut" | grep -q "^hitRate"
check $? "sma: stats include hitRate"
echo "$smaOut" | grep -qi "error\|'type\|'nyi\|'length"
[ $? -ne 0 ]
check $? "sma: no error in output"

echo "=== running meanrev strategy against aud_cad, 2020.01.15 ==="
mrOut=$(cd "$ROOT" && "$Q" modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy meanrev -lookback 30 -zEntry 1.5 -q < /dev/null 2>&1)
echo "$mrOut" | tee "$LOGS/backtest_meanrev.log"

echo "$mrOut" | grep -q "^Loaded [1-9][0-9]* bar(s) for aud_cad"
check $? "meanrev: loaded a non-zero bar count"
echo "$mrOut" | grep -q "^totalReturn"
check $? "meanrev: stats include totalReturn"
echo "$mrOut" | grep -qi "error\|'type\|'nyi\|'length"
[ $? -ne 0 ]
check $? "meanrev: no error in output"

echo "=== running candle strategy (hammer pattern) against aud_cad, 2020.01.15 ==="
candleOut=$(cd "$ROOT" && "$Q" modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 -strategy candle -pattern hammer -q < /dev/null 2>&1)
echo "$candleOut" | tee "$LOGS/backtest_candle.log"

echo "$candleOut" | grep -q "^Loaded [1-9][0-9]* bar(s) for aud_cad"
check $? "candle: loaded a non-zero bar count"
echo "$candleOut" | grep -q "candle (hammer)"
check $? "candle: report banner names the pattern"
echo "$candleOut" | grep -q "^totalReturn"
check $? "candle: stats include totalReturn"
echo "$candleOut" | grep -qi "error\|'type\|'nyi\|'length"
[ $? -ne 0 ]
check $? "candle: no error in output"

echo "=== running full non-default pipeline (momentum/confweighted/maxdd/twap) against aud_cad, 2020.01.15 ==="
pipeOut=$(cd "$ROOT" && "$Q" modules/backtest/run.q -sym aud_cad -sDate 2020.01.15 -eDate 2020.01.15 \
  -strategy momentum -lookback 15 -portfolio confweighted -risk maxdd -ddLimit 0.02 -execution twap -phaseIn 5 \
  -q < /dev/null 2>&1)
echo "$pipeOut" | tee "$LOGS/backtest_pipeline.log"

echo "$pipeOut" | grep -q "^Loaded [1-9][0-9]* bar(s) for aud_cad"
check $? "pipeline: loaded a non-zero bar count"
echo "$pipeOut" | grep -q "momentum / confweighted / maxdd / twap"
check $? "pipeline: report banner reflects all four overridden stages"
echo "$pipeOut" | grep -q "^totalReturn"
check $? "pipeline: stats include totalReturn"
echo "$pipeOut" | grep -qi "error\|'type\|'nyi\|'length"
[ $? -ne 0 ]
check $? "pipeline: no error in output"

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
