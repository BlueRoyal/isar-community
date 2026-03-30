#!/bin/bash
# ── Build isar-wasm for Flutter Web ──────────────────────────────────
#
# Produces the WASM binary + JS glue that Flutter/Dart loads at runtime.
#
# Prerequisites:
#   rustup target add wasm32-unknown-unknown
#   cargo install wasm-pack
#   (optional) cargo install wasm-opt   # for -O4 shrinking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀  Building isar-wasm …"

# ── 1. Check tooling ─────────────────────────────────────────────────

if ! command -v wasm-pack &>/dev/null; then
  echo "❌  wasm-pack not found.  Installing …"
  cargo install wasm-pack
fi

# ── 2. Clean ──────────────────────────────────────────────────────────

rm -rf pkg

# ── 3. Build for web (ES module, no bundler required) ─────────────────

echo "🌐  wasm-pack build --target web …"
wasm-pack build --target web --out-dir pkg --release -- --features default

# ── 4. Optional: optimise with wasm-opt ───────────────────────────────

if command -v wasm-opt &>/dev/null; then
  echo "⚡  Running wasm-opt -O4 …"
  wasm-opt -O4 \
    --enable-bulk-memory \
    --enable-nontrapping-float-to-int \
    pkg/isar_wasm_bg.wasm \
    -o pkg/isar_wasm_bg.wasm
else
  echo "⚠️   wasm-opt not found – skipping (install via: cargo install wasm-opt)"
fi

# ── 5. Print sizes ───────────────────────────────────────────────────

WASM_SIZE=$(wc -c < pkg/isar_wasm_bg.wasm | tr -d ' ')
WASM_KB=$((WASM_SIZE / 1024))
echo ""
echo "✅  Build complete!"
echo "    pkg/isar_wasm_bg.wasm  ${WASM_KB} KB"
echo "    pkg/isar_wasm.js       $(wc -c < pkg/isar_wasm.js | tr -d ' ') bytes"
echo ""
echo "📋  Next steps:"
echo "    1. Copy pkg/ into your Flutter project's web/ directory"
echo "    2. Reference it from index.html  (see README)"
