#!/bin/bash
# tests/sh/run_idb_test.sh
# Acceptance test for idb.q: starts a TP, an RDB, and an idb writer
# (independently subscribed to the TP, checkpointing on a short timer).
# Verifies: (1) a checkpoint writes today's data to the idb staging root
# and tells the RDB to flush what's now durable, (2) a second checkpoint
# APPENDS rather than overwriting, (3) EOD promotion combines everything
# checkpointed into a properly sorted/attributed partition under the real
# HDB root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/core"
TESTS="$ROOT/tests"
LOGS="$TESTS/logs"
DATA="$ROOT/examples/data"
Q=/c/q/w64/q.exe

pass=0
fail=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "PASS: $2"; pass=$((pass+1))
  else
    echo "FAIL: $2"; fail=$((fail+1))
  fi
}

cleanup() { taskkill //F //IM q.exe > /dev/null 2>&1; }
trap cleanup EXIT

echo "=== resetting example data ==="
rm -rf "$DATA/tplogs_idb" "$DATA/idb_staging" "$DATA/hdb_idb"
mkdir -p "$DATA/tplogs_idb" "$LOGS"

cleanup
sleep 1

cd "$CORE"
echo "=== starting tp ==="
"$Q" init.q -procType tp -name tp0 -port 5010 -tplogdir "$DATA/tplogs_idb" -bmode 0 > "$LOGS/id_tp.log" 2>&1 &
sleep 1
echo "=== starting rdb ==="
"$Q" init.q -procType rdb -name rdb0 -port 5011 -tpaddr :localhost:5010 -hdbroot "$DATA/hdb_idb" > "$LOGS/id_rdb.log" 2>&1 &
sleep 1
echo "=== starting idb writer (2s checkpoint interval) ==="
"$Q" init.q -procType idb -name idb0 -port 5015 -tpaddr :localhost:5010 -rdbaddr :localhost:5011 \
  -idbroot "$DATA/idb_staging" -hdbroot "$DATA/hdb_idb" -checkpointfreq 0D00:00:02 > "$LOGS/id_idb.log" 2>&1 &
sleep 2

echo "=== publishing first batch ==="
"$Q" "$TESTS/q/publish.q" -q < /dev/null
sleep 4

echo "=== checking first checkpoint landed on disk and RDB was flushed ==="
diskCount1=$("$Q" -q < /dev/null 2>&1 <<'EOF'
system "l ../examples/data/idb_staging";
show count quote;
exit 0
EOF
)
echo "on-disk quote rows after checkpoint 1: $diskCount1"
echo "$diskCount1" | grep -qx "20"
check $? "first checkpoint wrote 20 quote rows to idb staging"

rdbCount1=$("$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5011";
show h "count quote";
hclose h;
exit 0
EOF
)
echo "RDB quote row count after checkpoint 1: $rdbCount1"
echo "$rdbCount1" | grep -qx "0"
check $? "RDB was flushed after the first checkpoint notified it"

echo "=== publishing second batch ==="
"$Q" "$TESTS/q/publish.q" -q < /dev/null
sleep 4

echo "=== checking second checkpoint appended (not overwrote) ==="
diskCount2=$("$Q" -q < /dev/null 2>&1 <<'EOF'
system "l ../examples/data/idb_staging";
show count quote;
exit 0
EOF
)
echo "on-disk quote rows after checkpoint 2: $diskCount2"
echo "$diskCount2" | grep -qx "40"
check $? "second checkpoint appended, giving 40 total quote rows on disk"

echo "=== triggering EOD promotion ==="
eodOut=$("$Q" -q < /dev/null 2>&1 <<'EOF'
h:hopen `$":localhost:5015";
show h (`.oq.idb.eod;.z.d);
hclose h;
exit 0
EOF
)
echo "$eodOut"

echo "=== checking promoted HDB partition ==="
hdbOut=$("$Q" -q < /dev/null 2>&1 <<'EOF'
system "l ../examples/data/hdb_idb";
-1 "row count: ",string count quote;
-1 "sym attr: ",string attr (select sym from quote)`sym;
exit 0
EOF
)
echo "$hdbOut"
echo "$hdbOut" | grep -q "row count: 40"
check $? "EOD-promoted HDB partition has all 40 quote rows"
echo "$hdbOut" | grep -q "sym attr: p"
check $? "promoted sym column carries the parted attribute"

echo ""
echo "=== logs (tail) ==="
for f in id_tp id_rdb id_idb; do
  echo "--- $f.log ---"
  tail -10 "$LOGS/$f.log"
done

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit $fail
