#Requires -Version 5.1
# =============================================================
#  OIM 3600 - CTAP  ·  Environment Setup  ·  setup50.ps1
#
#  Started by install.ps1 (or by hand):
#      powershell -ExecutionPolicy Bypass -File C:\ctap\setup50.ps1
#
#  Runs in three stages, chained automatically:
#    Main      Windows PowerShell 5, normal user  -> preflight, then
#              starts Install (admin) and Configure (PS7)
#    Install   Windows PowerShell 5, Administrator (one "Yes" click)
#    Configure PowerShell 7, normal user
#
#  Safe to re-run at any time: every step skips what is already done.
# =============================================================

param(
    [ValidateSet('Main', 'Install', 'Configure')]
    [string]$Stage = 'Main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================
#  SECTION 1 -- Config and helpers
# =============================================================

$ScriptPath = $MyInvocation.MyCommand.Path
$Root       = Split-Path -Parent $ScriptPath
$ConfigFile = Join-Path $Root 'ctap-config.json'

if (-not (Test-Path $ConfigFile)) {
    Write-Host "  [FAIL] ctap-config.json not found in $Root" -ForegroundColor Red
    Write-Host '         Re-run the install command from the course website.' -ForegroundColor Yellow
    exit 1
}
$Cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Log every stage to C:\ctap\logs so a failed install can be diagnosed later.
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ("setup-{0}-{1}.log" -f $Stage, (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { }

function Write-Banner { param($msg) $l = '-' * 60; Write-Host "`n$l`n  $msg`n$l" -ForegroundColor White }
function Write-Step   { param($msg) Write-Host "  >> $msg"     -ForegroundColor Cyan }
function Write-OK     { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail   { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red }

function Stop-Setup {
    param($msg)
    Write-Fail $msg
    Write-Host ''
    Write-Host "  Setup stopped. Fix the problem above, then run setup again." -ForegroundColor Yellow
    Write-Host "  If you are stuck, email your instructor the log file:" -ForegroundColor Yellow
    Write-Host "    $LogFile" -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch { }
    if ($Stage -ne 'Main') { Read-Host '  Press Enter to close this window' | Out-Null }
    exit 1
}

function Test-Cmd { param($name) return $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('PATH', 'User')
    $wa = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if ((Test-Path $wa) -and ($env:PATH -notmatch [regex]::Escape($wa))) { $env:PATH = "$wa;$env:PATH" }
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'

# =============================================================
#  SECTION 2 -- Preflight (Main stage, normal user)
#  Stops only on problems setup cannot fix itself.
# =============================================================

function Invoke-Preflight {
    Write-Banner 'Checking this computer'

    # Windows 10/11, 64-bit
    $os = Get-CimInstance Win32_OperatingSystem
    if (-not [Environment]::Is64BitOperatingSystem) { Stop-Setup '64-bit Windows is required.' }
    if ([int]$os.BuildNumber -lt 19041) { Stop-Setup "Windows is too old ($($os.Caption), build $($os.BuildNumber)). Update Windows first." }
    Write-OK "$($os.Caption) (build $($os.BuildNumber))"

    # Disk space: Anaconda alone needs several GB
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    if ($freeGB -lt 15) { Stop-Setup "Only $freeGB GB free on C:. At least 15 GB is needed." }
    Write-OK "$freeGB GB free on C:"

    # C:\ctap writable
    try {
        $probe = Join-Path $Root '.write-test'
        Set-Content -Path $probe -Value 'ok'; Remove-Item $probe -Force
        Write-OK "$Root is writable"
    } catch { Stop-Setup "Cannot write to $Root." }

    # Real Desktop folder (handles OneDrive-redirected desktops)
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path $desktop)) { Stop-Setup 'Cannot find your Desktop folder.' }
    Write-OK "Desktop: $desktop"

    # Internet: GitHub and Anaconda must be reachable
    foreach ($url in @('https://github.com', 'https://repo.anaconda.com')) {
        try {
            Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null
            Write-OK "Can reach $url"
        } catch { Stop-Setup "Cannot reach $url. Check your internet connection (Babson guest Wi-Fi may block it)." }
    }

    # winget (Windows App Installer); on brand-new machines it may need registering
    Update-SessionPath
    if (-not (Test-Cmd 'winget')) {
        Write-Step 'winget not ready yet -- registering Windows App Installer...'
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 5
        Update-SessionPath
    }
    if (-not (Test-Cmd 'winget')) {
        Stop-Setup 'winget is not available. Open the Microsoft Store, update "App Installer", then run setup again.'
    }
    Write-OK "winget $(winget --version)"

    # Pending Windows restart (warning only)
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($pending) { Write-Warn 'Windows has a restart pending. If an install fails, restart and run setup again.' }
}

# =============================================================
#  SECTION 3 -- Install software (Install stage, Administrator)
#  Machine-wide tools only. Anaconda is installed later as the
#  normal user, so it always lands in the student's own profile.
# =============================================================

function Invoke-Install {
    Write-Banner 'Installing software (this can take 10-15 minutes)'

    if (-not (Test-IsAdmin)) { Stop-Setup 'The install stage must run as Administrator.' }
    Update-SessionPath

    # -- remove conflicting Python installs (python.org and Microsoft Store) --
    Write-Step 'Checking for conflicting Python installations...'
    foreach ($root in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^Python 3' -and $_.DisplayName -notmatch 'Anaconda|Miniconda' } |
            ForEach-Object {
                Write-Warn "Removing $($_.DisplayName)"
                Start-Process msiexec.exe -ArgumentList "/X $($_.PSChildName) /quiet /norestart" -Wait -ErrorAction SilentlyContinue
            }
    }
    Get-AppxPackage -Name 'PythonSoftwareFoundation*' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Warn "Removing Microsoft Store Python ($($_.Name))"
        Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
    }
    Write-OK 'No conflicting Python installs'

    # -- PowerShell 7: classic MSI installer, downloaded directly.
    #    (From 7.7 on, winget only offers a per-user Store-style package,
    #     which cannot be installed machine-wide.)
    if (Test-Path $Pwsh) { Write-OK 'PowerShell 7 already installed' }
    else {
        Write-Step 'Installing PowerShell 7...'
        $msi = Join-Path $env:TEMP 'PowerShell-7-win-x64.msi'
        try { Invoke-WebRequest -Uri $Cfg.PwshMsiUrl -OutFile $msi -UseBasicParsing }
        catch { Stop-Setup "Could not download PowerShell 7 from $($Cfg.PwshMsiUrl)" }
        $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
            "/i `"$msi`" /qn /norestart ADD_PATH=1 REGISTER_MANIFEST=1 ENABLE_PSREMOTING=0 ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0"
        if (Test-Path $Pwsh) { Write-OK 'PowerShell 7 installed' }
        else { Stop-Setup "PowerShell 7 did not install (msiexec exit code $($proc.ExitCode))." }
    }

    # -- other machine-wide tools via winget --
    $tools = @(
        @{ Id = 'Git.Git';                    Name = 'Git';                Check = 'C:\Program Files\Git\cmd\git.exe' },
        @{ Id = 'GitHub.cli';                 Name = 'GitHub CLI';         Check = 'C:\Program Files\GitHub CLI\gh.exe' },
        @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code'; Check = 'C:\Program Files\Microsoft VS Code\Code.exe' }
    )

    foreach ($t in $tools) {
        if (Test-Path $t.Check) { Write-OK "$($t.Name) already installed"; continue }
        Write-Step "Installing $($t.Name)..."
        winget install --id $t.Id --exact --source winget --scope machine --silent `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
        if (Test-Path $t.Check) { Write-OK "$($t.Name) installed" }
        else { Stop-Setup "$($t.Name) did not install (winget exit code $LASTEXITCODE)." }
    }

    Write-OK 'Software installed'
}

# =============================================================
#  SECTIONS 4-8 -- Configure (PowerShell 7, normal user)
# =============================================================

$AnacondaDir = Join-Path $env:USERPROFILE 'anaconda3'
$PythonExe   = Join-Path $AnacondaDir 'python.exe'
$CodeExe     = 'C:\Program Files\Microsoft VS Code\Code.exe'
$CodeCmd     = 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
$StudentRepo = Join-Path $Root 'student_repo'
$Workspace   = Join-Path $StudentRepo 'ctap.code-workspace'

# -------------------------------------------------------------
#  SECTION 4 -- Anaconda (installed "just for me", no admin)
# -------------------------------------------------------------
function Install-Anaconda {
    Write-Banner 'Anaconda (this is the slow one -- 5 to 10 minutes)'
    $condaExe = Join-Path $AnacondaDir 'Scripts\conda.exe'

    if (Test-Path $condaExe) {
        $ver   = ((& $condaExe --version 2>$null) -replace 'conda ', '').Trim()
        $major = [int](($ver -split '\.')[0])
        if ($major -ge $Cfg.MinCondaMajor) { Write-OK "Anaconda already installed (conda $ver)"; return }
        Stop-Setup "An old Anaconda (conda $ver) is installed. Ask your instructor to run reset-env50.ps1, then run setup again."
    }

    $override = '/S /InstallationType=JustMe /RegisterPython=1 /AddToPath=0 /D={0}' -f $AnacondaDir
    Write-Step 'Installing Anaconda...'
    winget install --id Anaconda.Anaconda3 --exact --source winget --scope user --silent `
        --accept-package-agreements --accept-source-agreements --override $override 2>&1 | Out-Host

    if (-not (Test-Path $PythonExe)) {
        Write-Warn 'winget could not install Anaconda -- downloading the installer directly...'
        $url = $null
        try {
            $idx = Invoke-WebRequest -Uri 'https://repo.anaconda.com/archive/' -UseBasicParsing
            $exe = $idx.Links.href | Where-Object { $_ -match '^Anaconda3-\d{4}\.\d+-\d+-Windows-x86_64\.exe$' } |
                   Sort-Object -Descending | Select-Object -First 1
            if ($exe) { $url = "https://repo.anaconda.com/archive/$exe" }
        } catch { }
        if (-not $url) { Stop-Setup 'Could not find the Anaconda installer online.' }
        $tmp = Join-Path $env:TEMP 'Anaconda3-installer.exe'
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        Start-Process -FilePath $tmp -ArgumentList $override -Wait
    }

    if (-not (Test-Path $PythonExe)) { Stop-Setup 'Anaconda did not install.' }
    Write-OK 'Anaconda installed'
}

# -------------------------------------------------------------
#  SECTION 5 -- PowerShell profile, conda, VS Code
# -------------------------------------------------------------
function Set-ShellAndEditor {
    Write-Banner 'Configuring PowerShell and VS Code'

    # conda: never auto-activate outside VS Code
    $condaBat = Join-Path $AnacondaDir 'condabin\conda.bat'
    & $condaBat config --set auto_activate_base false 2>&1 | Out-Null
    Write-OK 'conda configured (active only inside VS Code)'

    # PowerShell 7 profile. $PROFILE gives the real path even when
    # Documents is redirected to OneDrive (common on Babson laptops).
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $allHosts    = $PROFILE.CurrentUserAllHosts
    if (Test-Path $allHosts) { Remove-Item $allHosts -Force }   # conda init leftovers
    New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null

    $ghLine = ''
    if ($env:GH_CONFIG_DIR) { $ghLine = "`$env:GH_CONFIG_DIR = '$env:GH_CONFIG_DIR'" }   # keep instructor test setups

    $profileText = @"
# ---- OIM 3600 CTAP profile (written by setup50.ps1) ----
`$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
             [Environment]::GetEnvironmentVariable('PATH','User')
$ghLine
# Activate Anaconda only inside VS Code terminals
if (`$env:TERM_PROGRAM -eq 'vscode' -and (Test-Path '$AnacondaDir\Scripts\conda.exe')) {
    (& '$AnacondaDir\Scripts\conda.exe' 'shell.powershell' 'hook') | Out-String | Invoke-Expression
    conda activate base *> `$null
}
"@
    [IO.File]::WriteAllText($profilePath, $profileText, [Text.UTF8Encoding]::new($false))
    Write-OK "PowerShell profile written"

    # VS Code extensions (close VS Code first so installs complete)
    Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force
    $extensions = @(
        'ms-python.python', 'ms-python.vscode-pylance', 'ms-toolsai.jupyter',
        'ms-vsliveshare.vsliveshare', 'ritwickdey.liveserver', 'eamodio.gitlens',
        'michaelcurrin.auto-commit-msg', 'tomoki1207.pdf'
    )
    $installed = (& $CodeCmd --list-extensions 2>$null) | ForEach-Object { $_.ToLower() }
    foreach ($ext in $extensions) {
        if ($installed -contains $ext.ToLower()) { continue }
        Write-Step "VS Code extension $ext..."
        & $CodeCmd --install-extension $ext --force 2>&1 | Out-Null
    }
    Write-OK 'VS Code extensions installed'

    # VS Code user settings (AI off). Placeholder path -> this user's profile.
    $src = Join-Path $Root 'user-settings50.json'
    $dst = Join-Path $env:APPDATA 'Code\User\settings.json'
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    $profileFwd = $env:USERPROFILE -replace '\\', '/'
    $text = (Get-Content $src -Raw) -replace 'C:/Users/WINDOWS-USER-NAME', $profileFwd
    [IO.File]::WriteAllText($dst, $text, [Text.UTF8Encoding]::new($false))
    Write-OK 'VS Code settings written (AI features off)'
}

# -------------------------------------------------------------
#  SECTION 6 -- GitHub: login, username check, Git identity, accept
# -------------------------------------------------------------
function Connect-GitHub {
    Write-Banner 'Connecting to GitHub'
    Update-SessionPath

    # gh-student extension (published build, no Go needed)
    if ((gh extension list 2>$null | Out-String) -match 'gh-student') {
        gh extension upgrade gh-student 2>&1 | Out-Null
    } else {
        gh extension install foundation50/gh-student 2>&1 | Out-Null
    }
    & gh student --help *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Setup 'Could not install the gh student tool.' }
    Write-OK 'gh student tool ready'

    # Login (skipped when already logged in)
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  Your browser will open so you can connect GitHub.' -ForegroundColor Yellow
        Write-Host '   1. Write down the 8-character code shown below (do NOT press Ctrl+C).' -ForegroundColor Yellow
        Write-Host '   2. Press Enter, enter the code in the browser, and click Authorize.' -ForegroundColor Yellow
        Write-Host '   3. If asked any other question here, just press Enter.' -ForegroundColor Yellow
        Write-Host ''
        gh auth login --hostname github.com --web --git-protocol https `
            -s admin:org -s read:org -s repo -s workflow
        gh auth status *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Setup 'GitHub login did not complete.' }
    }
    gh auth setup-git 2>&1 | Out-Null

    # Who is logged in? Check it is the class account.
    $user = (gh api user --jq .login).Trim()
    $okFormat = ($user -match "^[a-z]+-$($Cfg.UsernameSuffix)$") -or
                ($Cfg.InstructorAccounts -contains $user) -or ($Cfg.TestAccounts -contains $user)
    if (-not $okFormat) {
        gh auth logout --hostname github.com 2>&1 | Out-Null
        Stop-Setup "You logged in as '$user'. Use your class account (firstname-$($Cfg.UsernameSuffix)). Sign out of GitHub in your browser, sign in with the class account, then run setup again."
    }
    Set-Content -Path (Join-Path $Root '.student_config.txt') -Value $user -Encoding ascii
    Write-OK "Logged in as $user"

    # Git identity from the GitHub account (no typing)
    if (-not (git config --global user.name))  {
        $name = (gh api user --jq '.name // .login').Trim()
        git config --global user.name $name
    }
    if (-not (git config --global user.email)) {
        $id = (gh api user --jq .id).Trim()
        git config --global user.email "$id+$user@users.noreply.github.com"
    }
    Write-OK "Git identity: $(git config --global user.name) <$(git config --global user.email)>"

    # Invited? (no invite = instructor hasn't added this account yet)
    $state = (gh api "user/memberships/orgs/$($Cfg.Org)" --jq .state 2>$null)
    if (-not $state) {
        Stop-Setup "Your instructor has not added '$user' to the class yet. Email your instructor your username, wait for confirmation, then run setup again."
    }

    # Accept the assignment (also accepts the org invitation)
    $out = (gh student accept $Cfg.Org $Cfg.Classroom $Cfg.Assignment 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -and $out -notmatch 'already accepted') {
        Write-Host $out
        Stop-Setup 'Accepting the course repository failed (message above).'
    }
    Write-OK "Course repository ready: $($Cfg.Org)/$($Cfg.Classroom)-$($Cfg.Assignment)-$user"
}

# -------------------------------------------------------------
#  SECTION 7 -- Repos (first update50), nbstripout, workspace, shortcut
# -------------------------------------------------------------
function Set-Repos {
    Write-Banner 'Downloading your course repository'

    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'update50.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $StudentRepo '.git'))) {
        Stop-Setup 'update50.ps1 could not download your repository.'
    }

    # Strip notebook output on commit
    & $PythonExe -m pip install --quiet nbstripout 2>&1 | Out-Null
    Push-Location $StudentRepo
    try { & $PythonExe -m nbstripout --install } finally { Pop-Location }
    Write-OK 'Notebook output stripping enabled'

    # Workspace file (ignored by .gitignore) and desktop shortcut
    $interp = Join-Path $AnacondaDir 'python.exe'
    $ws = [ordered]@{
        folders  = @(@{ path = '.' })
        settings = [ordered]@{
            'python.defaultInterpreterPath'              = $interp
            'python.terminal.activateEnvironment'        = $false
            'terminal.integrated.defaultProfile.windows' = 'PowerShell'
            'terminal.integrated.profiles.windows'       = @{ PowerShell = @{ path = $Pwsh } }
            'files.autoSave'                             = 'afterDelay'
            'files.autoSaveDelay'                        = 1000
            'notebook.lineNumbers'                       = 'on'
            'notebook.output.scrolling'                  = $true
            'git.autofetch'                              = $true
            'git.confirmSync'                            = $false
        }
    }
    [IO.File]::WriteAllText($Workspace, ($ws | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OIM3600.lnk'
    $sh  = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sh.TargetPath       = $CodeExe
    $sh.Arguments        = "`"$Workspace`""
    $sh.WorkingDirectory = $StudentRepo
    $sh.Description      = 'OIM 3600 - open the course workspace'
    $sh.IconLocation     = "$CodeExe,0"
    $sh.Save()
    Write-OK 'Desktop shortcut OIM3600 created'
}

# -------------------------------------------------------------
#  SECTION 8 -- Validate and finish
# -------------------------------------------------------------
function Complete-Setup {
    Write-Banner 'Checking the installation'
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'validate-env50.ps1')
    $ok = ($LASTEXITCODE -eq 0)

    Write-Banner ($(if ($ok) { 'SETUP COMPLETE' } else { 'SETUP FINISHED WITH PROBLEMS' }))
    if ($ok) {
        Write-Host '  Double-click the OIM3600 shortcut on your Desktop.' -ForegroundColor Green
        Write-Host '  Your course files are in student_repo. Work only there.' -ForegroundColor Green
    } else {
        Write-Host '  Some checks failed (see above). Email your instructor this log file:' -ForegroundColor Yellow
        Write-Host "    $LogFile" -ForegroundColor Yellow
    }
}

function Invoke-Configure {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Setup 'The configure stage must run in PowerShell 7.' }
    Update-SessionPath
    Install-Anaconda
    Set-ShellAndEditor
    Connect-GitHub
    Set-Repos
    Complete-Setup
}

# =============================================================
#  Stage control
# =============================================================

switch ($Stage) {

    'Main' {
        Write-Host ''
        Write-Host "  $($Cfg.CourseName)" -ForegroundColor White
        Write-Host "  $($Cfg.Term) setup" -ForegroundColor DarkGray

        Invoke-Preflight

        # Install stage: one Windows "Yes" prompt, waits until done.
        # Skipped on re-runs when everything is already installed.
        $needed = @($Pwsh, 'C:\Program Files\Git\cmd\git.exe',
                    'C:\Program Files\GitHub CLI\gh.exe', 'C:\Program Files\Microsoft VS Code\Code.exe') |
                  Where-Object { -not (Test-Path $_) }
        if ($needed) {
        Write-Host ''
        Write-Host '  Windows will now ask: "Do you want to allow this app to make changes?"' -ForegroundColor Yellow
        Write-Host '  Click YES. A second window opens and installs the software.' -ForegroundColor Yellow
        try {
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList `
                "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Stage Install"
        } catch {
            Stop-Setup 'Administrator permission was not given (you clicked No). Run setup again and click Yes.'
        }
        if ($p.ExitCode -ne 0) { Stop-Setup 'The software install did not finish. See the second window or the log in C:\ctap\logs.' }
        } else { Write-OK 'Software already installed' }

        # Configure stage: continue in PowerShell 7, same window, normal user.
        if (-not (Test-Path $Pwsh)) { Stop-Setup 'PowerShell 7 was not found after install.' }
        & $Pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Stage Configure
        $code = $LASTEXITCODE
        try { Stop-Transcript | Out-Null } catch { }
        exit $code
    }

    'Install' {
        Invoke-Install
        try { Stop-Transcript | Out-Null } catch { }
        exit 0
    }

    'Configure' {
        Invoke-Configure
        try { Stop-Transcript | Out-Null } catch { }
        exit 0
    }
}
