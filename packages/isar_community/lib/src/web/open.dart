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
  // Wait for sql.js to be ready (Promise stored on window by index.html)
  final readyPromise = js_util.getProperty(window, '_isarReady');
  if (readyPromise != null) {
    await js_util.promiseToFuture(readyPromise);
  } else {
    // Fallback: wait briefly for scripts loaded in index.html
    for (var i = 0; i < 100; i++) {
      if (js_util.hasProperty(window, 'isarInit')) break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
  if (!js_util.hasProperty(window, 'isarInit')) {
    throw IsarError(
      'Isar Web not found. Add isar_wasm.js and sql.js to web/index.html.\n'
      '\n'
      'Required in web/index.html before Flutter bootstrap:\n'
      '  <script src="https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.11.0/sql-wasm.js"></script>\n'
      '  <script>\n'
      '    window._isarReady = initSqlJs({\n'
      '      locateFile: function(f) {\n'
      '        return "https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.11.0/" + f;\n'
      '      }\n'
      '    }).then(function(sql) { window._isarSql = sql; });\n'
      '  </script>\n'
      '  <script src="isar_wasm.js"></script>',
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
      'Update isar_wasm.js to match.',
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

      // Register property offsets for this collection type
      isar.offsets[OBJ] =
          List<int>.generate(schema.properties.length, (i) => i);

      // Register offsets for embedded schemas used by this collection
      for (final embedded in schema.embeddedSchemas.values) {
        isar.offsets[embedded.type] =
            List<int>.generate(embedded.properties.length, (i) => i);
      }

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
