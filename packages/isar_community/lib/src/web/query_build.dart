// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:isar_community/isar.dart';
import 'package:isar_community/src/web/bindings.dart';
import 'package:isar_community/src/web/isar_collection_impl.dart';
import 'package:isar_community/src/web/isar_impl.dart';
import 'package:isar_community/src/web/isar_web.dart';

Query<T> buildWebQuery<T, OBJ>(
  IsarCollectionImpl<OBJ> collection,
  List<WhereClause> whereClauses,
  bool whereDistinct,
  Sort whereSort,
  FilterOperation? filter,
  List<SortProperty> sortBy,
  List<DistinctProperty> distinctBy,
  int? offset,
  int? limit,
  String? property,
) {
  return _WasmQuery<T, OBJ>(
    collection: collection,
    whereClauses: whereClauses,
    whereDistinct: whereDistinct,
    whereSort: whereSort,
    filter: filter,
    sortBy: sortBy,
    distinctBy: distinctBy,
    offset: offset,
    limit: limit,
    property: property,
  );
}

class _WasmQuery<T, OBJ> extends Query<T> {
  _WasmQuery({
    required this.collection,
    required this.whereClauses,
    required this.whereDistinct,
    required this.whereSort,
    required this.filter,
    required this.sortBy,
    required this.distinctBy,
    required this.offset,
    required this.limit,
    required this.property,
  });

  final IsarCollectionImpl<OBJ> collection;
  final List<WhereClause> whereClauses;
  final bool whereDistinct;
  final Sort whereSort;
  final FilterOperation? filter;
  final List<SortProperty> sortBy;
  final List<DistinctProperty> distinctBy;
  final int? offset;
  final int? limit;
  final String? property;

  @override
  Isar get isar => collection.isar;

  IsarImpl get _isar => collection.isar;
  String get tableName => collection.name;

  // ── SQL generation ─────────────────────────────────────────────────

  String _buildSelectSql({String select = '*'}) {
    final buf = StringBuffer('SELECT $select FROM "$tableName"');

    final conditions = _buildWhereConditions();
    if (conditions.isNotEmpty) {
      buf.write(' WHERE ${conditions.join(" AND ")}');
    }

    final orderParts = <String>[];
    if (sortBy.isNotEmpty) {
      for (final sort in sortBy) {
        final dir = sort.sort == Sort.asc ? 'ASC' : 'DESC';
        orderParts.add('"${sort.property}" $dir');
      }
    } else {
      final dir = whereSort == Sort.asc ? 'ASC' : 'DESC';
      orderParts.add('_id $dir');
    }
    buf.write(' ORDER BY ${orderParts.join(", ")}');

    if (limit != null) buf.write(' LIMIT $limit');
    if (offset != null) buf.write(' OFFSET $offset');

    buf.write(';');
    return buf.toString();
  }

  List<String> _buildWhereConditions() {
    final conditions = <String>[];

    for (final wc in whereClauses) {
      if (wc is IdWhereClause) {
        if (wc.lower != null) {
          final op = wc.includeLower ? '>=' : '>';
          conditions.add('_id $op ${wc.lower}');
        }
        if (wc.upper != null) {
          final op = wc.includeUpper ? '<=' : '<';
          conditions.add('_id $op ${wc.upper}');
        }
      } else if (wc is IndexWhereClause) {
        final idx = collection.schema.indexes[wc.indexName];
        if (idx != null) {
          if (wc.lower != null) {
            for (var i = 0; i < wc.lower!.length && i < idx.properties.length; i++) {
              final propName = idx.properties[i].name;
              final value = wc.lower![i];
              final op = wc.includeLower ? '>=' : '>';
              conditions.add(_formatValueCondition(propName, op, value));
            }
          }
          if (wc.upper != null) {
            for (var i = 0; i < wc.upper!.length && i < idx.properties.length; i++) {
              final propName = idx.properties[i].name;
              final value = wc.upper![i];
              final op = wc.includeUpper ? '<=' : '<';
              conditions.add(_formatValueCondition(propName, op, value));
            }
          }
        }
      }
      // LinkWhereClause handled via subquery if needed
    }

    if (filter != null) {
      final filterSql = _filterToSql(filter!);
      if (filterSql.isNotEmpty) {
        conditions.add(filterSql);
      }
    }

    return conditions;
  }

  String _formatValueCondition(String propName, String op, dynamic value) {
    if (value is String) {
      return '"$propName" $op \'${_escapeSql(value)}\'';
    } else if (value == null) {
      return '"$propName" IS NULL';
    } else {
      return '"$propName" $op $value';
    }
  }

  String _filterToSql(FilterOperation filter) {
    if (filter is FilterGroup) {
      if (filter.type == FilterGroupType.not) {
        if (filter.filters.isEmpty) return '';
        final inner = _filterToSql(filter.filters.first);
        return inner.isEmpty ? '' : 'NOT ($inner)';
      }
      final parts = filter.filters
          .map(_filterToSql)
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isEmpty) return '';
      final joiner = filter.type == FilterGroupType.and ? ' AND ' : ' OR ';
      return '(${parts.join(joiner)})';
    } else if (filter is FilterCondition) {
      return _conditionToSql(filter);
    } else if (filter is ObjectFilter) {
      // Embedded object filters — apply to JSON column
      return _filterToSql(filter.filter);
    }
    return '';
  }

  String _conditionToSql(FilterCondition cond) {
    final prop = '"${cond.property}"';

    switch (cond.type) {
      case FilterConditionType.equalTo:
        if (cond.value1 == null) return '$prop IS NULL';
        return '$prop = ${_sqlValue(cond.value1)}';
      case FilterConditionType.greaterThan:
        final op = cond.include1 ? '>=' : '>';
        return '$prop $op ${_sqlValue(cond.value1)}';
      case FilterConditionType.lessThan:
        final op = cond.include1 ? '<=' : '<';
        return '$prop $op ${_sqlValue(cond.value1)}';
      case FilterConditionType.between:
        final lower = _sqlValue(cond.value1);
        final upper = _sqlValue(cond.value2);
        return '$prop BETWEEN $lower AND $upper';
      case FilterConditionType.startsWith:
        return '$prop LIKE \'${_escapeSql(cond.value1.toString())}%\'';
      case FilterConditionType.endsWith:
        return '$prop LIKE \'%${_escapeSql(cond.value1.toString())}\'';
      case FilterConditionType.contains:
        return '$prop LIKE \'%${_escapeSql(cond.value1.toString())}%\'';
      case FilterConditionType.matches:
        final pattern = cond.value1
            .toString()
            .replaceAll('*', '%')
            .replaceAll('?', '_');
        return '$prop LIKE \'${_escapeSql(pattern)}\'';
      case FilterConditionType.isNull:
        return '$prop IS NULL';
      case FilterConditionType.isNotNull:
        return '$prop IS NOT NULL';
      case FilterConditionType.elementIsNull:
        return '$prop LIKE \'%null%\'';
      case FilterConditionType.elementIsNotNull:
        return '$prop IS NOT NULL';
      case FilterConditionType.listLength:
        // Approximate: JSON array length
        return 'json_array_length($prop) BETWEEN ${cond.value1} AND ${cond.value2}';
    }
  }

  String _sqlValue(dynamic value) {
    if (value == null) return 'NULL';
    if (value is String) return '\'${_escapeSql(value)}\'';
    if (value is DateTime) return '${value.millisecondsSinceEpoch}';
    return value.toString();
  }

  // ── Query execution ────────────────────────────────────────────────

  @override
  Future<T?> findFirst() {
    return _isar.getTxn(false, (txn) async {
      final sql = _buildSelectSql().replaceFirst(';', ' LIMIT 1;');
      final json = isarQueryJs(_isar.instance, txn, sql);
      final list = jsonDecode(json) as List<dynamic>;
      if (list.isEmpty) return null;
      return collection.deserializeFromJson(
        list[0] as Map<String, dynamic>,
      ) as T?;
    });
  }

  @override
  T? findFirstSync() => unsupportedOnWeb();

  @override
  Future<List<T>> findAll() {
    return _isar.getTxn(false, (txn) async {
      final sql = _buildSelectSql();
      final json = isarQueryJs(_isar.instance, txn, sql);
      final list = jsonDecode(json) as List<dynamic>;

      if (property != null) {
        return list.map((row) {
          final map = row as Map<String, dynamic>;
          return map[property] as T;
        }).toList();
      }

      return list.map((item) {
        return collection.deserializeFromJson(
          item as Map<String, dynamic>,
        ) as T;
      }).toList();
    });
  }

  @override
  List<T> findAllSync() => unsupportedOnWeb();

  @override
  Future<bool> deleteFirst() {
    return _isar.getTxn(true, (txn) async {
      final selectSql = _buildSelectSql(select: '_id')
          .replaceFirst(';', ' LIMIT 1;');
      final json = isarQueryJs(_isar.instance, txn, selectSql);
      final list = jsonDecode(json) as List<dynamic>;
      if (list.isEmpty) return false;
      final id = (list[0] as Map<String, dynamic>)['_id'];
      final deleteSql = 'DELETE FROM "$tableName" WHERE _id = $id;';
      final count = isarDeleteQueryJs(_isar.instance, txn, deleteSql);
      return count > 0;
    });
  }

  @override
  bool deleteFirstSync() => unsupportedOnWeb();

  @override
  Future<int> deleteAll() {
    return _isar.getTxn(true, (txn) async {
      final conditions = _buildWhereConditions();
      final where =
          conditions.isEmpty ? '' : ' WHERE ${conditions.join(" AND ")}';
      final sql = 'DELETE FROM "$tableName"$where;';
      return isarDeleteQueryJs(_isar.instance, txn, sql);
    });
  }

  @override
  int deleteAllSync() => unsupportedOnWeb();

  // ── Aggregates ─────────────────────────────────────────────────────

  @override
  Future<R?> aggregate<R>(AggregationOp op) {
    return _isar.getTxn(false, (txn) async {
      final conditions = _buildWhereConditions();
      final where =
          conditions.isEmpty ? '' : ' WHERE ${conditions.join(" AND ")}';

      late final String sql;
      switch (op) {
        case AggregationOp.count:
          sql = 'SELECT COUNT(*) as v FROM "$tableName"$where;';
          break;
        case AggregationOp.isEmpty:
          sql = 'SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END as v FROM "$tableName"$where;';
          break;
        case AggregationOp.min:
          sql = 'SELECT MIN("${property ?? "_id"}") as v FROM "$tableName"$where;';
          break;
        case AggregationOp.max:
          sql = 'SELECT MAX("${property ?? "_id"}") as v FROM "$tableName"$where;';
          break;
        case AggregationOp.sum:
          sql = 'SELECT SUM("${property ?? "_id"}") as v FROM "$tableName"$where;';
          break;
        case AggregationOp.average:
          sql = 'SELECT AVG("${property ?? "_id"}") as v FROM "$tableName"$where;';
          break;
      }

      final json = isarAggregateJs(_isar.instance, txn, sql);
      final value = jsonDecode(json);
      if (value == null) return null;

      if (R == int) return (value as num).toInt() as R;
      if (R == double) return (value as num).toDouble() as R;
      if (R == DateTime) {
        return DateTime.fromMillisecondsSinceEpoch((value as num).toInt()) as R;
      }
      return value as R?;
    });
  }

  @override
  R? aggregateSync<R>(AggregationOp op) => unsupportedOnWeb();

  // ── Export ─────────────────────────────────────────────────────────

  @override
  Future<R> exportJsonRaw<R>(R Function(Uint8List) callback) {
    return _isar.getTxn(false, (txn) async {
      final sql = _buildSelectSql();
      final json = isarQueryJs(_isar.instance, txn, sql);
      final bytes = Uint8List.fromList(utf8.encode(json));
      return callback(bytes);
    });
  }

  @override
  R exportJsonRawSync<R>(R Function(Uint8List) callback) =>
      unsupportedOnWeb();

  // ── Watch (stub) ───────────────────────────────────────────────────

@override
Stream<List<T>> watch({bool fireImmediately = false}) {
  final controller = StreamController<List<T>>();

  // Initiales Laden + periodisches Polling (SQLite hat keine Change-Events)
  Timer? timer;

  Future<void> poll() async {
    try {
      final results = await findAll();
      if (!controller.isClosed) {
        controller.add(results);
      }
    } catch (e) {
      if (!controller.isClosed) {
        controller.addError(e);
      }
    }
  }

  controller.onListen = () {
    if (fireImmediately) poll();
    // Alle 500ms pollen — für Debugging ausreichend
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) => poll());
  };

  controller.onCancel = () {
    timer?.cancel();
    controller.close();
  };

  return controller.stream;
}

@override
Stream<void> watchLazy({bool fireImmediately = false}) {
  return watch(fireImmediately: fireImmediately).map((_) {});
  }
}

String _escapeSql(String value) => value.replaceAll("'", "''");
