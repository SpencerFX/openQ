#!/bin/bash
# scripts/startStop/shutdownBacktest.sh
# Stops the backtest service started by scripts/startStop/startupBacktest.sh,
# using the PID it recorded. Safe to run even if it already died.
#
# Usage: ./scripts/startStop/shutdownBacktest.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/scripts/logs"
PIDFILE="$LOGS/openq-backtest.pids"

if [ ! -f "$PIDFILE" ]; then
  echo "No $PIDFILE found - backtest service isn't running (or was started another way)."
  exit 0
fi

echo "=== stopping backtest service ==="
stopped=0
missing=0
while read -r role pid; do
  [ -z "${pid:-}" ] && continue
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      taskkill //F //PID "$pid" > /dev/null 2>&1
    fi
    if kill -0 "$pid" 2>/dev/null; then
      echo "FAILED to stop $role (pid $pid)"
    else
      echo "stopped $role (pid $pid)"
      stopped=$((stopped+1))
    fi
  else
    echo "$role (pid $pid) already not running"
    missing=$((missing+1))
  fi
done < "$PIDFILE"

rm -f "$PIDFILE"
echo ""
echo "=== done: $stopped stopped, $missing already gone ==="
