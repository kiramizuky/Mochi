# Signs Windows files with signtool and a real Authenticode certificate.
#
# The certificate is never read from the repository. Configure one of:
#   COUCOU_SIGN_PFX            path to a .pfx (with COUCOU_SIGN_PFX_PASSWORD)
#   COUCOU_SIGN_THUMBPRINT     thumbprint of a certificate in Cert:\CurrentUser\My
#   COUCOU_SIGNTOOL            explicit path to signtool.exe (optional)
#   COUCOU_TIMESTAMP_URL       RFC 3161 timestamp server (optional)
#
# Local unsigned builds must keep working, so the script exits 0 with a warning
# when no certificate is configured. Release jobs pass -RequireSignature, which
# turns that warning into an error before anything reaches users.
#
# The password is passed to signtool with /p and is therefore briefly visible to
# processes on the same machine. CI avoids that by importing the pfx into the
# user store once and signing with COUCOU_SIGN_THUMBPRINT instead.

param(
  [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Files,
  [string]$PfxPath = $env:COUCOU_SIGN_PFX,
  [string]$PfxPassword = $env:COUCOU_SIGN_PFX_PASSWORD,
  [string]$Thumbprint = $env:COUCOU_SIGN_THUMBPRINT,
  [string]$TimestampUrl = $env:COUCOU_TIMESTAMP_URL,
  [switch]$RequireSignature,
  [switch]$NoTimestamp
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

$hasThumbprint = -not [string]::IsNullOrWhiteSpace($Thumbprint)
$hasPfx = -not [string]::IsNullOrWhiteSpace($PfxPath)

if (-not $hasThumbprint -and -not $hasPfx) {
  if ($RequireSignature) {
    throw "No Authenticode certificate configured (COUCOU_SIGN_THUMBPRINT or COUCOU_SIGN_PFX)."
  }
  Write-Warning "No code-signing certificate configured; leaving files unsigned."
  exit 0
}
if (-not $hasThumbprint -and -not (Test-Path $PfxPath)) {
  throw "COUCOU_SIGN_PFX points to a missing file: $PfxPath"
}
if ($hasPfx -and -not $hasThumbprint -and [string]::IsNullOrEmpty($PfxPassword)) {
  throw "COUCOU_SIGN_PFX_PASSWORD is required when signing with a pfx."
}
if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
  $TimestampUrl = "http://timestamp.digicert.com"
}

$signtool = Find-SignTool
$arguments = @("sign", "/fd", "SHA256")
if ($hasThumbprint) {
  $arguments += @("/sha1", $Thumbprint)
} else {
  $arguments += @("/f", $PfxPath, "/p", $PfxPassword)
}
if (-not $NoTimestamp) {
  $arguments += @("/tr", $TimestampUrl, "/td", "SHA256")
}

foreach ($file in $Files) {
  if (-not (Test-Path $file)) { throw "File to sign not found: $file" }
  $full = (Resolve-Path $file).Path
  Write-Host "Signing $full"
  & $signtool @arguments $full
  if ($LASTEXITCODE -ne 0) {
    throw "signtool failed for $full (exit $LASTEXITCODE)"
  }
  $signature = Get-AuthenticodeSignature $full
  if (-not $signature.SignerCertificate) {
    throw "No signer certificate on $full after signing"
  }
  Write-Host ("  signed by {0} ({1})" -f $signature.SignerCertificate.Subject, $signature.SignerCertificate.Thumbprint)
}

Write-Host ("Signed {0} file(s)." -f @($Files).Count)
