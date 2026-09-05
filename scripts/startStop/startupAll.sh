#!/bin/bash
# scripts/startStop/startupAll.sh
# Starts every pipeline in this repo at once - the default pipeline plus
# every module under cfg_proc/modules/ - each process via initFromCfg.q
# and its cfg_proc/*.json, in each pipeline's documented start order
# (massive is the one with an order that matters: fh -> tp -> cep -> rdb
# -> idb -> hdb - see the README's "Modules" section).
#
# No synthetic data flows on its own here - every tp's "genFreq" is blank
# by default (see core/config.q), so modules/utils/generator/generator.q's
# self-publish timer never activates even though every tp already loads
# it as a library. For that, use scripts/startStop/startupAllWithGen.sh instead,
# which starts the exact same set of processes but passes each tp a
# non-blank -genFreq, turning that self-publish timer on.
#
# This is a separate, parallel mechanism from scripts/startStop/startup.sh/
# shutdown.sh (which only manage the plain default pipeline via init.q,
# not initFromCfg.q, and track their own PIDs in openq.pids) - this
# script's PIDs are tracked in openq-all.pids instead, and
# shutdownAll.sh is its matching stop script. Don't mix the two pidfiles/
# scripts for the same running processes.
#
# Usage: ./scripts/startStop/startupAll.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
CFG="$ROOT/cfg_proc"
LOGS="$ROOT/scripts/logs"
DATA="$ROOT/examples/data"
Q="${Q_BIN:-q}"
PIDFILE="$LOGS/openq-all.pids"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q ./scripts/startStop/startupAll.sh" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "openQ (all pipelines) already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/startStop/shutdownAll.sh before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS" \
  "$DATA/tplogs" "$DATA/hdb" "$DATA/idb_staging" \
  "$DATA/mon/tplogs" "$DATA/mon/hdb" "$DATA/mon/idb_staging" \
  "$DATA/markout/tplogs" "$DATA/markout/hdb" "$DATA/markout/idb_staging" \
  "$DATA/massive/tplogs" "$DATA/massive/hdb" "$DATA/massive/idb_staging" \
  "$DATA/spread/tplogs" "$DATA/spread/hdb" "$DATA/spread/idb_staging"
: > "$PIDFILE"

start_proc() {
  local label="$1" config="$2"; shift 2
  echo "=== starting $label ($config) ==="
  (cd "$CORE" && exec "$Q" initFromCfg.q -config "$CFG/$config" "$@" > "$LOGS/all_${label}.log" 2>&1) &
  echo "$label $!" >> "$PIDFILE"
  sleep 1
}

# rdb is an active/standby pair, not a single process (see core/rdb.q's
# header) - the same rdb.json launched twice, -instance 1/2 picking
# port1/port2 apart; only instance 1 subscribes to the tickerplant at
# startup. start_proc_rdb wraps the pair so every pipeline below states
# it once instead of twice.
start_proc_rdb() {
  local label="$1" config="$2"
  start_proc "${label}_1" "$config" -instance 1
  start_proc "${label}_2" "$config" -instance 2
}

echo "########## default pipeline ##########"
start_proc default_tp    tp.json
start_proc_rdb default_rdb rdb.json
start_proc default_cep   cep.json
start_proc default_idb   idb.json
start_proc default_hdb   hdb.json
start_proc default_gw    gw.json

echo "########## mon ##########"
start_proc mon_tp          modules/mon/tp.json
start_proc_rdb mon_rdb     modules/mon/rdb.json
start_proc mon_idb        modules/mon/idb.json
start_proc mon_hdb         modules/mon/hdb.json
start_proc mon_cep         modules/mon/cep.json

echo "########## markout ##########"
start_proc markout_tp          modules/markout/tp.json
start_proc_rdb markout_rdb modules/markout/rdb.json
start_proc markout_idb        modules/markout/idb.json
start_proc markout_hdb         modules/markout/hdb.json
start_proc markout_cep         modules/markout/cep.json

echo "########## massive (fh -> tp -> cep -> rdb -> idb -> hdb) ##########"
start_proc massive_tp          modules/massive/tp.json
start_proc massive_cep         modules/massive/cep.json
start_proc_rdb massive_rdb modules/massive/rdb.json
start_proc massive_idb        modules/massive/idb.json
start_proc massive_hdb         modules/massive/hdb.json
start_proc massive_fh          modules/massive/fh.json

echo "########## spread ##########"
start_proc spread_tp          modules/spread/tp.json
start_proc_rdb spread_rdb modules/spread/rdb.json
start_proc spread_idb        modules/spread/idb.json
start_proc spread_hdb         modules/spread/hdb.json
start_proc spread_cep         modules/spread/cep.json

echo ""
echo "=== all pipelines started (37 processes - each of the 6 rdb pipelines above is now an active/standby pair, and idbWriter1/idbWriter2 are now a single idb - see core/idb.q's header) ==="
echo "PIDs recorded in: $PIDFILE"
echo "Logs in: $LOGS/all_<label>.log"
echo "To stop everything: ./scripts/startStop/shutdownAll.sh"
