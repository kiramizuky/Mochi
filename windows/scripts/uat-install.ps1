# Per-user install UAT for the NSIS installer.
#
# Installs silently into the current user, checks the registry entry, the
# installed binaries, the staged relay and the app smoke test, then uninstalls
# and checks that disposable data went away while user preferences and Claude
# Code's settings.json were left alone.
#
#   npm run uat:install
#   npm run uat:install -- -Installer release/Coucou-Windows-0.1.1-setup.exe -KeepInstalled
#   npm run uat:install -- -ExpectSignature     # signed release
#
# This changes this user's installed apps (then reverts it). Close Coucou first.
# Run it on Windows 10 and Windows 11 as a normal user for release sign-off.

param(
  [string]$Installer,
  [switch]$KeepInstalled,
  [switch]$ExpectSignature,
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-CoucouUninstallEntry {
  $root = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
  if (-not (Test-Path $root)) { return $null }
  Get-ChildItem $root | ForEach-Object {
    $item = Get-ItemProperty $_.PSPath
    if ($item.DisplayName -like "Coucou*") { $item }
  } | Select-Object -First 1
}

function Get-InstalledExe([string]$EntryPath) {
  $item = Get-ItemProperty $EntryPath
  # Tauri's NSIS writes InstallLocation with surrounding quotes on some
  # versions; a quoted path is still a path, not a drive called '"C'.
  $location = ([string]$item.InstallLocation).Trim().Trim('"')
  if ($location) {
    $candidate = Join-Path $location "coucou.exe"
    if (Test-Path $candidate) { return $candidate }
  }
  $icon = ([string]$item.DisplayIcon).Trim().Trim('"') -replace ',\d+$', ''
  if ($icon -and (Test-Path $icon)) { return $icon }
  return $null
}

function Invoke-QuietUninstall([string]$UninstallString) {
  $exe = $UninstallString -replace '^"', '' -replace '".*$', ''
  if (-not (Test-Path $exe)) { throw "Uninstaller not found: $exe" }
  $p = Start-Process -FilePath $exe -ArgumentList "/S" -Wait -PassThru
  return $p.ExitCode
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($elevated) {
  Write-Warning "This shell is elevated; the no-admin install contract is not being exercised."
}

$existing = Get-CoucouUninstallEntry
if ($existing) {
  throw "Coucou is already installed ($($existing.DisplayName) $($existing.DisplayVersion)). Uninstall it first."
}

if (-not $Installer) {
  $candidate = Get-ChildItem (Join-Path $PSScriptRoot "..\release") -Filter "Coucou-Windows-*-setup.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^Coucou-Windows-\d+\.\d+\.\d+-setup\.exe$' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $candidate) { throw "No versioned installer in windows\release. Run: npm run pack" }
  $Installer = $candidate.FullName
}
if (-not (Test-Path $Installer)) { throw "Installer not found: $Installer" }
$installerPath = (Resolve-Path $Installer).Path

$name = Split-Path $installerPath -Leaf
if ($name -notmatch '^Coucou-Windows-(?<version>\d+\.\d+\.\d+)-setup\.exe$') {
  throw "Expected a versioned installer named Coucou-Windows-<version>-setup.exe, got $name"
}
$expectedVersion = $Matches.version

$claudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$claudeBefore = if (Test-Path $claudeSettings) { (Get-FileHash $claudeSettings -Algorithm SHA256).Hash } else { $null }
$prefs = Join-Path $env:APPDATA "Coucou\settings.json"
$prefsBefore = if (Test-Path $prefs) { (Get-FileHash $prefs -Algorithm SHA256).Hash } else { $null }
$local = Join-Path $env:LOCALAPPDATA "Coucou"

$installed = $false
$entryPath = $null

try {
  if ($ExpectSignature) {
    & (Join-Path $PSScriptRoot "verify-signature.ps1") -Files $installerPath -RequireTimestamp
  } else {
    $sig = Get-AuthenticodeSignature $installerPath
    if ($sig.Status -eq "NotSigned") {
      Write-Warning "Installer is unsigned; UAT continues, but a public release must be signed."
    }
  }

  Write-Host "Installing $name (current user, silent)..."
  $install = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
  if ($install.ExitCode -ne 0) { throw "Installer exited $($install.ExitCode)" }
  $installed = $true

  $deadline = (Get-Date).AddSeconds(30)
  do {
    $entry = Get-CoucouUninstallEntry
    if ($entry) { $entryPath = $entry.PSPath }
    if (-not $entry) { Start-Sleep -Milliseconds 250 }
  } while (-not $entry -and (Get-Date) -lt $deadline)
  if (-not $entry) { throw "No HKCU uninstall entry appeared after 30 s" }

  if ($entry.DisplayVersion -ne $expectedVersion) {
    throw "Registry version is '$($entry.DisplayVersion)', expected '$expectedVersion'"
  }
  if (-not $entry.UninstallString) { throw "UninstallString is missing" }
  Write-Host "  registry: $($entry.DisplayName) $($entry.DisplayVersion), publisher $($entry.Publisher)"

  $exe = Get-InstalledExe $entryPath
  if (-not $exe) { throw "coucou.exe is not in the install location" }
  $installDir = Split-Path $exe -Parent
  Write-Host "  installed at $installDir"

  $hookResource = Join-Path $installDir "coucou-hook.exe"
  if (-not (Test-Path $hookResource)) { throw "coucou-hook.exe resource is missing from the install directory" }

  if ($ExpectSignature) {
    & (Join-Path $PSScriptRoot "verify-signature.ps1") -Files $exe, $hookResource -RequireTimestamp
  }

  & (Join-Path $PSScriptRoot "smoke-app.ps1") -App $exe -TimeoutSec $TimeoutSec

  $stagedHook = Join-Path $local "bin\coucou-hook.exe"
  if (-not (Test-Path $stagedHook)) { throw "The app did not stage the relay at $stagedHook" }
  if ($ExpectSignature) {
    & (Join-Path $PSScriptRoot "verify-signature.ps1") -Files $stagedHook -RequireTimestamp
  }
  Write-Host "  relay staged at $stagedHook"

  if ($KeepInstalled) {
    Write-Host "Keeping Coucou $expectedVersion installed at $installDir (-KeepInstalled)."
    return
  }

  Write-Host "Uninstalling..."
  $code = Invoke-QuietUninstall $entry.UninstallString
  if ($code -ne 0) { throw "Uninstaller exited $code" }

  $deadline = (Get-Date).AddSeconds(30)
  do {
    $stillInstalled = (Get-CoucouUninstallEntry) -or (Test-Path $exe)
    if ($stillInstalled) { Start-Sleep -Milliseconds 250 }
  } while ($stillInstalled -and (Get-Date) -lt $deadline)
  if (Get-CoucouUninstallEntry) { throw "The uninstall registry entry survived" }
  if (Test-Path $exe) { throw "coucou.exe survived the uninstall" }
  $installed = $false

  foreach ($disposable in @("bin", "inbox", "crashes", "coucou.log", "coucou.log.1", "coucou-log-export.txt")) {
    $path = Join-Path $local $disposable
    if (Test-Path $path) { throw "Disposable data survived the uninstall: $path" }
  }

  $claudeAfter = if (Test-Path $claudeSettings) { (Get-FileHash $claudeSettings -Algorithm SHA256).Hash } else { $null }
  if ($claudeBefore -ne $claudeAfter) { throw "Uninstall changed Claude Code's settings.json" }

  $prefsAfter = if (Test-Path $prefs) { (Get-FileHash $prefs -Algorithm SHA256).Hash } else { $null }
  if ($prefsBefore -and $prefsBefore -ne $prefsAfter) { throw "Uninstall changed the user's Coucou preferences" }

  Write-Host "UAT passed: install, launch, relay, smoke test, uninstall and cleanup."
}
finally {
  if ($installed -and -not $KeepInstalled) {
    try {
      $entry = Get-CoucouUninstallEntry
      if ($entry -and $entry.UninstallString) {
        Write-Warning "Cleaning up a failed UAT run..."
        Invoke-QuietUninstall $entry.UninstallString | Out-Null
      }
    } catch {
      Write-Warning "Cleanup uninstall failed: $_"
    }
  }
}
