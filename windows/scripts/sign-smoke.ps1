# Proves the signing pipeline works without a purchased certificate.
#
# Creates a throwaway self-signed code-signing certificate, signs copies of
# coucou-hook.exe twice (once with a pfx, once with a certificate thumbprint, the
# way CI signs), verifies signtool /pa /all plus the timestamp, and removes the
# certificate and files again. Nothing in release/ is touched.
#
#   npm run sign:smoke
#   npm run sign:smoke -- -NoTimestamp     # offline
#
# Adding the throwaway certificate to Cert:\CurrentUser\Root is what lets
# signtool verify the chain; it is removed in the finally block. Requires the
# Windows SDK (signtool) and Windows PowerShell 5.1.

param(
  [string]$Hook = "target\release\coucou-hook.exe",
  [switch]$NoTimestamp
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Hook)) {
  throw "$Hook not found. Run: cargo build --release -p coucou-hook"
}

$hookPath = (Resolve-Path $Hook).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("coucou-sign-" + [guid]::NewGuid().ToString("N"))
$cert = $null
$thumbprint = $null
$trusted = $false

try {
  New-Item -ItemType Directory -Path $work | Out-Null

  Write-Host "Creating a throwaway code-signing certificate..."
  $cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=Coucou Signing Smoke Test" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddDays(1)
  $thumbprint = $cert.Thumbprint

  $pfx = Join-Path $work "smoke.pfx"
  $password = [guid]::NewGuid().ToString("N")
  $secure = ConvertTo-SecureString $password -AsPlainText -Force
  Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null

  $viaPfx = Join-Path $work "hook-pfx.exe"
  $viaThumbprint = Join-Path $work "hook-thumbprint.exe"
  Copy-Item $hookPath $viaPfx
  Copy-Item $hookPath $viaThumbprint

  $signParams = @{ Files = @($viaPfx); PfxPath = $pfx; PfxPassword = $password }
  if ($NoTimestamp) { $signParams["NoTimestamp"] = $true }
  & (Join-Path $PSScriptRoot "sign.ps1") @signParams

  $signParams = @{ Files = @($viaThumbprint); Thumbprint = $thumbprint }
  if ($NoTimestamp) { $signParams["NoTimestamp"] = $true }
  & (Join-Path $PSScriptRoot "sign.ps1") @signParams

  # A self-signed chain only verifies once the certificate is trusted. This is a
  # temporary CurrentUser root, removed below.
  $cer = Join-Path $work "smoke.cer"
  Export-Certificate -Cert $cert -FilePath $cer | Out-Null
  & certutil.exe -addstore -user -f Root $cer | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "certutil could not trust the throwaway certificate" }
  $trusted = $true

  $verifyParams = @{ Files = @($viaPfx, $viaThumbprint) }
  if (-not $NoTimestamp) { $verifyParams["RequireTimestamp"] = $true }
  & (Join-Path $PSScriptRoot "verify-signature.ps1") @verifyParams

  Write-Host "Code signing pipeline passed (pfx + thumbprint, timestamp included: $(-not $NoTimestamp))."
}
finally {
  if ($trusted -and $thumbprint) {
    & certutil.exe -delstore -user Root $thumbprint | Out-Null
  }
  if ($cert) {
    Remove-Item "Cert:\CurrentUser\My\$thumbprint" -Force -ErrorAction SilentlyContinue
  }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
