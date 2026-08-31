# Rebuilds the BeatNet + Librosa analyzer environment from scratch.
#
# Requirements:
#   * Python 3.9 (BeatNet's stack pins numpy<1.24 and numba 0.56, which do not
#     have wheels for newer Pythons).
#   * Visual Studio Build Tools with the C++ workload and a Windows SDK.
#     madmom -- which BeatNet uses for DBN beat decoding -- has no pure-Python
#     wheel and is compiled from Cython sources here.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools\setup_fusion_env.ps1

$ErrorActionPreference = "Stop"

$root   = Split-Path -Parent $PSScriptRoot
$venv   = Join-Path $PSScriptRoot ".venv-fusion"
$python = "$env:LOCALAPPDATA\Programs\Python\Python39\python.exe"

if (-not (Test-Path $python)) {
    $found = & py -3.9 -c "import sys; print(sys.executable)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $found) { $python = $found }
    else { throw "Python 3.9 not found. Install it, then re-run this script." }
}

Write-Host "Using interpreter: $python"
if (Test-Path $venv) {
    Write-Host "Removing existing venv at $venv"
    Remove-Item $venv -Recurse -Force
}

& $python -m venv $venv
$vpy = Join-Path $venv "Scripts\python.exe"

# setuptools is pinned below 70 because madmom 0.16.1's setup.py still relies
# on distutils behaviour that newer setuptools removed.
& $vpy -m pip install --upgrade "pip==24.0" "setuptools<70" "wheel"

# Numeric base first: madmom compiles against whichever numpy is installed,
# so it has to be in place before madmom is built.
& $vpy -m pip install "numpy==1.23.5" "cython==0.29.37" "scipy==1.10.1" "mido==1.2.10"

# --no-build-isolation so the build sees the numpy/Cython just installed.
& $vpy -m pip install --no-build-isolation "madmom==0.16.1"

& $vpy -m pip install "librosa==0.10.2.post1" "numba==0.56.4" "llvmlite==0.39.1" `
    "soundfile==0.12.1" "soxr==0.3.7" "audioread==3.0.1" "pooch==1.8.2" `
    "scikit-learn==1.3.2" "joblib==1.4.2" "decorator==5.1.1" "lazy_loader==0.4" `
    "msgpack==1.0.8" "typing_extensions==4.12.2"

& $vpy -m pip install "torch==2.5.1" --index-url https://download.pytorch.org/whl/cpu

# BeatNet imports matplotlib and pyaudio at module scope even for offline use.
& $vpy -m pip install "matplotlib==3.7.5" "pyaudio==0.2.14"

# --no-deps: BeatNet's own pins would pull an incompatible numpy back in.
& $vpy -m pip install --no-deps "BeatNet==1.1.3"

Write-Host ""
Write-Host "Verifying..."
& $vpy (Join-Path $PSScriptRoot "BeatmapAnalyzer.py") --selftest
