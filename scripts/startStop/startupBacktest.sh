#!/bin/bash
# scripts/startStop/startupBacktest.sh
# Starts modules/backtest/service.q - the long-running counterpart to
# modules/backtest/run.q's one-shot CLI report (see that file's header).
# Not a cfg_proc/ module (no tp/rdb/idb/cep pipeline makes sense for one
# static, read-only archive) - tracked with its own pidfile/log, same
# idea as startupAllByModule.sh's per-module ones, just for this one
# standalone process instead of a whole module.
#
# Usage: ./scripts/startStop/startupBacktest.sh [port] [efxroot]
#   defaults: port 5097, efxroot C:/data/db1/efx
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/scripts/logs"
PIDFILE="$LOGS/openq-backtest.pids"
Q="${Q_BIN:-q}"
PORT="${1:-5097}"
EFXROOT="${2:-C:/data/db1/efx}"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q $0" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "backtest service already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/startStop/shutdownBacktest.sh before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS"
: > "$PIDFILE"

echo "=== starting backtest service on port $PORT (efxroot: $EFXROOT) ==="
(cd "$ROOT" && exec "$Q" modules/backtest/service.q -port "$PORT" -efxroot "$EFXROOT" > "$LOGS/backtest.log" 2>&1) &
echo "backtest $!" >> "$PIDFILE"

echo ""
echo "=== backtest service started ==="
echo "PID recorded in: $PIDFILE"
echo "Log in: $LOGS/backtest.log"
echo "To stop: ./scripts/startStop/shutdownBacktest.sh"
