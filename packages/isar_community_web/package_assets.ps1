# ── package_assets.ps1 ───────────────────────────────────────────────
#
# Baut das WASM-Modul und kopiert die Ausgabe in das
# isar_community_web Package (assets/).
#
# Ausfuehren aus dem isar-community Root:
#   .\packages\isar_wasm\package_assets.ps1
#
# Danach sind die WASM-Dateien im Package enthalten und werden
# mit "dart run isar_community_web:setup" ins Flutter-Projekt kopiert.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IsarWasmDir = $ScriptDir  # packages/isar_wasm
$WebPackageDir = Join-Path (Split-Path -Parent $ScriptDir) "isar_community_web"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Build WASM + Package Assets" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Baue WASM ─────────────────────────────────────────────────────

Write-Host "[1/2] Baue WASM..." -ForegroundColor Yellow

Push-Location $IsarWasmDir

if (Test-Path "build.ps1") {
    & .\build.ps1
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Host "FEHLER: WASM Build fehlgeschlagen!" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "FEHLER: build.ps1 nicht gefunden in $IsarWasmDir" -ForegroundColor Red
    Pop-Location
    exit 1
}

Pop-Location

# ── 2. Kopiere in Package assets/ ────────────────────────────────────

Write-Host ""
Write-Host "[2/2] Kopiere nach isar_community_web/assets/..." -ForegroundColor Yellow

$AssetsDir = Join-Path $WebPackageDir "assets"
New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null

$pkgDir = Join-Path $IsarWasmDir "pkg"

$files = @("isar_wasm.js", "isar_wasm_bg.wasm")

foreach ($f in $files) {
    $source = Join-Path $pkgDir $f
    $target = Join-Path $AssetsDir $f

    if (Test-Path $source) {
        Copy-Item $source $target -Force
        $sizeKB = [math]::Round((Get-Item $source).Length / 1024)
        Write-Host "  $f ($sizeKB KB)" -ForegroundColor Green
    } else {
        Write-Host "  FEHLER: $source nicht gefunden!" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  Fertig! Assets aktualisiert in:" -ForegroundColor Green
Write-Host "  $AssetsDir" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Naechster Schritt: Package publishen oder committen" -ForegroundColor Cyan
Write-Host ""
