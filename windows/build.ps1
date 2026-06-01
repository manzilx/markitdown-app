# Builds a standalone OcrReview.exe (requires the .NET 8 SDK on Windows).
# Usage:  pwsh ./build.ps1   (run from the windows/ folder)
$ErrorActionPreference = "Stop"

dotnet publish src/OcrReview.App/OcrReview.App.csproj `
    -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -o publish

Write-Host ""
Write-Host "Built: $(Resolve-Path publish/OcrReview.exe)" -ForegroundColor Green
