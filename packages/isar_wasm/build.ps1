# ── build.ps1 ────────────────────────────────────────────────────────
#
# Build-Skript fuer isar-wasm (Windows PowerShell)
#
# Voraussetzungen:
#   1. Rust installiert (rustup-init.exe von https://rustup.rs)
#   2. rustup target add wasm32-unknown-unknown
#   3. cargo install wasm-pack
#
# Ausfuehren:
#   cd packages\isar_wasm
#   .\build.ps1

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Isar WASM Build (Windows)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Toolchain pruefen ─────────────────────────────────────────────

Write-Host "[1/5] Pruefe Toolchain..." -ForegroundColor Yellow

# Rust
try {
    $rustVersion = & rustc --version 2>&1
    Write-Host "  Rust: $rustVersion" -ForegroundColor Green
} catch {
    Write-Host "  FEHLER: Rust nicht gefunden!" -ForegroundColor Red
    Write-Host "  Installiere von: https://rustup.rs" -ForegroundColor Red
    Write-Host "  (rustup-init.exe herunterladen und ausfuehren)" -ForegroundColor Red
    exit 1
}

# wasm-pack
try {
    $wasmPackVersion = & wasm-pack --version 2>&1
    Write-Host "  wasm-pack: $wasmPackVersion" -ForegroundColor Green
} catch {
    Write-Host "  wasm-pack nicht gefunden. Installiere..." -ForegroundColor Yellow
    & cargo install wasm-pack
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FEHLER: wasm-pack Installation fehlgeschlagen!" -ForegroundColor Red
        exit 1
    }
}

# WASM target
$targets = & rustup target list --installed 2>&1
if ($targets -notmatch "wasm32-unknown-unknown") {
    Write-Host "  WASM target fehlt. Installiere..." -ForegroundColor Yellow
    & rustup target add wasm32-unknown-unknown
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FEHLER: WASM target Installation fehlgeschlagen!" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  WASM target: wasm32-unknown-unknown" -ForegroundColor Green

Write-Host ""

# ── 2. Alte Builds aufraeumen ─────────────────────────────────────────

Write-Host "[2/5] Raeume alte Builds auf..." -ForegroundColor Yellow

if (Test-Path "pkg") {
    Remove-Item -Recurse -Force "pkg"
    Write-Host "  pkg/ entfernt" -ForegroundColor Gray
}

Write-Host ""

# ── 3. WASM bauen ────────────────────────────────────────────────────

Write-Host "[3/5] Baue WASM (--target web --release)..." -ForegroundColor Yellow
Write-Host "  Das kann beim ersten Mal einige Minuten dauern..." -ForegroundColor Gray
Write-Host ""

& wasm-pack build --target web --out-dir pkg --release

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  FEHLER: wasm-pack build fehlgeschlagen!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Haeufige Ursachen:" -ForegroundColor Yellow
    Write-Host "    - Visual Studio C++ Build Tools fehlen" -ForegroundColor Gray
    Write-Host "    - sqlite-wasm-rs API hat sich geaendert" -ForegroundColor Gray
    Write-Host "    - Netzwerkproblem beim Herunterladen von Crates" -ForegroundColor Gray
    exit 1
}

Write-Host ""

# ── 4. Optional: wasm-opt ────────────────────────────────────────────

Write-Host "[4/5] Optimierung..." -ForegroundColor Yellow

$wasmFile = "pkg\isar_wasm_bg.wasm"

try {
    $null = & wasm-opt --version 2>&1
    Write-Host "  wasm-opt gefunden, optimiere..." -ForegroundColor Gray

    & wasm-opt -O4 `
        --enable-bulk-memory `
        --enable-nontrapping-float-to-int `
        $wasmFile `
        -o $wasmFile

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Optimierung abgeschlossen" -ForegroundColor Green
    }
} catch {
    Write-Host "  wasm-opt nicht gefunden (optional)" -ForegroundColor Gray
    Write-Host "  Installieren mit: cargo install wasm-opt" -ForegroundColor Gray
}

Write-Host ""

# ── 5. Zusammenfassung ───────────────────────────────────────────────

Write-Host "[5/5] Ergebnis:" -ForegroundColor Yellow

if (Test-Path $wasmFile) {
    $wasmSize = (Get-Item $wasmFile).Length
    $wasmKB = [math]::Round($wasmSize / 1024)
    $jsFile = "pkg\isar_wasm.js"
    $jsSize = if (Test-Path $jsFile) { (Get-Item $jsFile).Length } else { 0 }

    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Green
    Write-Host "  Build erfolgreich!" -ForegroundColor Green
    Write-Host "  ==================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  pkg\isar_wasm_bg.wasm   $wasmKB KB" -ForegroundColor White
    Write-Host "  pkg\isar_wasm.js        $jsSize Bytes" -ForegroundColor White
    Write-Host ""
    Write-Host "  Naechste Schritte:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Kopiere die Build-Dateien in deine Flutter-App:" -ForegroundColor White
    Write-Host "     Copy-Item pkg\isar_wasm.js      ..\..\..\deine_app\web\" -ForegroundColor Gray
    Write-Host "     Copy-Item pkg\isar_wasm_bg.wasm ..\..\..\deine_app\web\" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. COOP/COEP Header in web\index.html einfuegen" -ForegroundColor White
    Write-Host "     (siehe README.md)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. flutter run -d chrome" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  WASM-Datei nicht gefunden!" -ForegroundColor Red
    Write-Host "  Pruefe die Build-Ausgabe oben auf Fehler." -ForegroundColor Red
    exit 1
}