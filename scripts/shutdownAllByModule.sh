#!/bin/bash
# scripts/shutdownAllByModule.sh
# Stops everything scripts/startupAllByModule.sh started for one module,
# using the PIDs it recorded in openq-<module>.pids. Safe to run even if
# some/all processes already died.
#
# Usage: ./scripts/shutdownAllByModule.sh <module-name>
#   e.g. ./scripts/shutdownAllByModule.sh mon
set -uo pipefail

MODULE="${1:-}"
if [ -z "$MODULE" ]; then
  echo "Usage: $0 <module-name>" >&2
  echo "e.g.:  $0 mon" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/scripts/logs"
PIDFILE="$LOGS/openq-${MODULE}.pids"

if [ ! -f "$PIDFILE" ]; then
  echo "No $PIDFILE found - module '$MODULE' isn't running (or was started another way)."
  exit 0
fi

echo "=== stopping module '$MODULE' ==="
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
