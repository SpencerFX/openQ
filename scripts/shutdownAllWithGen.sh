#!/bin/bash
# scripts/shutdownAllWithGen.sh
# Stops everything scripts/startupAllWithGen.sh started, using the PIDs
# it recorded in openq-all-gen.pids. Safe to run even if some/all
# processes already died. Separate from shutdown.sh (plain default
# pipeline, openq.pids) and shutdownAll.sh (all pipelines, generator off,
# openq-all.pids) - use this one for anything started via
# startupAllWithGen.sh.
#
# Usage: ./scripts/shutdownAllWithGen.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/scripts/logs"
PIDFILE="$LOGS/openq-all-gen.pids"

if [ ! -f "$PIDFILE" ]; then
  echo "No $PIDFILE found - nothing to stop (not running, or started another way)."
  exit 0
fi

echo "=== stopping all openQ pipelines (generator-enabled run) ==="
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
