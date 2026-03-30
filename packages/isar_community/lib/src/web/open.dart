// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
import 'dart:html';
import 'dart:js_util' as js_util;

import 'package:isar_community/isar.dart';
import 'package:isar_community/src/common/schemas.dart';
import 'package:isar_community/src/web/bindings.dart';
import 'package:isar_community/src/web/isar_collection_impl.dart';
import 'package:isar_community/src/web/isar_impl.dart';
import 'package:isar_community/src/web/isar_web.dart';
import 'package:meta/meta.dart';

bool _wasmLoaded = false;

Future<void> initializeIsarWeb([String? wasmUrl]) async {
  if (_wasmLoaded) return;

  final url = wasmUrl ?? 'isar_wasm.js';

  // Load the ES module via a script tag
  final script = ScriptElement();
  script.type = 'module';
  // ignore: unsafe_html
  script.src = url;
  script.async = true;
  document.head!.append(script);

  try {
    await script.onLoad.first.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw IsarError(
          'Could not load Isar WASM module from "$url".\n'
          '\n'
          'Make sure you have run the setup command:\n'
          '  dart run isar_community_web:setup\n',
        );
      },
    );
  } catch (e) {
    throw IsarError(
      'Failed to load Isar WASM module: $e\n'
      '\n'
      'Run: dart run isar_community_web:setup',
    );
  }

  // Initialise the WASM runtime
  isarInitJs();

  // Verify version compatibility
  final wasmVersion = isarVersionJs();
  if (wasmVersion != Isar.version) {
    throw IsarError(
      'Isar WASM version mismatch: Dart package is ${Isar.version} '
      'but WASM module is $wasmVersion.\n'
      'Run: dart run isar_community_web:setup',
    );
  }

  _wasmLoaded = true;
}

@visibleForTesting
void doNotInitializeIsarWeb() {
  _wasmLoaded = true;
}

Future<Isar> openIsar({
  required List<CollectionSchema<dynamic>> schemas,
  String? directory,
  required String name,
  required int maxSizeMiB,
  required bool relaxedDurability,
  CompactCondition? compactOnLaunch,
}) async {
  await initializeIsarWeb();

  final schemasJson = getSchemas(schemas).map((e) => e.toJson());
  final schemasJsonStr = jsonEncode(schemasJson.toList());

  final instance = openIsarJs(name, schemasJsonStr, relaxedDurability);

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
