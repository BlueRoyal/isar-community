Diese Dateien werden automatisch vom Build-Prozess erstellt.

Fuehre aus (im isar-community Root):

  cd packages\isar_wasm
  .\package_assets.ps1

Das baut den WASM-Code und kopiert die Ergebnisse hierher:

  - isar_wasm.js        (JS-Glue)
  - isar_wasm_bg.wasm   (SQLite WASM Binary)

NICHT manuell bearbeiten!
