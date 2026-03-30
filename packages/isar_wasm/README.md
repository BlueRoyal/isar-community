# Isar WASM — Web Support for isar_community v3

SQLite-backed WebAssembly module that brings `isar_community` to Flutter Web.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Flutter Web App (Dart)                         │
│                                                 │
│  isar_community package                         │
│    └── lib/src/web/                             │
│         ├── open.dart          ← loads WASM     │
│         ├── bindings.dart      ← JS interop     │
│         ├── isar_impl.dart     ← Isar instance  │
│         ├── isar_collection_impl.dart            │
│         └── query_build.dart   ← query → SQL    │
│                                                 │
├─────────────── dart:js_interop ─────────────────┤
│                                                 │
│  isar-wasm (this crate)                         │
│    ├── database.rs    ← open/close SQLite       │
│    ├── transaction.rs ← BEGIN/COMMIT/ROLLBACK   │
│    ├── collection.rs  ← CRUD (INSERT/SELECT/..) │
│    ├── query.rs       ← arbitrary SQL execution │
│    └── schema.rs      ← DDL from Isar schemas   │
│                                                 │
├─────────────── wasm-bindgen ────────────────────┤
│                                                 │
│  sqlite-wasm-rs                                 │
│    └── SQLite 3.x compiled to WASM              │
│         Storage: OPFS → memory fallback         │
└─────────────────────────────────────────────────┘
```

## How it works

1. **Dart calls `Isar.open()`** → conditional import selects `web/open.dart`
2. `open.dart` dynamically imports the ES module (`isar_wasm.js`)
3. The JS glue instantiates the `.wasm` binary and exposes Rust functions
4. `openIsar()` creates a SQLite database (OPFS-backed when available)
5. Collection schemas are translated to `CREATE TABLE` / `CREATE INDEX`
6. CRUD calls go through `dart:js_interop` → `wasm-bindgen` → SQLite
7. Queries are compiled to SQL on the Dart side and executed via WASM

## Prerequisites

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# WASM target
rustup target add wasm32-unknown-unknown

# wasm-pack
cargo install wasm-pack

# (optional) wasm-opt for size optimisation
cargo install wasm-opt
```

## Building

```bash
cd packages/isar_wasm
chmod +x build.sh
./build.sh
```

This produces `pkg/` with:
- `isar_wasm.js` — ES module glue
- `isar_wasm_bg.wasm` — the compiled WASM binary
- `isar_wasm.d.ts` — TypeScript definitions (for non-Dart consumers)

## Integration into Flutter Web

### 1. Copy build output

```bash
cp packages/isar_wasm/pkg/isar_wasm.js     your_flutter_app/web/
cp packages/isar_wasm/pkg/isar_wasm_bg.wasm your_flutter_app/web/
```

### 2. Update `web/index.html`

Add COOP/COEP headers for OPFS (SharedArrayBuffer) support:

```html
<head>
  <meta http-equiv="Cross-Origin-Opener-Policy" content="same-origin" />
  <meta http-equiv="Cross-Origin-Embedder-Policy" content="require-corp" />
</head>
```

### 3. Replace Dart web bindings

Copy the updated Dart files into the isar_community package:

```
packages/isar_community/lib/src/web/
  ├── bindings.dart              ← NEW (dart:js_interop)
  ├── open.dart                  ← NEW (WASM loading)
  ├── isar_impl.dart             ← NEW (WASM transactions)
  ├── isar_collection_impl.dart  ← NEW (JSON serialisation)
  ├── isar_web.dart              ← unchanged constants
  └── query_build.dart           ← NEW (SQL generation)
```

### 4. Use in your Flutter app

```dart
import 'package:isar_community/isar.dart';

void main() async {
  // On web, this loads the WASM module automatically
  final isar = await Isar.open(
    [UserSchema],
    name: 'myapp',
  );

  // Use exactly like native!
  await isar.writeTxn(() async {
    await isar.users.put(User()..name = 'Alice');
  });

  final users = await isar.users.where().findAll();
  print(users);
}
```

## Storage backends

| Backend | Browser support | Persistence | Performance |
|---------|----------------|-------------|-------------|
| OPFS    | Chrome 86+, Edge 86+, Firefox 111+, Safari 16.4+ | ✅ Survives refresh | Fast |
| Memory  | All browsers | ❌ Session only | Fastest |

The module tries OPFS first and falls back to in-memory automatically.

### Enabling OPFS

OPFS requires `SharedArrayBuffer`, which needs these HTTP headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without these headers, the module silently falls back to in-memory storage.

## Current limitations

- **Watch/Stream:** `watchLazy()`, `watchObject()`, and `watchQuery()` are
  stubs.  SQLite doesn't have native change notifications in WASM.
  A polling-based implementation is planned.
- **Sync operations:** `txnSync`, `writeTxnSync`, `putAllSync`, etc. throw
  `UnsupportedError` (same as the original web implementation).
- **OPFS deletion:** `close(deleteFromDisk: true)` doesn't yet remove OPFS
  files (requires async File System Access API calls).
- **Embedded objects:** Stored as JSON text columns.  Deep querying on
  embedded fields requires JSON SQL functions (SQLite 3.38+).

## File structure

```
packages/isar_wasm/
├── Cargo.toml              ← Rust crate config
├── build.sh                ← Build script
├── src/
│   ├── lib.rs              ← WASM entry point
│   ├── database.rs         ← SQLite open/close
│   ├── transaction.rs      ← BEGIN/COMMIT/ROLLBACK
│   ├── collection.rs       ← CRUD operations
│   ├── query.rs            ← SQL query execution
│   └── schema.rs           ← DDL generation from Isar schemas
└── pkg/                    ← Build output (after ./build.sh)
    ├── isar_wasm.js
    ├── isar_wasm_bg.wasm
    └── isar_wasm.d.ts
```

## Version compatibility

The WASM module version must match the Dart package version.  `open.dart`
verifies this at startup and throws `IsarError` on mismatch.

| isar_community | isar-wasm |
|----------------|-----------|
| 3.3.0          | 3.3.0     |

## License

Apache-2.0 — same as isar_community.
