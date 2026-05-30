# Build bundled sidecar .exe (no Python needed on end-user PC).
# Requires Python 3.12+ on the BUILD machine only (CI or dev PC).

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

Write-Host "Installing Python deps..."
python -m pip install --upgrade pip
python -m pip install uv
uv sync --python 3.12
uv pip install pyinstaller

Write-Host "Building ocr-sidecar.exe..."
uv run pyinstaller scripts/ocr-sidecar.spec --noconfirm --distpath win/src-tauri/binaries --workpath win/.pyinstaller-build

$Built = Join-Path $Root "win\src-tauri\binaries\ocr-sidecar.exe"
if (-not (Test-Path $Built)) {
    throw "Sidecar build failed — ocr-sidecar.exe not found"
}

Write-Host "Built: $Built"
