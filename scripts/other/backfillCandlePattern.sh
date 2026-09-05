#!/bin/bash
# scripts/other/backfillCandlePattern.sh
# Backfills modules/analytics/candle/run.q (10-timeframe, 32-pattern
# candlestick scan) across every real trading date currently in
# eq_m1_yfinance - one q modules/analytics/candle/run.q -date <dt> call
# per date, discovered dynamically off the live eq_m1_yfinance gateway
# rather than hardcoded (so a re-run after more history has backfilled
# just covers more dates, no edits needed here). Today itself is excluded
# - it's still live/partial, not a real "whole day" to scan (run.q's own
# default already reflects the same "yesterday, not today" reasoning).
# Requires a running eq_m1_yfinance module (./scripts/startStop/startupAllByModule.sh
# eq_m1_yfinance) - this only reads over its gateway, never touches
# eq_m1_yfinance's own data.
#
# Usage: ./scripts/other/backfillCandlePattern.sh [-hdbroot <path>] [-gwaddr :host:port]
# Defaults match run.q's own (C:/data/db1/ta, :localhost:5119).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/scripts/logs"
Q="${Q_BIN:-q}"

HDBROOT="C:/data/db1/ta"
GWADDR=":localhost:5119"
while [ $# -gt 0 ]; do
  case "$1" in
    -hdbroot) HDBROOT="$2"; shift 2 ;;
    -gwaddr)  GWADDR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$LOGS"

echo "=== discovering real trading dates in eq_m1_yfinance ($GWADDR) ==="
dateList=$(cd "$ROOT" && "$Q" -q < /dev/null 2>&1 <<EOF
h:hopen \`\$"$GWADDR";
neg[h] (\`.oq.gw.query;\`eq_m1_yfinance;\`sym\`exchange\`timestamp;2000.01.01D00:00:00.000000000;.z.d-1;\`;\`);
r:(h[])\`data;
hclose h;
r:update date:\`date\$timestamp from r;
-1 " " sv string asc distinct r\`date;
exit 0
EOF
)
dateList=$(echo "$dateList" | tail -1)
echo "Dates: $dateList"
n=$(echo "$dateList" | wc -w)
echo "$n real trading date(s) to backfill into $HDBROOT"
echo ""

i=0
t0=$(date +%s)
for dt in $dateList; do
  i=$((i+1))
  echo "=== [$i/$n] $dt ==="
  (cd "$ROOT" && "$Q" modules/analytics/candle/run.q -date "$dt" -hdbroot "$HDBROOT" -gwaddr "$GWADDR" -q < /dev/null \
    2>&1 | tee "$LOGS/candlepattern_${dt}.log" | grep -E "^Loaded|^Total candlePattern|^Load:|gateway query failed|no eq_m1_yfinance")
  echo ""
done
t1=$(date +%s)

echo "=== backfill complete: $n date(s) in $((t1-t0))s, logs in $LOGS/candlepattern_<date>.log ==="
