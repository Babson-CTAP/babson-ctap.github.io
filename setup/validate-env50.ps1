#Requires -Version 7.0
# =============================================================
#  OIM 3600 - CTAP  ·  validate-env50.ps1
#  Checks the environment built by setup50.ps1. Changes nothing.
#  Run any time from PowerShell 7:   C:\ctap\validate-env50.ps1
#  Exit code 0 = no failures.
# =============================================================

$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg  = Get-Content (Join-Path $Root 'ctap-config.json') -Raw | ConvertFrom-Json

$script:pass = 0; $script:warn = 0; $script:fail = 0
function Pass { param($m, $d = '') $script:pass++; Write-Host "  [PASS] $m$(if($d){"  ($d)"})" -ForegroundColor Green }
function Warn { param($m, $d = '') $script:warn++; Write-Host "  [WARN] $m$(if($d){"  ($d)"})" -ForegroundColor Yellow }
function Fail { param($m, $d = '') $script:fail++; Write-Host "  [FAIL] $m$(if($d){"  ($d)"})" -ForegroundColor Red }
function Section { param($m) Write-Host "`n  $m" -ForegroundColor White }

$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')

# -- 1. Tools --------------------------------------------------
Section '1. Tools'
if ($PSVersionTable.PSVersion.Major -ge 7) { Pass 'PowerShell 7' "v$($PSVersionTable.PSVersion)" } else { Fail 'Not running in PowerShell 7' }
foreach ($t in @(@{c='git'; a='--version'}, @{c='gh'; a='--version'}, @{c='code'; a='--version'})) {
    if (Get-Command $t.c) { Pass "$($t.c) installed" ((& $t.c $t.a | Select-Object -First 1)) } else { Fail "$($t.c) not found on PATH" }
}
& gh student --help *> $null
if ($LASTEXITCODE -eq 0) { Pass 'gh student tool working' } else { Fail 'gh student tool not working' }

# -- 2. Anaconda / Python --------------------------------------
Section '2. Anaconda and Python'
$ana   = Join-Path $env:USERPROFILE 'anaconda3'
$conda = Join-Path $ana 'Scripts\conda.exe'
if (Test-Path (Join-Path $ana 'python.exe')) { Pass 'Anaconda installed' $ana } else { Fail 'Anaconda not found' $ana }
if (Test-Path $conda) {
    $v = ((& $conda --version) -replace 'conda ', '').Trim()
    if ([int]($v -split '\.')[0] -ge $Cfg.MinCondaMajor) { Pass "conda version OK" $v } else { Fail 'Anaconda too old' $v }
    if ((& $conda config --get auto_activate_base) -match 'false') { Pass 'conda auto_activate_base = false' } else { Warn 'conda auto_activate_base is not false' }
}
if (Get-AppxPackage -Name 'PythonSoftwareFoundation*') { Fail 'Microsoft Store Python installed (conflicts with Anaconda)' } else { Pass 'No Microsoft Store Python' }
$py = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
      Where-Object { $_.DisplayName -match '^Python 3' -and $_.DisplayName -notmatch 'Anaconda|Miniconda' }
if ($py) { Fail 'Conflicting python.org install' ($py.DisplayName -join ', ') } else { Pass 'No conflicting python.org installs' }

# -- 3. PowerShell profile -------------------------------------
Section '3. PowerShell profile'
$prof = $PROFILE.CurrentUserCurrentHost
if (Test-Path $prof) {
    $p = Get-Content $prof -Raw
    if ($p -match 'OIM 3600 CTAP profile') { Pass 'CTAP profile present' } else { Fail 'Profile is not the CTAP profile' $prof }
    if ($p -match "TERM_PROGRAM -eq 'vscode'") { Pass 'conda activates only inside VS Code' } else { Fail 'conda hook missing from profile' }
} else { Fail 'PowerShell profile missing' $prof }
if (Test-Path $PROFILE.CurrentUserAllHosts) { Warn 'Extra profile.ps1 present (may interfere)' $PROFILE.CurrentUserAllHosts }

# -- 4. VS Code -------------------------------------------------
Section '4. VS Code'
$settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
if (Test-Path $settingsPath) {
    $raw = (Get-Content $settingsPath -Raw) -replace '(?m)^\s*//.*$', ''
    $s = $raw | ConvertFrom-Json
    if ($s) {
        $checks = [ordered]@{
            'chat.disableAIFeatures'        = $true
            'editor.inlineSuggest.enabled'  = $false
            'gitlens.ai.enabled'            = $false
            'python.terminal.activateEnvironment' = $false
            'jupyter.jupyterServerType'     = 'local'
        }
        foreach ($k in $checks.Keys) {
            $val = $s.$k
            if ($null -eq $val) { Fail "$k missing" } elseif ("$val" -eq "$($checks[$k])") { Pass "$k = $val" } else { Fail "$k = $val" "expected $($checks[$k])" }
        }
        $interp = $s.'python.defaultInterpreterPath' -replace '/', '\'
        if ($interp -and (Test-Path $interp)) { Pass 'Interpreter path points to Anaconda' } else { Fail 'Interpreter path does not exist' $interp }
    } else { Fail 'VS Code settings.json could not be read' }
} else { Fail 'VS Code settings.json missing' }

$need = 'ms-python.python','ms-toolsai.jupyter','ms-vsliveshare.vsliveshare','ritwickdey.liveserver','eamodio.gitlens','michaelcurrin.auto-commit-msg','tomoki1207.pdf'
$have = (code --list-extensions) | ForEach-Object { $_.ToLower() }
$missing = $need | Where-Object { $have -notcontains $_ }
if ($missing) { Fail 'VS Code extensions missing' ($missing -join ', ') } else { Pass 'VS Code extensions installed' }

# -- 5. GitHub --------------------------------------------------
Section '5. GitHub'
gh auth status *> $null
if ($LASTEXITCODE -eq 0) { Pass 'Logged in to GitHub' } else { Fail 'Not logged in to GitHub' }
$user = (gh api user --jq .login)
$okUser = $user -and (($user -match "^[a-z]+-$($Cfg.UsernameSuffix)$") -or ($Cfg.InstructorAccounts -contains $user) -or ($Cfg.TestAccounts -contains $user))
if ($okUser) { Pass 'GitHub username format' $user } else { Fail 'GitHub username is not a class account' "$user (expected firstname-$($Cfg.UsernameSuffix))" }
if (git config --global user.name)  { Pass 'git user.name set'  (git config --global user.name) }  else { Fail 'git user.name not set' }
if (git config --global user.email) { Pass 'git user.email set' (git config --global user.email) } else { Fail 'git user.email not set' }

# -- 6. Course folders -----------------------------------------
Section '6. Course folders'
$sr = Join-Path $Root 'student_repo'
if (Test-Path (Join-Path $Root 'class_repo\.git')) { Pass 'class_repo downloaded' } else { Fail 'class_repo missing' }
if (Test-Path (Join-Path $sr '.git')) {
    Pass 'student_repo downloaded'
    $origin = git -C $sr remote get-url origin
    $expect = "$($Cfg.Org)/$($Cfg.Classroom)-$($Cfg.Assignment)-$user"
    if ($origin -match [regex]::Escape($expect)) { Pass 'student_repo connected to your GitHub repo' $expect } else { Fail 'student_repo connected to the wrong repo' $origin }
    if (git -C $sr remote | Select-String '^upstream$') { Pass 'upstream remote set' } else { Warn 'upstream remote missing (update50 adds it)' }
    if ((git -C $sr config --get filter.nbstripout.clean)) { Pass 'nbstripout enabled' } else { Warn 'nbstripout not enabled' }
} else { Fail 'student_repo missing' }
if (Test-Path (Join-Path $sr 'ctap.code-workspace')) { Pass 'Workspace file present' } else { Fail 'Workspace file missing' }
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OIM3600.lnk'
if (Test-Path $lnk) { Pass 'Desktop shortcut OIM3600' } else { Fail 'Desktop shortcut missing' $lnk }
foreach ($f in 'ctap-config.json','setup50.ps1','update50.ps1','validate-env50.ps1','reset-env50.ps1','user-settings50.json') {
    if (-not (Test-Path (Join-Path $Root $f))) { Warn "$f missing from $Root" }
}

# -- Summary ---------------------------------------------------
Write-Host ''
Write-Host "  Passed: $script:pass   Warnings: $script:warn   Failed: $script:fail" -ForegroundColor White
if ($script:fail -eq 0) { Write-Host '  Environment ready for class.' -ForegroundColor Green; exit 0 }
Write-Host '  Fix the [FAIL] items above (or run setup50 again).' -ForegroundColor Red
exit 1
