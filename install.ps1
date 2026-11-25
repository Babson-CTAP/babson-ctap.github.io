# =============================================================
#  OIM 3600 - CTAP  ·  Bootstrap installer
#
#  Students paste ONE line into Windows PowerShell (not as admin):
#
#    irm https://babson-ctap.github.io/install.ps1 | iex
#
#  This script:
#    1. Creates C:\ctap
#    2. Downloads the course scripts into C:\ctap
#    3. Starts setup50.ps1
# =============================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'   # progress bars make Windows PowerShell downloads very slow

# Older Windows PowerShell 5 builds may not use TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SiteUrl = 'https://babson-ctap.github.io/setup'
$Root    = 'C:\ctap'
$Files   = @(
    'ctap-config.json',
    'setup50.ps1',
    'update50.ps1',
    'validate-env50.ps1',
    'reset-env50.ps1',
    'user-settings50.json'
)

Write-Host ''
Write-Host '  OIM 3600 - CTAP setup' -ForegroundColor White
Write-Host '  Downloading course files...' -ForegroundColor Cyan

if (-not (Test-Path $Root)) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
}

foreach ($f in $Files) {
    $dest = Join-Path $Root $f
    try {
        Invoke-WebRequest -Uri "$SiteUrl/$f" -OutFile $dest -UseBasicParsing
        Unblock-File -Path $dest
        Write-Host "  [OK] $f" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] Could not download $f" -ForegroundColor Red
        Write-Host "         Check your internet connection and run the command again." -ForegroundColor Yellow
        return
    }
}

# Instructions for resetting this computer (instructor use)
$resetText = @'
OIM 3600 - CTAP: how to reset this computer
(removes everything setup installed, then setup can be run again)

1. Close every PowerShell window.
2. Start menu -> type "Windows PowerShell" -> Run as administrator -> Yes.
   The window title must say "Windows PowerShell" (not just "PowerShell").
3. Paste this one line and press Enter:

irm https://babson-ctap.github.io/setup/reset-env50.ps1 -OutFile $env:TEMP\reset-env50.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\reset-env50.ps1

4. Type RESET when asked. When it finishes, restart the computer.
5. Run setup again from https://babson-ctap.github.io
'@
Set-Content -Path (Join-Path $Root 'reset_command.txt') -Value $resetText -Encoding ascii

# Start setup in a fresh Windows PowerShell process so the
# execution policy never blocks it.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'setup50.ps1')
