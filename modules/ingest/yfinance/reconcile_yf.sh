#!/usr/bin/env bash
# One-shot: rebuild TODAY's yfinance m1 partition(s) cleanly from Yahoo, to
# undo the idb double-write from the 2026-09-09 feeder restart (core/idb.q
# has no dedup). MUST run AFTER the live idb EOD promote so no in-flight
# bars are lost. load_yfinance.q per-(date,exchange) rewrite is idempotent.
#   ./reconcile_yf.sh eq   -> hkex + nikkei -> C:/data/db1/eq  <today>/eq_m1_yfinance
#   ./reconcile_yf.sh fx   -> fx            -> C:/data/db1/efx <today>/fx_m1_yfinance
set -u
cd "$(dirname "$0")"
PY=./.venv/Scripts/python.exe
Q="C:/q/w64/q.exe"
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p logs/reconcile
LOG="logs/reconcile/reconcile_${1:-none}_${TS}.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== reconcile_yf ${1:-} @ $(date -u) ==="

case "${1:-}" in
  eq) EXES="hkex nikkei"; DB="C:/data/db1/eq";  PORTS="5063 5090" ;;
  fx) EXES="fx";          DB="C:/data/db1/efx"; PORTS="5143 5093" ;;
  *)  echo "usage: $0 eq|fx"; exit 2 ;;
esac

rc=0
for ex in $EXES; do
  echo "--- backfill $ex (m1, 1d) $(date -u) ---"
  "$PY" py/backfill.py --exchange "$ex" --cadence m1 --days 1 || { echo "backfill $ex FAILED"; rc=1; break; }
  echo "--- to_kdb $ex -> $DB $(date -u) ---"
  "$PY" py/to_kdb.py --exchange "$ex" --cadence m1 --db "$DB" --q "C:/q/w64/q.exe" --qhome "C:/q" || { echo "to_kdb $ex FAILED"; rc=1; break; }
done

if [ "$rc" = 0 ]; then
  echo "--- reload HDBs $(date -u) ---"
  for p in $PORTS; do "C:/q/w64/q.exe" .reload_hdb.q "$p" || true; done
fi
echo "=== reconcile_yf ${1:-} finished rc=$rc @ $(date -u) ==="
exit $rc
