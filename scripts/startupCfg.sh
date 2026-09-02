#!/bin/bash
# scripts/startupCfg.sh
# Same platform as scripts/startup.sh (tp/rdb/hdb/gw quartet, background q
# processes, existing data under DATA_DIR kept - safe to rerun), but each
# process is bootstrapped via core/initFromCfg.q + a JSON file under
# cfg_proc/ instead of init.q's long per-role CLI flag list - see
# core/initFromCfg.q's header comment for how that works. Every env-var
# override below is passed as an explicit CLI flag on top of -config, so
# it wins over the JSON's own value the same way any CLI flag would.
#
# Uses the same PID file as startup.sh (scripts/logs/openq.pids), so
# ./scripts/shutdown.sh stops a platform started either way - the two
# scripts are alternative bootstraps for the same platform, not meant to
# run at the same time (the running-already guard below covers that).
#
# Usage: ./scripts/startupCfg.sh
# Env overrides: TP_PORT RDB_PORT RDB2_PORT HDB_PORT GW_PORT DATA_DIR BMODE Q_BIN
# RDB_PORT/RDB2_PORT are rdb_1 (active)/rdb_2 (standby)'s ports - see
# core/rdb.q's header for the active/standby pair design.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
CFG="$ROOT/cfg_proc"
LOGS="$ROOT/scripts/logs"
DATA="${DATA_DIR:-$ROOT/examples/data}"
Q="${Q_BIN:-q}"

TP_PORT="${TP_PORT:-5010}"
RDB_PORT="${RDB_PORT:-5011}"
HDB_PORT="${HDB_PORT:-5012}"
GW_PORT="${GW_PORT:-5013}"
BMODE="${BMODE:-0}"

PIDFILE="$LOGS/openq.pids"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q ./scripts/startupCfg.sh" >&2
  exit 1
fi

if [ ! -d "$CFG" ]; then
  echo "cfg_proc/ not found at: $CFG" >&2
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 $(cut -d' ' -f2 "$PIDFILE" | head -1) 2>/dev/null; then
  echo "openQ already appears to be running (see $PIDFILE)." >&2
  echo "Stop it first with ./scripts/shutdown.sh before starting again." >&2
  exit 1
fi

mkdir -p "$LOGS" "$DATA/tplogs" "$DATA/hdb"
: > "$PIDFILE"

start_proc() {
  local label="$1" role="$2"; shift 2
  echo "=== starting $label (cfg_proc/$role.json) ==="
  (cd "$CORE" && exec "$Q" initFromCfg.q -config "$CFG/$role.json" "$@" > "$LOGS/$label.log" 2>&1) &
  echo "$label $!" >> "$PIDFILE"
  sleep 1
}

RDB2_PORT="${RDB2_PORT:-5100}"

# name/schema/utilities/libraries all come from each role's JSON; only the
# values that vary per environment (port, data paths, cross-process
# addresses) are passed here - each one overrides its JSON counterpart.
# rdb is now an active/standby pair (see core/rdb.q's header) - the same
# rdb.json launched twice, -instance 1/2 picking -port1/-port2 apart (see
# .util.start.resolveInstancePort) and only instance 1 subscribing to the
# tickerplant at startup.
start_proc tp    tp  -port "$TP_PORT"  -tplogdir "$DATA/tplogs" -bmode "$BMODE"
start_proc rdb_1 rdb -port1 "$RDB_PORT" -port2 "$RDB2_PORT" -instance 1 -tpaddr ":localhost:$TP_PORT" -hdbroot "$DATA/hdb"
start_proc rdb_2 rdb -port1 "$RDB_PORT" -port2 "$RDB2_PORT" -instance 2 -tpaddr ":localhost:$TP_PORT" -hdbroot "$DATA/hdb"
start_proc hdb   hdb -port "$HDB_PORT" -hdbroot "$DATA/hdb"
start_proc gw    gw  -port "$GW_PORT"  -rdbaddr ":localhost:$RDB_PORT" -hdbaddr ":localhost:$HDB_PORT"

echo ""
echo "=== openQ platform started (config-driven, via initFromCfg.q) ==="
echo "  tp    :localhost:$TP_PORT    (logs: $LOGS/tp.log)"
echo "  rdb_1 :localhost:$RDB_PORT   (logs: $LOGS/rdb_1.log) - ACTIVE (subscribed to tp)"
echo "  rdb_2 :localhost:$RDB2_PORT  (logs: $LOGS/rdb_2.log) - STANDBY (call .oq.rdb.activate[] to promote)"
echo "  hdb   :localhost:$HDB_PORT   (logs: $LOGS/hdb.log)"
echo "  gw    :localhost:$GW_PORT    (logs: $LOGS/gw.log)"
echo ""
echo "Publish ticks by connecting to the tp and calling \`upd, e.g.:"
echo "  neg[h] (\`upd;\`quote;data)"
echo "Query by connecting to the gw and calling .oq.gw.query, e.g.:"
echo "  neg[h] (\`.oq.gw.query;\`quote;\`;\`;\`;\`;\`); h[]"
echo ""
echo "To stop: ./scripts/shutdown.sh"
