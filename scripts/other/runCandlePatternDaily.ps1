# scripts/other/runCandlePatternDaily.ps1
# Windows Task Scheduler's entry point for the daily candlePattern batch
# (modules/analytics/candle/run.q). Just sets the working directory to
# the repo root (run.q's own loads are repo-root-relative, same as every
# other modules/*/run.q or simulator.q script) and runs it with no -date,
# so it always covers "yesterday" - run.q's own default, and the same
# reasoning eq_m1_yfinance/mon's own housekeeping use for their daily
# EOD promotes. Tracked via jobStatus (modules/mon/jobStatus.q) - see
# run.q's own header for how; nothing scheduling-specific to track here.
#
# Registered by scripts/other/scheduleCandlePatternDaily.ps1; run this
# file directly to test the exact command Task Scheduler will run.
$ErrorActionPreference = "Stop"
$repoRoot = "C:\Users\giant\Downloads\Work\Git\openQ"
$qBin = "C:\q\w64\q.exe"
Set-Location $repoRoot
& $qBin "$repoRoot\modules\analytics\candle\run.q" -q
exit $LASTEXITCODE
