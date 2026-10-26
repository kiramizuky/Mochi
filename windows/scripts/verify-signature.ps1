# Verifies Authenticode signatures the way a Windows release should be checked:
# signtool /pa /all (including the chain) plus a timestamp check.
#
#   ./verify-signature.ps1 -Files release/Coucou-Windows-0.1.1-setup.exe -RequireTimestamp
#
# The release workflow runs this on coucou.exe, coucou-hook.exe and the installer
# before uploading anything. UAT runs it on the installed binaries.

param(
  [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Files,
  [string]$TimestampUrl,
  [switch]$RequireTimestamp
)

$ErrorActionPreference = "Stop"

function Find-SignTool {
  if ($env:COUCOU_SIGNTOOL -and (Test-Path $env:COUCOU_SIGNTOOL)) {
    return (Resolve-Path $env:COUCOU_SIGNTOOL).Path
  }
  $fromPath = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($fromPath) { return $fromPath.Source }

  $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (Test-Path $kits) {
    $candidates = @(Get-ChildItem $kits -Directory |
      Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
      Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
  }
  throw "signtool.exe not found. Install the Windows SDK or set COUCOU_SIGNTOOL."
}

$signtool = Find-SignTool
$failures = @()

foreach ($file in $Files) {
  if (-not (Test-Path $file)) { throw "File to verify not found: $file" }
  $full = (Resolve-Path $file).Path
  $signature = Get-AuthenticodeSignature $full

  if (-not $signature.SignerCertificate) {
    $failures += "$full is not signed"
    Write-Host "UNSIGNED $full"
    continue
  }

  $verifyArgs = @("verify", "/pa", "/all", "/v")
  if ($TimestampUrl) { $verifyArgs += @("/tw", $TimestampUrl) }
  $output = & $signtool @verifyArgs $full 2>&1
  $verifyExit = $LASTEXITCODE
  $text = ($output | Out-String)

  $timestamped = -not ($text -match "(not timestamped|no timestamp)")
  if ($signature.TimeStamperCertificate) { $timestamped = $true }

  if ($verifyExit -ne 0) {
    $failures += "$full failed signtool verify (exit $verifyExit)"
    Write-Host "INVALID $full"
    Write-Host $text
    continue
  }
  if ($signature.Status -ne "Valid") {
    $failures += "$full has an untrusted chain (status: $($signature.Status))"
    Write-Host "UNTRUSTED $full ($($signature.Status))"
    continue
  }
  if ($RequireTimestamp -and -not $timestamped) {
    $failures += "$full is not timestamped"
    Write-Host "NO TIMESTAMP $full"
    continue
  }

  Write-Host ("OK {0} - {1}" -f $full, $signature.SignerCertificate.Subject)
}

if ($failures.Count -gt 0) {
  throw ("Signature verification failed:`n  " + ($failures -join "`n  "))
}

Write-Host ("Verified {0} file(s)." -f @($Files).Count)
