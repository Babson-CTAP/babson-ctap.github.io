# =============================================================
#  OIM 3600 - CTAP -- Environment Reset Script
#  Reverses everything done by setup50.ps1, including C:\ctap.
#
#  Run from Windows PowerShell 5 as Administrator:
#    1. Press Start -> type: Windows PowerShell
#    2. Right-click -> Run as Administrator
#    3. powershell -ExecutionPolicy Bypass -File C:\ctap\reset-env50.ps1
# =============================================================

$ErrorActionPreference = 'Continue'

# =============================================================
#  Helpers
# =============================================================
function Write-Banner {
    param($msg)
    $line = '-' * 60
    Write-Host "`n$line" -ForegroundColor White
    Write-Host "  $msg" -ForegroundColor White
    Write-Host "$line`n" -ForegroundColor White
}
function Write-Step { param($msg) Write-Host "  >> $msg"     -ForegroundColor Cyan    }
function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green   }
function Write-Warn { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow  }
function Write-Skip { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Fail { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red     }

function Remove-IfExists {
    param([string]$Path, [string]$Label = '')
    if (-not $Label) { $Label = $Path }
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-OK "Removed: $Label"
        } catch {
            Write-Warn "Could not remove: $Label  ($_)"
        }
    } else {
        Write-Skip "Not found: $Label"
    }
}

function Remove-PathEntry {
    param([string]$Substring, [string]$Scope)
    $current = [System.Environment]::GetEnvironmentVariable('PATH', $Scope)
    if (-not $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -and $_ -notlike "*$Substring*" }
    $newPath = $parts -join ';'
    if ($newPath -ne $current) {
        [System.Environment]::SetEnvironmentVariable('PATH', $newPath, $Scope)
        Write-OK "Removed '$Substring' from $Scope PATH"
    } else {
        Write-Skip "'$Substring' not in $Scope PATH"
    }
}

# Uninstall through Windows' own uninstall entries (no winget, so the
# Microsoft Store certificate problem cannot block it).
function Uninstall-ByName {
    param([string]$Pattern, [string]$Label)
    Write-Step "Uninstalling $Label..."
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $find = { Get-ItemProperty $roots -ErrorAction SilentlyContinue |
              Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $Pattern } }
    $apps = & $find
    if (-not $apps) { Write-Skip "$Label not installed"; return }
    foreach ($a in $apps) {
        $u = "$($a.UninstallString)"
        if ($u -match 'msiexec') {
            Start-Process msiexec.exe -ArgumentList "/x $($a.PSChildName) /qn /norestart" -Wait
        } else {
            $exe = if ($u -match '^"([^"]+)"') { $Matches[1] } else { ($u -split ' ')[0] }
            if (Test-Path $exe) { Start-Process $exe -ArgumentList '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES' -Wait }
        }
    }
    if (& $find) { Write-Warn "$Label may still be installed -- remove it in Settings > Apps" }
    else         { Write-OK   "$Label removed" }
}

function Uninstall-WingetApp {
    param([string]$Id, [string]$Name)
    Write-Step "Uninstalling $Name..."
    $result = winget uninstall --id $Id --silent --accept-source-agreements 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $result -match 'No installed package|not found') {
        Write-OK "$Name removed (or was not installed)"
    } else {
        Write-Warn "$Name -- winget exit code $LASTEXITCODE  (may still have been removed)"
    }
}

# =============================================================
#  Admin check
# =============================================================
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail 'This script must be run as Administrator. Exiting.'
    exit 1
}

# =============================================================
#  Confirmation
# =============================================================
Write-Host ''
Write-Host '  OIM 3600 -- Environment Reset' -ForegroundColor White
Write-Host ''
Write-Host '  This script will:' -ForegroundColor Yellow
Write-Host '    - Uninstall: Git, GitHub CLI, VS Code, Anaconda, PowerShell 7' -ForegroundColor Yellow
Write-Host '    - Remove the gh student extension' -ForegroundColor Yellow
Write-Host '    - Delete all conda, git, gh, and VS Code config files/folders' -ForegroundColor Yellow
Write-Host '    - Remove PowerShell profiles written by setup50.ps1' -ForegroundColor Yellow
Write-Host '    - Delete C:\ctap\student_repo and class_repo (unpushed student work is LOST)' -ForegroundColor Yellow
Write-Host '    - Clean PATH entries and registry uninstall keys' -ForegroundColor Yellow
Write-Host '    - Remove OIM3600 desktop shortcut' -ForegroundColor Yellow
Write-Host ''
Write-Host '  C:\ctap is deleted too (the setup command recreates it).' -ForegroundColor DarkGray
Write-Host ''
$confirm = Read-Host '  Type RESET to continue, anything else to cancel'
if ($confirm -ne 'RESET') {
    Write-Host '  Cancelled -- nothing was changed.' -ForegroundColor DarkGray
    exit 0
}

# -- ensure winget is accessible ----------------------------------
$windowsAppsPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
if ($env:PATH -notmatch [regex]::Escape($windowsAppsPath)) {
    $env:PATH = "$windowsAppsPath;$env:PATH"
}

# =============================================================
#  0. classroom50 gh extension
#     Remove before uninstalling gh itself
# =============================================================
Write-Banner '0. classroom50 GitHub CLI Extension'

Write-Step 'Removing classroom50 gh extensions...'
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $extList = gh extension list 2>&1 | Out-String
    foreach ($extName in @('gh-student', 'gh-teacher')) {
        if ($extList -match $extName) {
            gh extension remove $extName 2>&1 | Out-Null
            Write-OK "$extName extension removed"
        } else {
            Write-Skip "$extName extension not installed"
        }
    }
} else {
    Write-Skip 'gh not found -- skipping extension removal'
}

# =============================================================
#  1. Uninstall programs
# =============================================================
Write-Banner '1. Uninstalling Programs'

Write-Step 'Uninstalling Anaconda...'
$anacondaUninstaller = "$env:USERPROFILE\anaconda3\Uninstall-Anaconda3.exe"
if (Test-Path $anacondaUninstaller) {
    Start-Process $anacondaUninstaller -ArgumentList '/S' -Wait -ErrorAction SilentlyContinue
    Write-OK 'Anaconda silent uninstaller completed'
} else {
    Write-Skip 'Anaconda uninstaller not found at expected path'
}

Uninstall-ByName 'Git'                             'Git for Windows'
Uninstall-ByName 'GitHub CLI'                      'GitHub CLI'
Uninstall-ByName 'Microsoft Visual Studio Code*'   'Visual Studio Code'
# PowerShell 7 is uninstalled last (section 9) in case we are running inside it

# =============================================================
#  2. Anaconda / conda folders and config
# =============================================================
Write-Banner '2. Anaconda and Conda'

$anacondaDirs = @(
    "$env:USERPROFILE\anaconda3",
    "$env:USERPROFILE\.conda",
    "$env:USERPROFILE\.continuum",
    "$env:USERPROFILE\AppData\Local\conda",
    "$env:USERPROFILE\AppData\Local\Temp\anaconda*",
    "$env:USERPROFILE\AppData\Roaming\conda"
)
foreach ($d in $anacondaDirs) {
    if ($d -match '\*') {
        Get-Item $d -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-IfExists $_.FullName
        }
    } else {
        Remove-IfExists $d
    }
}

Remove-IfExists "$env:USERPROFILE\.condarc"                    '.condarc'
Remove-IfExists "$env:USERPROFILE\AppData\Roaming\Python"      'Roaming\Python'
Remove-IfExists "$env:USERPROFILE\AppData\Local\pip"           'pip cache'

# =============================================================
#  3. Git config and folders
# =============================================================
Write-Banner '3. Git'

Remove-IfExists "$env:USERPROFILE\.gitconfig"       '.gitconfig'
Remove-IfExists "$env:USERPROFILE\.gitconfig.lock"  '.gitconfig.lock'
Remove-IfExists "$env:APPDATA\Git"                  'AppData\Roaming\Git'
Remove-IfExists "$env:LOCALAPPDATA\Programs\Git"    'LocalAppData\Programs\Git'

$gitRegKeys = @(
    'HKCU:\Software\GitForWindows',
    'HKLM:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\WOW6432Node\GitForWindows'
)
foreach ($k in $gitRegKeys) {
    if (Test-Path $k) {
        Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Removed registry key: $k"
    } else {
        Write-Skip "Registry key not found: $k"
    }
}

# =============================================================
#  4. GitHub CLI config
# =============================================================
Write-Banner '4. GitHub CLI'

Remove-IfExists "$env:APPDATA\GitHub CLI"        'AppData\Roaming\GitHub CLI'
Remove-IfExists "$env:LOCALAPPDATA\GitHub CLI"   'AppData\Local\GitHub CLI'
Remove-IfExists "$env:LOCALAPPDATA\GitHubCLI"    'AppData\Local\GitHubCLI'

# Per-account gh config folders from older setups (gh-<name>)
$dotConfig = "$env:USERPROFILE\.config"
if (Test-Path $dotConfig) {
    Get-ChildItem $dotConfig -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^gh-' } |
        ForEach-Object { Remove-IfExists $_.FullName "~\.config\$($_.Name)" }
}

# =============================================================
#  5. VS Code config
# =============================================================
Write-Banner '5. VS Code'

$vsCodeProfilesDir = "$env:APPDATA\Code\User\profiles"
if (Test-Path $vsCodeProfilesDir) {
    Get-ChildItem $vsCodeProfilesDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $profileJson = Join-Path $_.FullName 'profile.json'
            if (Test-Path $profileJson) {
                $content = Get-Content $profileJson -Raw -ErrorAction SilentlyContinue
                if ($content -match 'OIM3600') {
                    Remove-IfExists $_.FullName "VS Code profile OIM3600 ($($_.Name))"
                }
            }
        }
} else {
    Write-Skip 'VS Code profiles directory not found'
}

Remove-IfExists "$env:APPDATA\Code\User\settings.json" 'VS Code user settings.json'
Remove-IfExists "$env:USERPROFILE\.vscode"        '.vscode'
Remove-IfExists "$env:USERPROFILE\.vscode-shared" '.vscode-shared'
Remove-IfExists "$env:LOCALAPPDATA\GitkrakenCLI"  'AppData\Local\GitkrakenCLI'

# =============================================================
#  6. PowerShell profiles
# =============================================================
Write-Banner '6. PowerShell Profiles'

$docs = [Environment]::GetFolderPath('MyDocuments')   # OneDrive-safe
$psProfiles = @(
    "$docs\PowerShell\Microsoft.PowerShell_profile.ps1",
    "$docs\PowerShell\profile.ps1",
    "$docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$docs\WindowsPowerShell\profile.ps1"
)
foreach ($p in $psProfiles) { Remove-IfExists $p }

# =============================================================
#  7. Course files created by setup50.ps1
# =============================================================
Write-Banner '7. Course Setup Files'

$courseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path   # C:\ctap
Remove-IfExists "$courseRoot\.student_config.txt" '.student_config.txt'
Remove-IfExists "$courseRoot\student_repo"         'student_repo\'
Remove-IfExists "$courseRoot\class_repo"           'class_repo\'

Remove-IfExists (Join-Path ([Environment]::GetFolderPath('Desktop')) 'OIM3600.lnk') 'Desktop shortcut OIM3600.lnk'

# Sync state stored outside the repo
Remove-IfExists "$env:USERPROFILE\.ctap" '.ctap sync state folder'

# =============================================================
#  8. PATH cleanup
# =============================================================
Write-Banner '8. PATH Cleanup'

Remove-PathEntry 'VS Code'        'User'
Remove-PathEntry 'anaconda'       'User'
Remove-PathEntry 'Anaconda'       'User'
Remove-PathEntry 'condabin'       'User'

Remove-PathEntry 'Git\cmd'        'Machine'
Remove-PathEntry 'Git\mingw64'    'Machine'
Remove-PathEntry 'Git\usr\bin'    'Machine'
Remove-PathEntry 'GitHub CLI'     'Machine'


# =============================================================
#  9. Registry -- uninstall key cleanup
# =============================================================
Write-Banner '9. Registry Uninstall Keys'

$uninstallHives = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$removePatterns = @(
    '*Git for Windows*',
    '*GitHub CLI*',
    '*Visual Studio Code*',
    '*Anaconda*',
    '*Miniconda*'
)

foreach ($hive in $uninstallHives) {
    if (-not (Test-Path $hive)) { continue }
    Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
        $displayName = $_.GetValue('DisplayName')
        if (-not $displayName) { return }
        foreach ($pattern in $removePatterns) {
            if ($displayName -like $pattern) {
                $keyPath = $_.PSPath
                try {
                    Remove-Item $keyPath -Recurse -Force -ErrorAction Stop
                    Write-OK "Removed uninstall key: $displayName"
                } catch {
                    Write-Warn "Could not remove uninstall key: $displayName"
                }
                break
            }
        }
    }
}

# =============================================================
#  10. Uninstall PowerShell 7 (last -- we may be running in it)
# =============================================================
Write-Banner '10. PowerShell 7'

Write-Warn 'Uninstalling PowerShell 7 last. If you are running this script'
Write-Warn 'inside pwsh, the session will end after this step.'
Write-Host ''

Uninstall-ByName 'PowerShell 7*' 'PowerShell 7'

Remove-IfExists 'C:\Program Files\PowerShell\7'                          'PS7 install folder'
Remove-IfExists "$env:LOCALAPPDATA\Microsoft\powershell"                 'PS7 LocalAppData'
Remove-PathEntry 'PowerShell\7'                                          'Machine'

# =============================================================
#  11. Remove C:\ctap itself (setup's install command recreates it)
# =============================================================
Write-Banner '11. Course folder'
Set-Location $env:SystemRoot
Remove-IfExists $courseRoot "$courseRoot (scripts, logs)"
if (Test-Path $courseRoot) {
    Write-Warn "$courseRoot is open in another window. Close that window and delete the folder by hand."
}

# =============================================================
#  Summary
# =============================================================
Write-Banner 'RESET COMPLETE'
Write-Host '  The machine is back to its pre-setup state.' -ForegroundColor White
Write-Host ''
Write-Host '  Recommended: restart the computer, then run the setup command' -ForegroundColor Yellow
Write-Host '  from https://babson-ctap.github.io' -ForegroundColor Yellow
Write-Host ''
