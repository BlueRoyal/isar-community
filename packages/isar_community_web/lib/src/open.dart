// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member
//
// WASM-based database opening for isar_community web.
//
// The WASM binary must be present in the web/ directory.
// Run "dart run isar_community_web:setup" to install it.

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
/// This is called automatically when you open an Isar instance.
/// The WASM files must be in the web/ directory — install them with:
///
///   dart run isar_community_web:setup
///
Future<void> initializeIsarWeb([String? wasmUrl]) async {
  if (_wasmLoaded) return;

  final url = wasmUrl ?? 'isar_wasm.js';

  // Dynamically import the ES module produced by wasm-pack.
  final module = await _importModule(url);
  if (module == null) {
    throw IsarError(
      'Could not load Isar WASM module from "$url".\n'
      '\n'
      'Make sure you have run the setup command:\n'
      '\n'
      '  dart run isar_community_web:setup\n'
      '\n'
      'This copies the required WASM files to your web/ directory.\n'
      'If you have already run setup, check that isar_wasm.js and\n'
      'isar_wasm_bg.wasm are present in your project\'s web/ folder.',
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
      'Isar WASM version mismatch: Dart package is ${Isar.version} '
      'but WASM module is $wasmVersion.\n'
      '\n'
      'Run: dart run isar_community_web:setup\n'
      '\n'
      'This will update the WASM files in your web/ directory.',
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
