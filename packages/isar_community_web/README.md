# isar_community_web

Web support for [isar_community](https://github.com/isar-community/isar-community). Adds SQLite-backed Isar to Flutter Web via pre-built WASM binaries.

## Quick start

**1. Add both packages:**

```yaml
dependencies:
  isar_community: ^3.3.0
  isar_community_web: ^3.3.0
```

**2. Install WASM files:**

```bash
dart run isar_community_web:setup
```

**3. Done!** Use Isar as usual — web works automatically:

```dart
final isar = await Isar.open([UserSchema]);
```

## What `setup` does

The setup command copies two files into your `web/` directory:

- `isar_wasm.js` — JavaScript glue code
- `isar_wasm_bg.wasm` — SQLite compiled to WebAssembly

These are served alongside your Flutter app and loaded at runtime.

## Persistent storage (OPFS)

For data to survive page refreshes, add these headers to `web/index.html`:

```html
<meta http-equiv="Cross-Origin-Opener-Policy" content="same-origin" />
<meta http-equiv="Cross-Origin-Embedder-Policy" content="require-corp" />
```

Without them, Isar uses in-memory storage (data is lost on refresh).

## Re-running setup

Run `dart run isar_community_web:setup` again after:
- Updating `isar_community_web` to a new version
- Deleting your `web/` directory
- Running `flutter clean`

## How it works

```
pubspec.yaml
  └─ isar_community_web: ^3.3.0
       │
       ├─ dart run setup  →  copies .js + .wasm to web/
       │
       └─ isar_community (Dart)
            └─ lib/src/web/open.dart
                 └─ loads isar_wasm.js at runtime
                      └─ instantiates isar_wasm_bg.wasm
                           └─ SQLite in WebAssembly
                                └─ OPFS / memory storage
```

## Version compatibility

The WASM module version must match the Dart package version exactly.
If they don't match, Isar throws an error at startup with instructions.

## License

Apache-2.0
