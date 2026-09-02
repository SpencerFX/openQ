#!/bin/bash
# scripts/qcon.sh
# Wrapper for scripts/qcon.q - connect an interactive q console to any
# configured openQ process by NAME (looked up from cfg_proc/**/*.json).
#
# Usage:
#   ./scripts/qcon.sh eq_m1_yfinance_rdb            # port1 (active)
#   ./scripts/qcon.sh eq_m1_yfinance_rdb.2           # port2 (standby)
#   ./scripts/qcon.sh eq_m1_yfinance_gw -host myhost.local
#   ./scripts/qcon.sh -list                          # print every known process name/type/port
# Env override: Q_BIN (defaults to `q` on PATH)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
Q="${Q_BIN:-q}"

if ! command -v "$Q" > /dev/null 2>&1; then
  echo "q binary not found: $Q (not on PATH, and not a valid path itself)" >&2
  echo "Set Q_BIN to your q executable, e.g. Q_BIN=/path/to/q ./scripts/qcon.sh <name>" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: ./scripts/qcon.sh <processName> [-host <host>]   (or -list to see every known name)" >&2
  exit 1
fi

if [ "$1" = "-list" ]; then
  exec "$Q" "$ROOT/scripts/qcon.q" -list
fi

NAME="$1"; shift
if command -v rlwrap > /dev/null 2>&1; then
  exec rlwrap "$Q" "$ROOT/scripts/qcon.q" -name "$NAME" "$@"
else
  # no rlwrap - still fully usable (q's own console has basic line editing,
  # especially on Windows), just without cross-session history
  exec "$Q" "$ROOT/scripts/qcon.q" -name "$NAME" "$@"
fi
