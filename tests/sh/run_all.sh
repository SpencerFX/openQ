#!/bin/bash
# tests/sh/run_all.sh
# Runs every run_*_test.sh in this directory, one after another, capturing
# each suite's full output and exit code under tests/logs/results/ for the
# dashboard's Tests page (the gateway parses PASS:/FAIL: lines out of the
# .out files). Each individual suite already tears its own q processes down
# on exit (some via `taskkill //F //IM q.exe`), so running this WILL stop a
# running openQ platform - restart it afterwards.
#
# Usage: bash tests/sh/run_all.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../logs/results"
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-420}"

rm -rf "$OUT"
mkdir -p "$OUT"
: > "$OUT/manifest.txt"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$OUT/startedAt"

for script in "$HERE"/run_*_test.sh; do
  name="$(basename "$script" .sh)"
  name="${name#run_}"
  name="${name%_test}"
  echo ">>> $name"
  start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  s_epoch=$(date +%s)
  timeout "$PER_SUITE_TIMEOUT" bash "$script" > "$OUT/$name.out" 2>&1
  code=$?
  e_epoch=$(date +%s)
  end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$name|$code|$start|$end|$((e_epoch - s_epoch))" >> "$OUT/manifest.txt"
  echo "    exit $code  ($((e_epoch - s_epoch))s)"
done

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$OUT/finishedAt"
echo "=== done - results under $OUT ==="
