// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member
//
// Collection implementation for WASM/web.
//
// Objects are serialised to/from JSON maps.  The WASM module handles
// the actual SQL execution.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:isar_community/isar.dart';
import 'package:isar_community/src/web/bindings.dart';
import 'package:isar_community/src/web/isar_impl.dart';
import 'package:isar_community/src/web/isar_web.dart';
import 'package:isar_community/src/web/query_build.dart';

class IsarCollectionImpl<OBJ> extends IsarCollection<OBJ> {
  IsarCollectionImpl({
    required this.isar,
    required this.schema,
  });

  @override
  final IsarImpl isar;

  @override
  final CollectionSchema<OBJ> schema;

  @override
  String get name => schema.name;

  late final _offsets = isar.offsets[OBJ]!;

  // ── Deserialisation ────────────────────────────────────────────────

  OBJ? _deserializeFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['_id'] as int;
    // Build an IsarReader-compatible object from the JSON map
    final reader = _JsonIsarReader(json, _offsets);
    return schema.deserialize(id, reader, _offsets, isar.offsets);
  }

  List<OBJ?> _deserializeList(List<dynamic> jsonList) {
    return jsonList.map((item) {
      if (item == null) return null;
      return _deserializeFromJson(item as Map<String, dynamic>);
    }).toList();
  }

  // ── Serialisation ──────────────────────────────────────────────────

  Map<String, dynamic> _serializeObj(OBJ object) {
    final writer = _JsonIsarWriter(_offsets, schema.properties);
    schema.serialize(object, writer, _offsets, isar.offsets);
    final map = writer.toMap();
    map['_id'] = schema.getId(object);
    return map;
  }

  // ── CRUD operations ────────────────────────────────────────────────

  @override
  Future<List<OBJ?>> getAll(List<Id> ids) {
    return isar.getTxn(false, (txn) async {
      final resultJson = isarGetAllJs(
        isar.instance,
        txn,
        name.toJS,
        jsonEncode(ids).toJS,
      ).toDart;

      final list = jsonDecode(resultJson) as List<dynamic>;
      return _deserializeList(list);
    });
  }

  @override
  Future<List<OBJ?>> getAllByIndex(String indexName, List<IndexKey> keys) {
    // Build SQL for index lookup
    return isar.getTxn(false, (txn) async {
      final results = <OBJ?>[];
      for (final key in keys) {
        final conditions = <String>[];
        final indexSchema = schema.indexes
            .firstWhere((idx) => idx.name == indexName);
        for (var i = 0; i < key.length && i < indexSchema.properties.length; i++) {
          final propName = indexSchema.properties[i].name;
          final value = key[i];
          if (value is String) {
            conditions.add('"$propName" = \'${_escapeSql(value)}\'');
          } else if (value == null) {
            conditions.add('"$propName" IS NULL');
          } else {
            conditions.add('"$propName" = $value');
          }
        }

        final sql =
            'SELECT _id, * FROM "$name" WHERE ${conditions.join(" AND ")} LIMIT 1;';
        final json = isarQueryJs(isar.instance, txn, sql.toJS).toDart;
        final list = jsonDecode(json) as List<dynamic>;
        results.add(list.isEmpty
            ? null
            : _deserializeFromJson(list[0] as Map<String, dynamic>));
      }
      return results;
    });
  }

  @override
  List<OBJ?> getAllSync(List<Id> ids) => unsupportedOnWeb();

  @override
  List<OBJ?> getAllByIndexSync(String indexName, List<IndexKey> keys) =>
      unsupportedOnWeb();

  @override
  Future<List<Id>> putAll(List<OBJ> objects) {
    return isar.getTxn(true, (txn) async {
      final serialized = objects.map(_serializeObj).toList();
      final resultJson = isarPutAllJs(
        isar.instance,
        txn,
        name.toJS,
        jsonEncode(serialized).toJS,
      ).toDart;

      final ids = (jsonDecode(resultJson) as List<dynamic>).cast<int>();

      // Attach ids back to objects
      for (var i = 0; i < objects.length; i++) {
        schema.attach(this, ids[i], objects[i]);
      }
      return ids;
    });
  }

  @override
  List<int> putAllSync(List<OBJ> objects, {bool saveLinks = true}) =>
      unsupportedOnWeb();

  @override
  Future<List<Id>> putAllByIndex(String? indexName, List<OBJ> objects) {
    // For WASM/SQLite, INSERT OR REPLACE handles upsert via UNIQUE indexes
    return putAll(objects);
  }

  @override
  List<Id> putAllByIndexSync(
    String indexName,
    List<OBJ> objects, {
    bool saveLinks = true,
  }) =>
      unsupportedOnWeb();

  @override
  Future<int> deleteAll(List<Id> ids) {
    return isar.getTxn(true, (txn) async {
      final count = isarDeleteAllJs(
        isar.instance,
        txn,
        name.toJS,
        jsonEncode(ids).toJS,
      );
      return count.toDartInt;
    });
  }

  @override
  Future<int> deleteAllByIndex(String indexName, List<IndexKey> keys) {
    return isar.getTxn(true, (txn) async {
      var totalDeleted = 0;
      for (final key in keys) {
        final conditions = <String>[];
        final indexSchema = schema.indexes
            .firstWhere((idx) => idx.name == indexName);
        for (var i = 0; i < key.length && i < indexSchema.properties.length; i++) {
          final propName = indexSchema.properties[i].name;
          final value = key[i];
          if (value is String) {
            conditions.add('"$propName" = \'${_escapeSql(value)}\'');
          } else if (value == null) {
            conditions.add('"$propName" IS NULL');
          } else {
            conditions.add('"$propName" = $value');
          }
        }
        final sql =
            'DELETE FROM "$name" WHERE ${conditions.join(" AND ")};';
        final count = isarDeleteQueryJs(isar.instance, txn, sql.toJS);
        totalDeleted += count.toDartInt;
      }
      return totalDeleted;
    });
  }

  @override
  int deleteAllSync(List<Id> ids) => unsupportedOnWeb();

  @override
  int deleteAllByIndexSync(String indexName, List<IndexKey> keys) =>
      unsupportedOnWeb();

  @override
  Future<void> clear() {
    return isar.getTxn(true, (txn) async {
      isarClearJs(isar.instance, txn, name.toJS);
    });
  }

  @override
  void clearSync() => unsupportedOnWeb();

  @override
  Future<void> importJson(List<Map<String, dynamic>> json) {
    return isar.getTxn(true, (txn) async {
      isarPutAllJs(
        isar.instance,
        txn,
        name.toJS,
        jsonEncode(json).toJS,
      );
    });
  }

  @override
  Future<void> importJsonRaw(Uint8List jsonBytes) {
    final json = jsonDecode(const Utf8Decoder().convert(jsonBytes)) as List;
    return importJson(json.cast());
  }

  @override
  void importJsonSync(List<Map<String, dynamic>> json) => unsupportedOnWeb();

  @override
  void importJsonRawSync(Uint8List jsonBytes) => unsupportedOnWeb();

  @override
  Future<int> count() => where().count();

  @override
  int countSync() => unsupportedOnWeb();

  @override
  Future<int> getSize({
    bool includeIndexes = false,
    bool includeLinks = false,
  }) =>
      unsupportedOnWeb();

  @override
  int getSizeSync({bool includeIndexes = false, bool includeLinks = false}) =>
      unsupportedOnWeb();

  // ── Watch (stub – requires polling or SQLite hooks) ────────────────

  @override
  Stream<void> watchLazy({bool fireImmediately = false}) {
    // TODO: Implement via polling or SQLite update hooks
    return const Stream.empty();
  }

  @override
  Stream<OBJ?> watchObject(
    Id id, {
    bool fireImmediately = false,
    bool deserialize = true,
  }) {
    // TODO: Implement via polling
    return const Stream.empty();
  }

  @override
  Stream<void> watchObjectLazy(Id id, {bool fireImmediately = false}) =>
      watchObject(id, deserialize: false).map((_) {});

  // ── Query builder ──────────────────────────────────────────────────

  @override
  Query<T> buildQuery<T>({
    List<WhereClause> whereClauses = const [],
    bool whereDistinct = false,
    Sort whereSort = Sort.asc,
    FilterOperation? filter,
    List<SortProperty> sortBy = const [],
    List<DistinctProperty> distinctBy = const [],
    int? offset,
    int? limit,
    String? property,
  }) {
    return buildWebQuery(
      this,
      whereClauses,
      whereDistinct,
      whereSort,
      filter,
      sortBy,
      distinctBy,
      offset,
      limit,
      property,
    );
  }

  @override
  Future<void> verify(List<OBJ> objects) => unsupportedOnWeb();

  @override
  Future<void> verifyLink(
    String linkName,
    List<int> sourceIds,
    List<int> targetIds,
  ) =>
      unsupportedOnWeb();
}

// ── Helpers ──────────────────────────────────────────────────────────

String _escapeSql(String value) => value.replaceAll("'", "''");

// ── Lightweight IsarReader/IsarWriter over JSON maps ─────────────────

/// Reads property values from a JSON map by offset.
///
/// The offset list maps property indices to the JSON map.  We use
/// the property name from the schema to look up values.
class _JsonIsarReader implements IsarReader {
  _JsonIsarReader(this._map, this._offsets);

  final Map<String, dynamic> _map;
  final List<int> _offsets;

  dynamic _get(int offset) {
    // offset is the property index – we need the property name
    // For simplicity, iterate through map keys (ordered in schema order)
    final keys = _map.keys.where((k) => k != '_id').toList();
    if (offset < keys.length) {
      return _map[keys[offset]];
    }
    return null;
  }

  @override
  bool readBool(int offset) => (_get(offset) as num?)?.toInt() == 1;

  @override
  bool? readBoolOrNull(int offset) {
    final v = _get(offset);
    if (v == null) return null;
    return (v as num).toInt() == 1;
  }

  @override
  int readByte(int offset) => (_get(offset) as num?)?.toInt() ?? 0;

  @override
  int readInt(int offset) => (_get(offset) as num?)?.toInt() ?? -2147483648;

  @override
  int? readIntOrNull(int offset) => (_get(offset) as num?)?.toInt();

  @override
  double readFloat(int offset) =>
      (_get(offset) as num?)?.toDouble() ?? double.nan;

  @override
  double? readFloatOrNull(int offset) => (_get(offset) as num?)?.toDouble();

  @override
  int readLong(int offset) =>
      (_get(offset) as num?)?.toInt() ?? -9007199254740990;

  @override
  int? readLongOrNull(int offset) => (_get(offset) as num?)?.toInt();

  @override
  double readDouble(int offset) =>
      (_get(offset) as num?)?.toDouble() ?? double.nan;

  @override
  double? readDoubleOrNull(int offset) => (_get(offset) as num?)?.toDouble();

  @override
  DateTime readDateTime(int offset) {
    final ms = (_get(offset) as num?)?.toInt() ?? 0;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  DateTime? readDateTimeOrNull(int offset) {
    final v = _get(offset) as num?;
    if (v == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  }

  @override
  String readString(int offset) => _get(offset)?.toString() ?? '';

  @override
  String? readStringOrNull(int offset) => _get(offset)?.toString();

  @override
  Uint8List readByteList(int offset) {
    final list = _get(offset);
    if (list is List) return Uint8List.fromList(list.cast<int>());
    return Uint8List(0);
  }

  @override
  Uint8List? readByteListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) return Uint8List.fromList(list.cast<int>());
    return null;
  }

  @override
  List<bool> readBoolList(int offset) {
    final list = _get(offset);
    if (list is List) return list.cast<bool>();
    return [];
  }

  @override
  List<bool>? readBoolListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) return list.cast<bool>();
    return null;
  }

  @override
  List<int> readIntList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toInt()).toList();
    return [];
  }

  @override
  List<int>? readIntListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toInt()).toList();
    return null;
  }

  @override
  List<double> readFloatList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toDouble()).toList();
    return [];
  }

  @override
  List<double>? readFloatListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toDouble()).toList();
    return null;
  }

  @override
  List<int> readLongList(int offset) => readIntList(offset);

  @override
  List<int>? readLongListOrNull(int offset) => readIntListOrNull(offset);

  @override
  List<double> readDoubleList(int offset) => readFloatList(offset);

  @override
  List<double>? readDoubleListOrNull(int offset) =>
      readFloatListOrNull(offset);

  @override
  List<String> readStringList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => e.toString()).toList();
    return [];
  }

  @override
  List<String>? readStringListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => e.toString()).toList();
    return null;
  }

  @override
  List<DateTime> readDateTimeList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list
          .map((e) => DateTime.fromMillisecondsSinceEpoch((e as num).toInt()))
          .toList();
    }
    return [];
  }

  @override
  List<DateTime>? readDateTimeListOrNull(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list
          .map((e) => DateTime.fromMillisecondsSinceEpoch((e as num).toInt()))
          .toList();
    }
    return null;
  }
}

/// Writes property values to a JSON map for INSERT.
class _JsonIsarWriter implements IsarWriter {
  _JsonIsarWriter(this._offsets, this._properties);

  final List<int> _offsets;
  final List<PropertySchema<dynamic>> _properties;
  final Map<String, dynamic> _data = {};

  Map<String, dynamic> toMap() => _data;

  String? _nameForOffset(int offset) {
    if (offset < _properties.length) {
      return _properties[offset].name;
    }
    return null;
  }

  void _set(int offset, dynamic value) {
    final name = _nameForOffset(offset);
    if (name != null) {
      _data[name] = value;
    }
  }

  @override
  void writeBool(int offset, bool? value) =>
      _set(offset, value == null ? null : (value ? 1 : 0));

  @override
  void writeByte(int offset, int value) => _set(offset, value);

  @override
  void writeInt(int offset, int? value) => _set(offset, value);

  @override
  void writeFloat(int offset, double? value) => _set(offset, value);

  @override
  void writeLong(int offset, int? value) => _set(offset, value);

  @override
  void writeDouble(int offset, double? value) => _set(offset, value);

  @override
  void writeDateTime(int offset, DateTime? value) =>
      _set(offset, value?.millisecondsSinceEpoch);

  @override
  void writeString(int offset, String? value) => _set(offset, value);

  @override
  void writeByteList(int offset, Uint8List? value) =>
      _set(offset, value?.toList());

  @override
  void writeBoolList(int offset, List<bool>? value) => _set(offset, value);

  @override
  void writeIntList(int offset, List<int>? value) => _set(offset, value);

  @override
  void writeFloatList(int offset, List<double>? value) => _set(offset, value);

  @override
  void writeLongList(int offset, List<int>? value) => _set(offset, value);

  @override
  void writeDoubleList(int offset, List<double>? value) => _set(offset, value);

  @override
  void writeStringList(int offset, List<String>? value) => _set(offset, value);

  @override
  void writeDateTimeList(int offset, List<DateTime>? value) =>
      _set(offset, value?.map((d) => d.millisecondsSinceEpoch).toList());
}
