# Runtime smoke test: boots the real app, then checks the island window, its
# panel/wake-strip geometry on the real monitor, the island's JavaScript/IPC
# bridge, the settings window, the Settings frontend (including the first-run
# Welcome card), the tray icon, the staged relay, a full permission round-trip
# and a Unicode file drop.
#
# The app performs the checks itself (COUCOU_SMOKE_TEST=1) and writes a JSON
# report; this script owns the timeout and makes the result readable in CI.
# It runs with a temporary %APPDATA% so first-launch UI is tested and no user
# setting or Claude Code hook is modified. Nothing is installed.
#
# Run from windows/ after: cargo build --release -p coucou --features custom-protocol
# (npm run build first builds the release relay). A CI runner and a normal
# desktop both work; close Coucou first.

param(
  [string]$App = "target\release\coucou.exe",
  [int]$TimeoutSec = 90,
  [switch]$KeepReport
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 defaults to the OEM code page; the file-drop check uses
# a Unicode name and its report is JSON, so print it as UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path $App)) {
  throw "$App not found. Run: npm run build; cargo build --release -p coucou --features custom-protocol"
}
$appPath = (Resolve-Path $App).Path

$running = Get-Process -Name coucou -ErrorAction SilentlyContinue
if ($running) {
  throw "Coucou is already running (PID $($running.Id -join ', ')). Close it before the smoke test."
}

$reportPath = Join-Path ([System.IO.Path]::GetTempPath()) "coucou-smoke-$PID.json"
Remove-Item $reportPath -ErrorAction SilentlyContinue

# A clean %APPDATA% gives the smoke run a first-launch profile: the Welcome card
# must render without depending on (or writing to) the developer's settings.
$smokeAppData = Join-Path ([System.IO.Path]::GetTempPath()) "coucou-smoke-appdata-$PID"
Remove-Item -Recurse -Force $smokeAppData -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $smokeAppData -Force | Out-Null

$info = [System.Diagnostics.ProcessStartInfo]::new()
$info.FileName = $appPath
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.CreateNoWindow = $true
$info.EnvironmentVariables["COUCOU_SMOKE_TEST"] = "1"
$info.EnvironmentVariables["COUCOU_SMOKE_REPORT"] = $reportPath
$info.EnvironmentVariables["APPDATA"] = $smokeAppData

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$process = [System.Diagnostics.Process]::Start($info)

# Drain both pipes so a chatty build can never fill a buffer and deadlock.
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()

if (-not $process.WaitForExit($TimeoutSec * 1000)) {
  try { $process.Kill($true) } catch { }
  $process.WaitForExit(5000) | Out-Null
  Write-Host (Get-Content (Join-Path $env:LOCALAPPDATA "Coucou\coucou.log") -Tail 25 -ErrorAction SilentlyContinue)
  throw "Coucou did not finish the smoke test within $TimeoutSec s"
}
$watch.Stop()
$exitCode = $process.ExitCode
$stdout = $stdoutTask.Result.Trim()
$stderr = $stderrTask.Result.Trim()

if (-not (Test-Path $reportPath)) {
  if ($stdout) { Write-Host $stdout }
  if ($stderr) { Write-Host $stderr }
  Write-Host (Get-Content (Join-Path $env:LOCALAPPDATA "Coucou\coucou.log") -Tail 25 -ErrorAction SilentlyContinue)
  throw "Coucou exited $exitCode without writing a smoke report"
}

$report = Get-Content $reportPath -Raw | ConvertFrom-Json

Write-Host "Coucou $($report.version) smoke test - $([math]::Round($report.duration_ms)) ms"
foreach ($check in $report.checks) {
  $mark = if ($check.ok) { "ok  " } else { "FAIL" }
  Write-Host ("  {0} {1,-18} {2}" -f $mark, $check.name, $check.detail)
}

$failed = @($report.checks | Where-Object { -not $_.ok })
if ($exitCode -ne 0 -or -not $report.ok -or $failed.Count -gt 0) {
  if ($stdout) { Write-Host "stdout: $stdout" }
  if ($stderr) { Write-Host "stderr: $stderr" }
  Write-Host (Get-Content (Join-Path $env:LOCALAPPDATA "Coucou\coucou.log") -Tail 40 -ErrorAction SilentlyContinue)
  throw ("Coucou app smoke test failed ({0} checks)" -f $failed.Count)
}

if ($KeepReport) {
  Write-Host "Report kept at $reportPath"
} else {
  Remove-Item $reportPath -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force $smokeAppData -ErrorAction SilentlyContinue

Write-Host ("Coucou app smoke test passed ({0} checks, {1} s)." -f @($report.checks).Count, [math]::Round($watch.Elapsed.TotalSeconds, 1))
