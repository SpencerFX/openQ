# scripts/other/scheduleCandlePatternDaily.ps1
# Registers scripts/other/runCandlePatternDaily.ps1 as a Windows daily
# Scheduled Task ("openQ_candlePattern_daily"). Run once (idempotent -
# -Force replaces an existing registration rather than erroring) to set
# up the daily modules/analytics/candle/run.q batch; re-run it any time
# to change the trigger time below.
#
# 18:00 local (=09:00 UTC on this machine) is deliberately after BOTH
# daily EOD promotes the batch depends on being finished for "yesterday":
# mon's own housekeeping (00:00 UTC) and eq_m1_yfinance's (08:30 UTC) -
# see README's "Modules" section - so there's a real half-hour margin,
# not a tight race against either.
#
# To remove: Unregister-ScheduledTask -TaskName openQ_candlePattern_daily
# To check history: Get-ScheduledTaskInfo -TaskName openQ_candlePattern_daily
$ErrorActionPreference = "Stop"

$scriptPath = "C:\Users\giant\Downloads\Work\Git\openQ\scripts\other\runCandlePatternDaily.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At "18:00"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName "openQ_candlePattern_daily" `
  -Action $action -Trigger $trigger -Settings $settings `
  -Description "Daily modules/analytics/candle/run.q batch: scans yesterday's eq_m1_yfinance bars for candlestick patterns across 10 timeframes, tracked in mon's jobStatus table." `
  -Force

Get-ScheduledTask -TaskName "openQ_candlePattern_daily" | Select-Object TaskName, State
