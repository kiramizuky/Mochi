# Smoke-tests the relay the way Claude Code invokes it.
#
# The contract is simple and strict: with Coucou closed, every event exits 0 and
# prints nothing. A permission request must also return promptly instead of
# waiting for the full 110 s decision budget.
#
# Run from windows/ after `cargo build --release -p coucou-hook`. Close the
# island first: if Coucou is running, a SessionStart would legitimately reach it.

param(
  [string]$Hook = "target\release\coucou-hook.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Hook)) {
  throw "$Hook not found. Run: cargo build --release -p coucou-hook"
}
$hookPath = (Resolve-Path $Hook).Path

function Invoke-Hook {
  param([string]$EventName, [string]$Json)

  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $hookPath
  $info.Arguments = $EventName
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $process = [System.Diagnostics.Process]::Start($info)
  $process.StandardInput.Write($Json)
  $process.StandardInput.Close()

  if (-not $process.WaitForExit(5000)) {
    try { $process.Kill($true) } catch { }
    throw "$EventName did not exit within 5 s while Coucou is closed"
  }
  $watch.Stop()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()

  if ($process.ExitCode -ne 0) {
    throw "$EventName exited $($process.ExitCode). stderr: $stderr"
  }
  if ($stdout.Trim()) {
    throw "$EventName printed to stdout while Coucou is closed: $stdout"
  }
  return $watch.Elapsed.TotalMilliseconds
}

$events = @(
  "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
  "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SubagentStart",
  "SubagentStop"
)

foreach ($event in $events) {
  $json = '{"hook_event_name":"' + $event + '","session_id":"smoke","cwd":"C:\\"}'
  $ms = Invoke-Hook -EventName $event -Json $json
  if ($ms -gt 1500) { throw "$event took $([math]::Round($ms)) ms; it must not slow Claude Code down" }
}

# A permission request must notice there is no pipe and fall through immediately,
# not sit through the 110 s decision budget.
$permission = '{"hook_event_name":"PermissionRequest","session_id":"smoke","cwd":"C:\\","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
$ms = Invoke-Hook -EventName "PermissionRequest" -Json $permission
if ($ms -gt 3000) { throw "PermissionRequest took $([math]::Round($ms)) ms with Coucou closed" }

# Garbage on stdin must be ignored, not crash.
$info = [System.Diagnostics.ProcessStartInfo]::new()
$info.FileName = $hookPath
$info.Arguments = "SessionStart"
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($info)
$p.StandardInput.Write("{ not json")
$p.StandardInput.Close()
if (-not $p.WaitForExit(5000)) { $p.Kill($true); throw "hook hung on malformed JSON" }
if ($p.ExitCode -ne 0) { throw "malformed JSON exited $($p.ExitCode)" }
if ($p.StandardOutput.ReadToEnd().Trim()) { throw "malformed JSON printed output" }

Write-Host "coucou-hook.exe is safe with Coucou closed (12 events + malformed input)."
