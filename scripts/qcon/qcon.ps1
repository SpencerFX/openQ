# scripts/qcon/qcon.ps1
# PowerShell wrapper for scripts/qcon/qcon.q - connect an interactive q console to
# any configured openQ process by NAME (looked up from cfg_proc/**/*.json).
# Same idea as scripts/qcon/qcon.sh, for a PowerShell prompt instead of bash.
#
# Usage:
#   .\scripts\qcon\qcon.ps1 eq_m1_yfinance_rdb            # port1 (active)
#   .\scripts\qcon\qcon.ps1 eq_m1_yfinance_rdb.2           # port2 (standby)
#   .\scripts\qcon\qcon.ps1 eq_m1_yfinance_gw -host myhost.local
#   .\scripts\qcon\qcon.ps1 -list                          # print every known process name/type/port
# Env override: $env:Q_BIN (defaults to q.exe on PATH)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$qBin = if ($env:Q_BIN) { $env:Q_BIN } else { "q" }

$qCmd = Get-Command $qBin -ErrorAction SilentlyContinue
if (-not $qCmd) {
    Write-Host "q binary not found: $qBin (not on PATH, and not a valid path itself)"
    Write-Host 'Set $env:Q_BIN to your q executable, e.g. $env:Q_BIN = "C:\q\w64\q.exe"; .\scripts\qcon\qcon.ps1 <name>'
    exit 1
}

if ($args.Count -eq 0) {
    Write-Host "Usage: .\scripts\qcon\qcon.ps1 <processName> [-host <host>]   (or -list to see every known name)"
    exit 1
}

if ($args[0] -eq "-list") {
    & $qBin "$root\scripts\qcon\qcon.q" -list
    exit $LASTEXITCODE
}

$name = $args[0]
$rest = $args[1..($args.Count - 1)]

# no rlwrap-equivalent on Windows by default - q's own console already has
# usable line editing (arrow keys/history) here, unlike q on Linux, so this
# is fully usable without one; kept as a plain exec rather than trying to
# shell out to something that likely isn't installed.
& $qBin "$root\scripts\qcon\qcon.q" -name $name @rest
exit $LASTEXITCODE
