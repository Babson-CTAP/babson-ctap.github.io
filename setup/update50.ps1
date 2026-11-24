# =============================================================
#  OIM 3600 - CTAP  ·  update50.ps1
#
#  Run at the start of every class, from the VS Code terminal:
#      ..\update50.ps1
#
#  1. Saves (commits + pushes) your work in student_repo
#  2. Downloads the latest course files into class_repo
#  3. Copies new and updated files into student_repo without
#     overwriting your work:
#       - new file            -> copied in
#       - only you changed it -> left alone
#       - only I changed it   -> updated
#       - we both changed it  -> my version keeps the name; yours is saved as
#                                name_student_YYYYMMDD_HHMM.ext
# =============================================================

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$startLocation = Get-Location

$root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg         = Get-Content (Join-Path $root 'ctap-config.json') -Raw | ConvertFrom-Json
$classRepo   = Join-Path $root 'class_repo'
$studentRepo = Join-Path $root 'student_repo'
$configFile  = Join-Path $root '.student_config.txt'

function Fail { param($msg) Write-Host "ERROR: $msg" -ForegroundColor Red; Set-Location $startLocation; exit 1 }

Write-Host ''
Write-Host '=== Course update ===' -ForegroundColor Cyan

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'GitHub CLI (gh) not found. Run setup50.ps1.' }

# ----------------------------------------------------------
# GitHub username: saved by setup, else ask GitHub
# ----------------------------------------------------------
$username = ''
if (Test-Path $configFile) { $username = (Get-Content $configFile -Raw).Trim() }
if (-not $username) {
    $username = (gh api user --jq .login 2>$null)
    if (-not $username) { Fail 'Not logged in to GitHub. Run setup50.ps1 again.' }
    $username = $username.Trim()
    Set-Content -Path $configFile -Value $username -Encoding ascii
}

$templateSlug = "$($cfg.Org)/$($cfg.TemplateRepo)"
$studentSlug  = "$($cfg.Org)/$($cfg.Classroom)-$($cfg.Assignment)-$username"
Write-Host "Course files: $templateSlug"
Write-Host "Your repo:    $studentSlug"

# ----------------------------------------------------------
# class_repo: clone once, then pull
# ----------------------------------------------------------
if (-not (Test-Path (Join-Path $classRepo '.git'))) {
    Write-Host 'Downloading course files (first time)...' -ForegroundColor Cyan
    gh repo clone $templateSlug $classRepo -- --quiet
    if ($LASTEXITCODE -ne 0) { Fail "Could not download $templateSlug." }
}
git -C $classRepo pull --quiet origin main
if ($LASTEXITCODE -ne 0) { Fail 'Could not update class_repo.' }

# ----------------------------------------------------------
# student_repo: clone once
# ----------------------------------------------------------
if (-not (Test-Path (Join-Path $studentRepo '.git'))) {
    Write-Host 'Downloading your repository (first time)...' -ForegroundColor Cyan
    if (Test-Path $studentRepo) {
        # Folder exists without git: clone beside it and move .git in
        $tmp = "$studentRepo-tmp"
        gh repo clone $studentSlug $tmp -- --quiet
        if ($LASTEXITCODE -ne 0) { Fail "Could not download $studentSlug." }
        Move-Item (Join-Path $tmp '.git') $studentRepo
        Remove-Item $tmp -Recurse -Force
        git -C $studentRepo checkout -- . 2>$null
    } else {
        gh repo clone $studentSlug $studentRepo -- --quiet
        if ($LASTEXITCODE -ne 0) { Fail "Could not download $studentSlug." }
    }
}

$origin = git -C $studentRepo remote get-url origin
if ($origin -notmatch [regex]::Escape($cfg.Org)) { Fail "student_repo is not connected to $($cfg.Org) (origin: $origin)." }
if (-not (git -C $studentRepo remote | Select-String '^upstream$')) {
    git -C $studentRepo remote add upstream "https://github.com/$templateSlug.git"
}

# ----------------------------------------------------------
# Save the student's work before changing anything
# ----------------------------------------------------------
Write-Host 'Saving your work...' -ForegroundColor Cyan
git -C $studentRepo add -A 2>$null | Out-Null
git -C $studentRepo commit --quiet -m "Save before update ($(Get-Date -Format 'yyyy-MM-dd'))" 2>$null | Out-Null
git -C $studentRepo push --quiet origin main 2>$null | Out-Null

# ----------------------------------------------------------
# Safe file sync (hash + last-instructor state)
# ----------------------------------------------------------
Write-Host 'Applying course updates...' -ForegroundColor Cyan

$excludeNames = @('.git', '.github', '.devcontainer', '.venv', 'venv', 'env', '__pycache__', '.DS_Store', 'Thumbs.db')
function Is-Excluded([string]$rel) {
    foreach ($n in $excludeNames) {
        if ($rel -eq $n -or $rel -like "$n\*" -or $rel -like "*\$n\*") { return $true }
    }
    return $false
}
function Get-Hash([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

# hw.py -> hw_student_20261124_1128.py ; README -> README_student_20261124_1128
function Get-StudentCopyName([string]$path, [string]$stamp) {
    $dir  = Split-Path $path -Parent
    $name = Split-Path $path -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [IO.Path]::GetExtension($name)
    if (-not $base) { $base = $name; $ext = '' }          # e.g. .gitignore
    $candidate = Join-Path $dir "$($base)_student_$stamp$ext"
    $n = 2
    while (Test-Path -LiteralPath $candidate) {           # two conflicts in the same minute
        $candidate = Join-Path $dir "$($base)_student_$($stamp)_$n$ext"; $n++
    }
    return $candidate
}

$stateDir = Join-Path $env:USERPROFILE '.ctap'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$stateFile = Join-Path $stateDir "sync_state.$($cfg.Org).$($cfg.Classroom).$username.json"

$state = @{}
if (Test-Path $stateFile) {
    try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-Host 'WARNING: could not read sync state; treating as first sync.' -ForegroundColor Yellow; $state = @{} }
}

$new = @(); $updated = @(); $conflicts = @()
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

Get-ChildItem -LiteralPath $classRepo -Recurse -File -Force | ForEach-Object {
    $src = $_.FullName
    $rel = $src.Substring($classRepo.Length + 1)
    if (Is-Excluded $rel) { return }

    $dest    = Join-Path $studentRepo $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $srcHash = Get-Hash $src
    if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $state[$rel] = $srcHash; $new += $rel; return
    }

    $destHash = Get-Hash $dest
    $last = if ($state.ContainsKey($rel)) { $state[$rel] } else { $null }

    if ($destHash -eq $srcHash) { $state[$rel] = $srcHash; return }       # identical
    if ($last -and $srcHash -eq $last) { return }                         # only student changed it
    if ($last -and $destHash -eq $last) {                                 # only instructor changed it
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $state[$rel] = $srcHash; $updated += $rel; return
    }

    # both changed: instructor version keeps the name, student copy renamed
    $backup = Get-StudentCopyName $dest $stamp
    Move-Item -LiteralPath $dest -Destination $backup -Force
    Copy-Item -LiteralPath $src -Destination $dest -Force
    $state[$rel] = $srcHash
    $conflicts += [pscustomobject]@{ File = $rel; Saved = $backup.Substring($studentRepo.Length + 1) }
}

($state | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $stateFile -Encoding UTF8

# Commit the update so student_repo stays clean
git -C $studentRepo add -A 2>$null | Out-Null
git -C $studentRepo commit --quiet -m "Course update ($(Get-Date -Format 'yyyy-MM-dd'))" 2>$null | Out-Null
git -C $studentRepo push --quiet origin main 2>$null | Out-Null

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
Write-Host ''
Write-Host '=== Update summary ===' -ForegroundColor Cyan
if ($new.Count)     { Write-Host 'New:' -ForegroundColor Green;      $new     | ForEach-Object { Write-Host "  + $_" } }
if ($updated.Count) { Write-Host 'Updated:' -ForegroundColor Yellow; $updated | ForEach-Object { Write-Host "  ~ $_" } }
if ($conflicts.Count) {
    Write-Host 'Both you and your instructor changed these files:' -ForegroundColor Red
    $conflicts | ForEach-Object {
        Write-Host "  ! $($_.File) is now the instructor's version." -ForegroundColor Red
        Write-Host "    Your version was saved as $($_.Saved)" -ForegroundColor Red
    }
}
if (-not ($new.Count + $updated.Count + $conflicts.Count)) { Write-Host 'No changes.' -ForegroundColor Gray }

Set-Location $startLocation
Write-Host ''
Write-Host 'Update complete.' -ForegroundColor Green
Write-Host ''
exit 0
