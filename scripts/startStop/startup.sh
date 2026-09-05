#!/bin/bash
# scripts/startStop/startup.sh
# Starts the whole openQ/core platform: tickerplant, RDB, HDB, gateway,
# CEP, and idb writer, each as a background q process. Existing data
# under DATA_DIR is kept (not wiped) so this is safe to use for normal
# day-to-day startup, not just for tests - see tests/sh/run_pipeline_test.sh
# for a from-scratch, self-verifying run.
#
# CEP and idb are started by default alongside the core tp/rdb/hdb/gw
# quartet; set WITH_CEP=0 / WITH_IDB=0 to skip either one.
#
# Usage: ./scripts/startStop/startup.sh
# Env overrides: TP_PORT RDB_PORT RDB2_PORT HDB_PORT GW_PORT CEP_PORT IDB_PORT
#                DATA_DIR BMODE Q_BIN WITH_CEP WITH_IDB CEPSCRIPT
#                CHECKPOINTFREQ
# RDB_PORT/RDB2_PORT are rdb_1 (starts ACTIVE)/rdb_2 (starts STANDBY)'s
# ports - see core/rdb.q's header for the active/standby pair design.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
LOGS="$ROOT/scripts/logs"
DATA="${DATA_DIR:-$ROOT/examples/data}"
Q="${Q_BIN:-q}"

TP_PORT="${TP_PORT:-5010}"
RDB_PORT="${RDB_PORT:-5011}"
RDB2_PORT="${RDB2_PORT:-5100}"
HDB_PORT="${HDB_PORT:-5012}"
GW_PORT="${GW_PORT:-5013}"
CEP_PORT="${CEP_PORT:-5014}"
IDB_PORT="${IDB_PORT:-5015}"
BMODE="${BMODE:-0}"

WITH_CEP="${WITH_CEP:-1}"
WITH_IDB="${WITH_IDB:-1}"
CEPSCRIPT="${CEPSCRIPT:-}"
CHECKPOINTFREQ="${CHECKPOINTFREQ:-0D00:02:00}"

PIDFILE="$LOGS/openq.pids"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q ./scripts/startStop/startup.sh" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "openQ already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/startStop/shutdown.sh before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS" "$DATA/tplogs" "$DATA/hdb" "$DATA/idb_staging"
: > "$PIDFILE"

start_proc() {
  local role="$1" name="$2" port="$3"; shift 3
  echo "=== starting $role ($name) on port $port ==="
  (cd "$CORE" && exec "$Q" init.q -procType "$role" -name "$name" -port "$port" "$@" > "$LOGS/$role.log" 2>&1) &
  echo "$role $!" >> "$PIDFILE"
  sleep 1
}

# rdb is an active/standby pair (see core/rdb.q's header) rather than a
# single -port process - -name is the shared BASE name here (init.q's
# .util.start.resolveInstancePort appends "_1"/"_2" itself, same as the
# JSON-config path does), so this doesn't go through the single-port
# start_proc helper above.
start_proc_rdb() {
  local label="$1" instance="$2"; shift 2
  echo "=== starting $label (rdb, instance $instance) ==="
  (cd "$CORE" && exec "$Q" init.q -procType rdb -name rdb0 \
     -port1 "$RDB_PORT" -port2 "$RDB2_PORT" -instance "$instance" "$@" > "$LOGS/$label.log" 2>&1) &
  echo "$label $!" >> "$PIDFILE"
  sleep 1
}

start_proc tp  tp0  "$TP_PORT"  -tplogdir "$DATA/tplogs" -bmode "$BMODE"
start_proc_rdb rdb_1 1 -tpaddr ":localhost:$TP_PORT" -hdbroot "$DATA/hdb"
start_proc_rdb rdb_2 2 -tpaddr ":localhost:$TP_PORT" -hdbroot "$DATA/hdb"
start_proc hdb hdb0 "$HDB_PORT" -hdbroot "$DATA/hdb"
start_proc gw  gw0  "$GW_PORT"  -rdbaddr ":localhost:$RDB_PORT" -hdbaddr ":localhost:$HDB_PORT"

if [ "$WITH_CEP" = "1" ]; then
  cepArgs=(-srcaddr ":localhost:$TP_PORT")
  [ -n "$CEPSCRIPT" ] && cepArgs+=(-cepscript "$CEPSCRIPT")
  start_proc cep cep0 "$CEP_PORT" "${cepArgs[@]}"
fi

if [ "$WITH_IDB" = "1" ]; then
  start_proc idb idb0 "$IDB_PORT" \
    -tpaddr ":localhost:$TP_PORT" -rdbaddr ":localhost:$RDB_PORT" -rdbaddr2 ":localhost:$RDB2_PORT" \
    -idbroot "$DATA/idb_staging" -hdbroot "$DATA/hdb" \
    -checkpointfreq "$CHECKPOINTFREQ"
fi

echo ""
echo "=== openQ platform started ==="
echo "  tp    :localhost:$TP_PORT    (logs: $LOGS/tp.log)"
echo "  rdb_1 :localhost:$RDB_PORT   (logs: $LOGS/rdb_1.log) - ACTIVE (subscribed to tp)"
echo "  rdb_2 :localhost:$RDB2_PORT  (logs: $LOGS/rdb_2.log) - STANDBY (call .oq.rdb.activate[] to promote)"
echo "  hdb   :localhost:$HDB_PORT   (logs: $LOGS/hdb.log)"
echo "  gw    :localhost:$GW_PORT    (logs: $LOGS/gw.log)"
[ "$WITH_CEP" = "1" ] && echo "  cep :localhost:$CEP_PORT  (logs: $LOGS/cep.log)$([ -z "$CEPSCRIPT" ] && echo "  [no -cepscript given - idle, no handlers registered]")"
[ "$WITH_IDB" = "1" ] && echo "  idb :localhost:$IDB_PORT  (logs: $LOGS/idb.log)"
echo ""
echo "Publish ticks by connecting to the tp and calling \`upd, e.g.:"
echo "  neg[h] (\`upd;\`quote;data)"
echo "Query by connecting to the gw and calling .oq.gw.query, e.g.:"
echo "  neg[h] (\`.oq.gw.query;\`quote;\`;\`;\`;\`;\`); h[]"
echo ""
echo "To stop: ./scripts/startStop/shutdown.sh"
