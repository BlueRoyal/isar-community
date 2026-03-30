// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member
//
// WASM-based database opening for isar_community web.
//
// Replaces the old JS/IndexedDB approach with a sqlite-wasm-rs backend
// loaded via a WASM module.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:isar_community/isar.dart';
import 'package:isar_community/src/common/schemas.dart';
import 'package:isar_community/src/web/bindings.dart';
import 'package:isar_community/src/web/isar_collection_impl.dart';
import 'package:isar_community/src/web/isar_impl.dart';
import 'package:isar_community/src/web/isar_web.dart';
import 'package:meta/meta.dart';

bool _wasmLoaded = false;

/// Load the isar-wasm ES module and initialise the WASM runtime.
///
/// Call this once before opening any Isar instance.  The WASM binary
/// (`isar_wasm_bg.wasm`) and JS glue (`isar_wasm.js`) must be served
/// from the application's `web/` directory.
///
/// [wasmUrl] allows overriding the default path (e.g. for CDN hosting).
Future<void> initializeIsarWeb([String? wasmUrl]) async {
  if (_wasmLoaded) return;

  final url = wasmUrl ?? 'isar_wasm.js';

  // Dynamically import the ES module produced by wasm-pack.
  // This works in modern browsers supporting <script type="module">.
  final module = await _importModule(url);
  if (module == null) {
    throw IsarError(
      'Failed to load isar-wasm module from "$url". '
      'Make sure the WASM build output (pkg/) is copied to your web/ directory.',
    );
  }

  // Call the default init() export which fetches & instantiates the .wasm
  final initFn = module.getProperty('default'.toJS);
  if (initFn != null) {
    final result = (initFn as JSFunction).callAsFunction();
    if (result is JSPromise) {
      await result.toDart;
    }
  }

  // Call isarInit() to set up panic hooks etc.
  isarInitJs();

  // Verify version compatibility
  final wasmVersion = isarVersion();
  if (wasmVersion != Isar.version) {
    throw IsarError(
      'Isar WASM version mismatch: Dart package expects ${Isar.version} '
      'but WASM module is $wasmVersion. '
      'Please rebuild the WASM module with the matching version.',
    );
  }

  _wasmLoaded = true;
}

/// Allows tests to skip the WASM loading step.
@visibleForTesting
void doNotInitializeIsarWeb() {
  _wasmLoaded = true;
}

/// Open an Isar database instance backed by WASM SQLite.
Future<Isar> openIsar({
  required List<CollectionSchema<dynamic>> schemas,
  String? directory,
  required String name,
  required int maxSizeMiB,
  required bool relaxedDurability,
  CompactCondition? compactOnLaunch,
}) async {
  await initializeIsarWeb();

  // Serialise schemas to JSON for the Rust side
  final schemasJson = getSchemas(schemas).map((e) => e.toJson());
  final schemasJsonStr = jsonEncode(schemasJson.toList());

  // Open the WASM-backed database
  final instance = openIsarJs(
    name.toJS,
    schemasJsonStr.toJS,
    relaxedDurability.toJS,
  );

  // Build the Dart-side Isar object
  final isar = IsarImpl(name, instance);
  final cols = <Type, IsarCollection<dynamic>>{};

  for (final schema in schemas) {
    schema.toCollection(<OBJ>() {
      schema as CollectionSchema<OBJ>;
      cols[OBJ] = IsarCollectionImpl<OBJ>(
        isar: isar,
        schema: schema,
      );
    });
  }

  isar.attachCollections(cols);
  return isar;
}

Isar openIsarSync({
  required List<CollectionSchema<dynamic>> schemas,
  String? directory,
  required String name,
  required int maxSizeMiB,
  required bool relaxedDurability,
  CompactCondition? compactOnLaunch,
}) =>
    unsupportedOnWeb();

FutureOr<void> initializeCoreBinary({
  Map<IsarAbi, String> libraries = const {},
  bool download = false,
}) =>
    unsupportedOnWeb();

// ── Helpers ──────────────────────────────────────────────────────────

/// Dynamically import an ES module via `import()`.
Future<JSObject?> _importModule(String url) async {
  try {
    // Use the browser's native dynamic import()
    final promise = globalContext.callMethod(
      'eval'.toJS,
      'import("$url")'.toJS,
    ) as JSPromise;
    final module = await promise.toDart;
    return module as JSObject?;
  } catch (e) {
    return null;
  }
}
