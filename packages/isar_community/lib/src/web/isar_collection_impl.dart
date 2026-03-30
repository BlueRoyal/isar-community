// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
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

  List<String> get _propertyNames =>
      schema.properties.keys.toList();

  // ── Deserialisation ────────────────────────────────────────────────

  OBJ? deserializeFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = (json['_id'] as num).toInt();
    final reader = _JsonIsarReader(json, _propertyNames);
    return schema.deserialize(id, reader, _offsets, isar.offsets);
  }

  List<OBJ?> deserializeList(List<dynamic> jsonList) {
    return jsonList.map((item) {
      if (item == null) return null;
      return deserializeFromJson(item as Map<String, dynamic>);
    }).toList();
  }

  // ── Serialisation ──────────────────────────────────────────────────

  Map<String, dynamic> _serializeObj(OBJ object) {
    final writer = _JsonIsarWriter(_propertyNames);
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
        isar.instance, txn, name, jsonEncode(ids),
      );
      final list = jsonDecode(resultJson) as List<dynamic>;
      return deserializeList(list);
    });
  }

  @override
  Future<List<OBJ?>> getAllByIndex(String indexName, List<IndexKey> keys) {
    return isar.getTxn(false, (txn) async {
      final results = <OBJ?>[];
      final idx = schema.indexes[indexName];
      if (idx == null) throw IsarError('Unknown index "$indexName"');

      for (final key in keys) {
        final conditions = <String>[];
        for (var i = 0; i < key.length && i < idx.properties.length; i++) {
          final propName = idx.properties[i].name;
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
            'SELECT * FROM "$name" WHERE ${conditions.join(" AND ")} LIMIT 1;';
        final json = isarQueryJs(isar.instance, txn, sql);
        final list = jsonDecode(json) as List<dynamic>;
        results.add(list.isEmpty
            ? null
            : deserializeFromJson(list[0] as Map<String, dynamic>));
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
        isar.instance, txn, name, jsonEncode(serialized),
      );
      final ids = (jsonDecode(resultJson) as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList();

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
      return isarDeleteAllJs(isar.instance, txn, name, jsonEncode(ids));
    });
  }

  @override
  Future<int> deleteAllByIndex(String indexName, List<IndexKey> keys) {
    return isar.getTxn(true, (txn) async {
      var totalDeleted = 0;
      final idx = schema.indexes[indexName];
      if (idx == null) throw IsarError('Unknown index "$indexName"');

      for (final key in keys) {
        final conditions = <String>[];
        for (var i = 0; i < key.length && i < idx.properties.length; i++) {
          final propName = idx.properties[i].name;
          final value = key[i];
          if (value is String) {
            conditions.add('"$propName" = \'${_escapeSql(value)}\'');
          } else if (value == null) {
            conditions.add('"$propName" IS NULL');
          } else {
            conditions.add('"$propName" = $value');
          }
        }
        final sql = 'DELETE FROM "$name" WHERE ${conditions.join(" AND ")};';
        totalDeleted += isarDeleteQueryJs(isar.instance, txn, sql);
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
      isarClearJs(isar.instance, txn, name);
    });
  }

  @override
  void clearSync() => unsupportedOnWeb();

  @override
  Future<void> importJson(List<Map<String, dynamic>> json) {
    return isar.getTxn(true, (txn) async {
      isarPutAllJs(isar.instance, txn, name, jsonEncode(json));
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

  @override
  Stream<void> watchLazy({bool fireImmediately = false}) {
    return const Stream.empty();
  }

  @override
  Stream<OBJ?> watchObject(
    Id id, {
    bool fireImmediately = false,
    bool deserialize = true,
  }) {
    return const Stream.empty();
  }

  @override
  Stream<void> watchObjectLazy(Id id, {bool fireImmediately = false}) =>
      watchObject(id, deserialize: false).map((_) {});

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

// ── IsarReader over JSON maps ────────────────────────────────────────

class _JsonIsarReader implements IsarReader {
  _JsonIsarReader(this._map, this._propertyNames);

  final Map<String, dynamic> _map;
  final List<String> _propertyNames;

  dynamic _get(int offset) {
    if (offset < _propertyNames.length) {
      return _map[_propertyNames[offset]];
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
  int? readByteOrNull(int offset) => (_get(offset) as num?)?.toInt();

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
  T? readObjectOrNull<T>(
    int offset,
    Deserialize<T> deserialize,
    Map<Type, List<int>> allOffsets,
  ) {
    final v = _get(offset);
    if (v == null) return null;
    if (v is Map<String, dynamic>) {
      // Embedded objects stored as JSON
      final reader = _JsonIsarReader(v, v.keys.toList());
      final offsets = allOffsets[T] ?? [];
      return deserialize(0, reader, offsets, allOffsets);
    }
    return null;
  }

  @override
  List<bool>? readBoolList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => e == true || e == 1).toList();
    return null;
  }

  @override
  List<bool?>? readBoolOrNullList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) => e == null ? null : (e == true || e == 1)).toList();
    }
    return null;
  }

  @override
  List<int>? readByteList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toInt()).toList();
    return null;
  }

  @override
  List<int>? readIntList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toInt()).toList();
    return null;
  }

  @override
  List<int?>? readIntOrNullList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) => e == null ? null : (e as num).toInt()).toList();
    }
    return null;
  }

  @override
  List<double>? readFloatList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => (e as num).toDouble()).toList();
    return null;
  }

  @override
  List<double?>? readFloatOrNullList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list
          .map((e) => e == null ? null : (e as num).toDouble())
          .toList();
    }
    return null;
  }

  @override
  List<int>? readLongList(int offset) => readIntList(offset);

  @override
  List<int?>? readLongOrNullList(int offset) => readIntOrNullList(offset);

  @override
  List<double>? readDoubleList(int offset) => readFloatList(offset);

  @override
  List<double?>? readDoubleOrNullList(int offset) =>
      readFloatOrNullList(offset);

  @override
  List<String>? readStringList(int offset) {
    final list = _get(offset);
    if (list is List) return list.map((e) => e.toString()).toList();
    return null;
  }

  @override
  List<String?>? readStringOrNullList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) => e?.toString()).toList();
    }
    return null;
  }

  @override
  List<DateTime>? readDateTimeList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list
          .map((e) => DateTime.fromMillisecondsSinceEpoch((e as num).toInt()))
          .toList();
    }
    return null;
  }

  @override
  List<DateTime?>? readDateTimeOrNullList(int offset) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) {
        if (e == null) return null;
        return DateTime.fromMillisecondsSinceEpoch((e as num).toInt());
      }).toList();
    }
    return null;
  }

  @override
  List<T>? readObjectList<T>(
    int offset,
    Deserialize<T> deserialize,
    Map<Type, List<int>> allOffsets,
    T defaultValue,
  ) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) {
        if (e is Map<String, dynamic>) {
          final reader = _JsonIsarReader(e, e.keys.toList());
          final offsets = allOffsets[T] ?? [];
          return deserialize(0, reader, offsets, allOffsets);
        }
        return defaultValue;
      }).toList();
    }
    return null;
  }

  @override
  List<T?>? readObjectOrNullList<T>(
    int offset,
    Deserialize<T> deserialize,
    Map<Type, List<int>> allOffsets,
  ) {
    final list = _get(offset);
    if (list is List) {
      return list.map((e) {
        if (e is Map<String, dynamic>) {
          final reader = _JsonIsarReader(e, e.keys.toList());
          final offsets = allOffsets[T] ?? [];
          return deserialize(0, reader, offsets, allOffsets);
        }
        return null;
      }).toList();
    }
    return null;
  }
}

// ── IsarWriter over JSON maps ────────────────────────────────────────

class _JsonIsarWriter implements IsarWriter {
  _JsonIsarWriter(this._propertyNames);

  final List<String> _propertyNames;
  final Map<String, dynamic> _data = {};

  Map<String, dynamic> toMap() => _data;

  String? _nameForOffset(int offset) {
    if (offset < _propertyNames.length) {
      return _propertyNames[offset];
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
  void writeObject<T>(
    int offset,
    Map<Type, List<int>> allOffsets,
    Serialize<T> serialize,
    T? value,
  ) {
    if (value == null) {
      _set(offset, null);
      return;
    }
    final objectOffsets = allOffsets[T] ?? [];
    final writer = _JsonIsarWriter(
      objectOffsets.map((e) => 'p$e').toList(),
    );
    serialize(value, writer, objectOffsets, allOffsets);
    _set(offset, writer.toMap());
  }

  @override
  void writeByteList(int offset, List<int>? values) => _set(offset, values);

  @override
  void writeBoolList(int offset, List<bool?>? values) => _set(offset, values);

  @override
  void writeIntList(int offset, List<int?>? values) => _set(offset, values);

  @override
  void writeFloatList(int offset, List<double?>? values) =>
      _set(offset, values);

  @override
  void writeLongList(int offset, List<int?>? values) => _set(offset, values);

  @override
  void writeDoubleList(int offset, List<double?>? values) =>
      _set(offset, values);

  @override
  void writeDateTimeList(int offset, List<DateTime?>? values) =>
      _set(offset, values?.map((d) => d?.millisecondsSinceEpoch).toList());

  @override
  void writeStringList(int offset, List<String?>? values) =>
      _set(offset, values);

  @override
  void writeObjectList<T>(
    int offset,
    Map<Type, List<int>> allOffsets,
    Serialize<T> serialize,
    List<T?>? values,
  ) {
    if (values == null) {
      _set(offset, null);
      return;
    }
    final objectOffsets = allOffsets[T] ?? [];
    final list = values.map((v) {
      if (v == null) return null;
      final writer = _JsonIsarWriter(
        objectOffsets.map((e) => 'p$e').toList(),
      );
      serialize(v, writer, objectOffsets, allOffsets);
      return writer.toMap();
    }).toList();
    _set(offset, list);
  }
}
