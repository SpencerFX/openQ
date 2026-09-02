#!/bin/bash
# scripts/startupAllWithGen.sh
# Same as scripts/startupAll.sh - starts every pipeline in this repo at
# once (default pipeline + every module under cfg_proc/modules/), each
# process via initFromCfg.q, in each pipeline's documented start order -
# except every tp is also given a non-blank -genFreq on its command line.
# initFromCfg.q's JSON merge only fills in a param the CLI didn't already
# supply (see initFromCfg.q's own header), so this -genFreq always wins
# over each tp.json's own blank default and turns on
# modules/utils/generator/generator.q's self-publish timer - already loaded as
# a library by every tp.json, just inactive until genFreq is non-blank.
# Nothing else changes: same JSON configs, same ports, same PIDFILE shape
# as startupAll.sh (a separate one, so the two don't collide - see below).
#
# The result: within a couple of seconds of each pipeline coming up,
# real-looking (type-correct, not semantically real) random data is
# already flowing through every tp/rdb/idb/hdb/cep on its own - nothing
# else needs to be started (no Python feed handlers, no real vendor
# connections) to see every pipeline actually moving data end to end.
#
# This is a separate, parallel mechanism from scripts/startup.sh/
# shutdown.sh (which only manage the plain default pipeline via init.q,
# not initFromCfg.q, and track their own PIDs in openq.pids) and from
# scripts/startupAll.sh/shutdownAll.sh (same process set, generator off
# by default, tracked in openq-all.pids) - this script's PIDs are tracked
# in openq-all-gen.pids instead, with its own matching
# shutdownAllWithGen.sh. Don't mix pidfiles/scripts for the same running
# processes, and don't run this alongside startupAll.sh/startup.sh at the
# same time - they claim the same ports.
#
# Usage: ./scripts/startupAllWithGen.sh
# Env override: GEN_FREQ (default 0D00:00:02)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
CFG="$ROOT/cfg_proc"
LOGS="$ROOT/scripts/logs"
DATA="$ROOT/examples/data"
Q="${Q_BIN:-q}"
PIDFILE="$LOGS/openq-all-gen.pids"
GEN_FREQ="${GEN_FREQ:-0D00:00:02}"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q ./scripts/startupAllWithGen.sh" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "openQ (all pipelines, with generator) already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/shutdownAllWithGen.sh before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS" \
  "$DATA/tplogs" "$DATA/hdb" "$DATA/idb_staging" \
  "$DATA/mon/tplogs" "$DATA/mon/hdb" "$DATA/mon/idb_staging" \
  "$DATA/markout/tplogs" "$DATA/markout/hdb" "$DATA/markout/idb_staging" \
  "$DATA/massive/tplogs" "$DATA/massive/hdb" "$DATA/massive/idb_staging" \
  "$DATA/spread/tplogs" "$DATA/spread/hdb" "$DATA/spread/idb_staging"
: > "$PIDFILE"

# $3 (optional) is "gen" for a tp - appends -genFreq so the JSON's own
# blank default gets overridden; every other role is started exactly like
# startupAll.sh does, untouched.
start_proc() {
  local label="$1" config="$2" role="${3:-}"; shift $(( $# < 3 ? 2 : 3 ))
  local extraArgs=("$@")
  [ "$role" = "gen" ] && extraArgs+=(-genFreq "$GEN_FREQ")
  echo "=== starting $label ($config)${role:+ [genFreq=$GEN_FREQ]} ==="
  (cd "$CORE" && exec "$Q" initFromCfg.q -config "$CFG/$config" "${extraArgs[@]}" > "$LOGS/allgen_${label}.log" 2>&1) &
  echo "$label $!" >> "$PIDFILE"
  sleep 1
}

# rdb is an active/standby pair, not a single process (see core/rdb.q's
# header) - same rdb.json launched twice, -instance 1/2 picking
# port1/port2 apart; only instance 1 subscribes to the tickerplant.
start_proc_rdb() {
  local label="$1" config="$2"
  start_proc "${label}_1" "$config" "" -instance 1
  start_proc "${label}_2" "$config" "" -instance 2
}

echo "########## default pipeline ##########"
start_proc default_tp    tp.json gen
start_proc_rdb default_rdb rdb.json
start_proc default_cep   cep.json
start_proc default_idb   idb.json
start_proc default_hdb   hdb.json
start_proc default_gw    gw.json

echo "########## mon ##########"
start_proc mon_tp          modules/mon/tp.json gen
start_proc_rdb mon_rdb     modules/mon/rdb.json
start_proc mon_idb        modules/mon/idb.json
start_proc mon_hdb         modules/mon/hdb.json
start_proc mon_cep         modules/mon/cep.json

echo "########## markout ##########"
start_proc markout_tp          modules/markout/tp.json gen
start_proc_rdb markout_rdb modules/markout/rdb.json
start_proc markout_idb        modules/markout/idb.json
start_proc markout_hdb         modules/markout/hdb.json
start_proc markout_cep         modules/markout/cep.json

echo "########## massive (fh -> tp -> cep -> rdb -> idb -> hdb) ##########"
start_proc massive_tp          modules/massive/tp.json gen
start_proc massive_cep         modules/massive/cep.json
start_proc_rdb massive_rdb modules/massive/rdb.json
start_proc massive_idb        modules/massive/idb.json
start_proc massive_hdb         modules/massive/hdb.json
start_proc massive_fh          modules/massive/fh.json

echo "########## spread ##########"
start_proc spread_tp          modules/spread/tp.json gen
start_proc_rdb spread_rdb modules/spread/rdb.json
start_proc spread_idb        modules/spread/idb.json
start_proc spread_hdb         modules/spread/hdb.json
start_proc spread_cep  modules/spread/cep.json

echo ""
echo "=== all pipelines started (37 processes - each of the 6 rdb pipelines above is now an active/standby pair, and idbWriter1/idbWriter2 are now a single idb), generator enabled on every tp ==="
echo "PIDs recorded in: $PIDFILE"
echo "Logs in: $LOGS/allgen_<label>.log"
echo "To stop everything: ./scripts/shutdownAllWithGen.sh"
