#!/bin/bash
# scripts/startupAllByModule.sh
# Starts every process one module defines under cfg_proc/modules/<name>/ -
# e.g. ./scripts/startupAllByModule.sh mon starts mon's
# tp/rdb/idb/hdb/cep, and nothing else. Fully generic: doesn't hardcode
# which roles a given module has - it starts whatever
# cfg_proc/modules/<name>/*.json files actually exist, in a preference
# order (tp, cep, rdb, idb, hdb, fh, gw, housekeeping, then anything else
# alphabetically) that matches every module's default flow: fh -> tp ->
# cep -> rdb -> hdb (rdb subscribes to its cep, not its tp, directly -
# see the README's "Modules" section for why; idb doesn't subscribe to
# either - see core/idb.q's header for its pivot-and-harvest design
# instead). Only covers cfg_proc/modules/ - the default pipeline
# (cfg_proc/*.json directly) is scripts/startup.sh's job, not this one's.
#
# Usage: ./scripts/startupAllByModule.sh <module-name>
#   e.g. ./scripts/startupAllByModule.sh mon
# PIDs recorded in scripts/logs/openq-<module>.pids; matching stop script
# is shutdownAllByModule.sh <module-name>. Independent of startup.sh/
# startupAll.sh/startupAllWithGen.sh and their own pidfiles - safe to run
# alongside any of them, since different modules never share ports.
set -uo pipefail

MODULE="${1:-}"
if [ -z "$MODULE" ]; then
  echo "Usage: $0 <module-name>" >&2
  echo "e.g.:  $0 mon" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
MODCFG="$ROOT/cfg_proc/modules/$MODULE"
LOGS="$ROOT/scripts/logs"
DATA="$ROOT/examples/data/$MODULE"
Q="${Q_BIN:-q}"
PIDFILE="$LOGS/openq-${MODULE}.pids"

if [ ! -d "$MODCFG" ]; then
  echo "No such module config dir: $MODCFG" >&2
  echo "Available modules:" >&2
  ls -1 "$ROOT/cfg_proc/modules" >&2
  exit 1
fi

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q $0 $MODULE" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "openQ module '$MODULE' already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/shutdownAllByModule.sh $MODULE before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS" "$DATA/tplogs" "$DATA/hdb" "$DATA/idb_staging"
: > "$PIDFILE"

start_proc() {
  local role="$1" config="$2"; shift 2
  echo "=== starting ${MODULE}_${role} ($config) ==="
  (cd "$CORE" && exec "$Q" initFromCfg.q -config "$config" "$@" > "$LOGS/bymod_${MODULE}_${role}.log" 2>&1) &
  echo "${MODULE}_${role} $!" >> "$PIDFILE"
  sleep 1
}

# Preference order - see header. Anything not listed here still gets
# started afterward (alphabetically), so a future module's unanticipated
# role isn't silently skipped.
PREFERRED_ORDER="tp cep rdb idb hdb fh gw housekeeping"
started=""
for role in $PREFERRED_ORDER; do
  config="$MODCFG/$role.json"
  if [ -f "$config" ]; then
    if [ "$role" = "rdb" ]; then
      # rdb is an active/standby pair, not a single process (see
      # core/rdb.q's header) - the same rdb.json launched twice,
      # -instance 1/2 picking -port1/-port2 apart; only instance 1
      # subscribes to the tickerplant at startup.
      start_proc "rdb_1" "$config" -instance 1
      start_proc "rdb_2" "$config" -instance 2
    else
      start_proc "$role" "$config"
    fi
    started="$started $role"
  fi
done
for config in "$MODCFG"/*.json; do
  [ -e "$config" ] || continue
  role="$(basename "$config" .json)"
  case " $started " in
    *" $role "*) continue ;;
  esac
  # eod is a one-shot batch job meant to be run deliberately, once you
  # know there's something checkpointed worth promoting - never auto-start
  # it here (running it against an empty module would publish an empty
  # partition for today, and a real eod run later the same day would then
  # collide with it - see core/eod.q's header).
  [ "$role" = "eod" ] && continue
  start_proc "$role" "$config"
  started="$started $role"
done

if [ -z "$started" ]; then
  echo "No *.json configs found under $MODCFG - nothing started." >&2
  rm -f "$PIDFILE"
  exit 1
fi

echo ""
echo "=== module '$MODULE' started ($(echo $started | wc -w) process(es)) ==="
echo "PIDs recorded in: $PIDFILE"
echo "Logs in: $LOGS/bymod_${MODULE}_<role>.log"
echo "To stop: ./scripts/shutdownAllByModule.sh $MODULE"
