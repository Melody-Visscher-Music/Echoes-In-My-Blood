# bootstrap_echoes.ps1 — installs prerequisites on a fresh PC, then runs setup_fusion_env.ps1
# Usage (from an ADMIN PowerShell):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\maike\Documents\Echoes In My Blood\tools\bootstrap_echoes.ps1"

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this from an Administrator PowerShell (Build Tools needs it)." }

$wg = @('-e','--source','winget','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}

# 1. Git (GitHub Desktop's built-in Git is not on PATH, so install the real one)
$gitExe = "$env:ProgramFiles\Git\cmd\git.exe"
if (-not (Get-Command git -ErrorAction SilentlyContinue) -and -not (Test-Path $gitExe)) {
    Write-Host "Installing Git" -ForegroundColor Cyan
    winget install --id Git.Git --silent @wg
    Update-SessionPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -and -not (Test-Path $gitExe)) { throw "Git install failed." }
} else {
    Write-Host "Git already installed" -ForegroundColor Green
}
Update-SessionPath

# 2. Python 3.9 (user scope, so it lands in %LOCALAPPDATA%\Programs\Python\Python39 like setup_fusion_env.ps1 expects)
$py39 = "$env:LOCALAPPDATA\Programs\Python\Python39\python.exe"
if (-not (Test-Path $py39)) {
    Write-Host "Installing Python 3.9" -ForegroundColor Cyan
    winget install --id Python.Python.3.9 --scope user --silent @wg
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path $py39)) { throw "Python 3.9 install failed." }
} else {
    Write-Host "Python 3.9 already installed" -ForegroundColor Green
}

# 3. Visual Studio Build Tools + C++ workload (includes the Windows SDK via --includeRecommended)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasMsvc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $hasMsvc) {
    Write-Host "Installing Visual Studio Build Tools (C++). This one takes a while..." -ForegroundColor Cyan
    winget install --id Microsoft.VisualStudio.2022.BuildTools @wg `
        --override "--wait --quiet --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $hasMsvc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (-not $hasMsvc) { throw "C++ Build Tools not detected after install. Reboot and re-run." }
} else {
    Write-Host "C++ Build Tools already installed" -ForegroundColor Green
}

# 4. Hand off to the real environment builder
Write-Host "Building the analyzer venv" -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "setup_fusion_env.ps1")
if ($LASTEXITCODE -ne 0) { throw "setup_fusion_env.ps1 failed (exit $LASTEXITCODE)." }

Write-Host "Echoes analyzer environment ready." -ForegroundColor Green