# Builds a standalone OcrReview.exe (requires the .NET 8 SDK on Windows).
# Usage:  pwsh ./build.ps1   (run from the windows/ folder)
$ErrorActionPreference = "Stop"

# Self-contained folder publish (most reliable for WPF + WinRT; no .NET install needed).
dotnet publish src/OcrReview.App/OcrReview.App.csproj `
    -c Release -r win-x64 --self-contained true `
    -o publish

Write-Host ""
Write-Host "Built: $(Resolve-Path publish/OcrReview.exe)  (run it from the publish folder)" -ForegroundColor Green
