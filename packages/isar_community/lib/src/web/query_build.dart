// ignore_for_file: public_member_api_docs, invalid_use_of_protected_member
//
// Query builder for WASM/web.
//
// Translates Isar's query DSL (WhereClause, Filter, Sort, Distinct,
// property projections) into SQL strings that the WASM module executes.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

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

  IsarImpl get isar => collection.isar;
  String get tableName => collection.name;

  // ── SQL generation ─────────────────────────────────────────────────

  String _buildSelectSql({String select = '*'}) {
    final buf = StringBuffer('SELECT $select FROM "$tableName"');

    // WHERE clauses
    final conditions = _buildWhereConditions();
    if (conditions.isNotEmpty) {
      buf.write(' WHERE ${conditions.join(" AND ")}');
    }

    // ORDER BY
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

    // LIMIT / OFFSET
    if (limit != null) buf.write(' LIMIT $limit');
    if (offset != null) buf.write(' OFFSET $offset');

    buf.write(';');
    return buf.toString();
  }

  List<String> _buildWhereConditions() {
    final conditions = <String>[];

    // WhereClause → range conditions on _id or indexed columns
    for (final wc in whereClauses) {
      if (wc.indexName == null) {
        // Id-based where clause
        if (wc.lower != null && wc.lower!.isNotEmpty) {
          final op = wc.includeLower ? '>=' : '>';
          conditions.add('_id $op ${wc.lower![0]}');
        }
        if (wc.upper != null && wc.upper!.isNotEmpty) {
          final op = wc.includeUpper ? '<=' : '<';
          conditions.add('_id $op ${wc.upper![0]}');
        }
      } else {
        // Index-based where clause
        if (wc.lower != null) {
          for (var i = 0; i < wc.lower!.length; i++) {
            final value = wc.lower![i];
            final op = wc.includeLower ? '>=' : '>';
            conditions.add(_formatCondition(wc.indexName!, i, op, value));
          }
        }
        if (wc.upper != null) {
          for (var i = 0; i < wc.upper!.length; i++) {
            final value = wc.upper![i];
            final op = wc.includeUpper ? '<=' : '<';
            conditions.add(_formatCondition(wc.indexName!, i, op, value));
          }
        }
      }
    }

    // Filter → SQL WHERE
    if (filter != null) {
      final filterSql = _filterToSql(filter!);
      if (filterSql.isNotEmpty) {
        conditions.add(filterSql);
      }
    }

    return conditions;
  }

  String _formatCondition(String indexName, int propIndex, String op, dynamic value) {
    // Resolve the property name from the index schema
    final indexSchema = collection.schema.indexes
        .firstWhere((idx) => idx.name == indexName);
    final propName = propIndex < indexSchema.properties.length
        ? indexSchema.properties[propIndex].name
        : indexName;

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
      final parts = filter.filters.map(_filterToSql).where((s) => s.isNotEmpty).toList();
      if (parts.isEmpty) return '';
      final joiner = filter.type == FilterGroupType.and ? ' AND ' : ' OR ';
      final expr = parts.join(joiner);
      if (filter.not) return 'NOT ($expr)';
      return '($expr)';
    } else if (filter is FilterCondition) {
      return _conditionToSql(filter);
    }
    return '';
  }

  String _conditionToSql(FilterCondition cond) {
    final prop = '"${cond.property}"';

    switch (cond.type) {
      case ConditionType.eq:
        if (cond.value1 == null) return '$prop IS NULL';
        return '$prop = ${_sqlValue(cond.value1)}';
      case ConditionType.gt:
        return '$prop > ${_sqlValue(cond.value1)}';
      case ConditionType.gte:
        return '$prop >= ${_sqlValue(cond.value1)}';
      case ConditionType.lt:
        return '$prop < ${_sqlValue(cond.value1)}';
      case ConditionType.lte:
        return '$prop <= ${_sqlValue(cond.value1)}';
      case ConditionType.between:
        return '$prop BETWEEN ${_sqlValue(cond.value1)} AND ${_sqlValue(cond.value2)}';
      case ConditionType.startsWith:
        return '$prop LIKE \'${_escapeSql(cond.value1.toString())}%\'';
      case ConditionType.endsWith:
        return '$prop LIKE \'%${_escapeSql(cond.value1.toString())}\'';
      case ConditionType.contains:
        return '$prop LIKE \'%${_escapeSql(cond.value1.toString())}%\'';
      case ConditionType.matches:
        // Isar wildcard pattern: * → %, ? → _
        final pattern = cond.value1
            .toString()
            .replaceAll('*', '%')
            .replaceAll('?', '_');
        return '$prop LIKE \'${_escapeSql(pattern)}\'';
      case ConditionType.isNull:
        return '$prop IS NULL';
      case ConditionType.isNotNull:
        return '$prop IS NOT NULL';
      default:
        return '';
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
    return isar.getTxn(false, (txn) async {
      final sql = _buildSelectSql().replaceFirst(';', ' LIMIT 1;');
      final json = isarQueryJs(isar.instance, txn, sql.toJS).toDart;
      final list = jsonDecode(json) as List<dynamic>;
      if (list.isEmpty) return null;
      return collection._deserializeFromJson(
        list[0] as Map<String, dynamic>,
      ) as T?;
    });
  }

  @override
  T? findFirstSync() => unsupportedOnWeb();

  @override
  Future<List<T>> findAll() {
    return isar.getTxn(false, (txn) async {
      final sql = _buildSelectSql();
      final json = isarQueryJs(isar.instance, txn, sql.toJS).toDart;
      final list = jsonDecode(json) as List<dynamic>;

      if (property != null) {
        // Property projection
        return list.map((row) {
          final map = row as Map<String, dynamic>;
          return map[property] as T;
        }).toList();
      }

      return list.map((item) {
        return collection._deserializeFromJson(
          item as Map<String, dynamic>,
        ) as T;
      }).toList();
    });
  }

  @override
  List<T> findAllSync() => unsupportedOnWeb();

  @override
  Future<int> deleteFirst() {
    return isar.getTxn(true, (txn) async {
      // Find the first matching id, then delete it
      final selectSql = _buildSelectSql(select: '_id')
          .replaceFirst(';', ' LIMIT 1;');
      final json = isarQueryJs(isar.instance, txn, selectSql.toJS).toDart;
      final list = jsonDecode(json) as List<dynamic>;
      if (list.isEmpty) return 0;
      final id = (list[0] as Map<String, dynamic>)['_id'];
      final deleteSql = 'DELETE FROM "$tableName" WHERE _id = $id;';
      return isarDeleteQueryJs(isar.instance, txn, deleteSql.toJS).toDartInt;
    });
  }

  @override
  int deleteFirstSync() => unsupportedOnWeb();

  @override
  Future<int> deleteAll() {
    return isar.getTxn(true, (txn) async {
      final conditions = _buildWhereConditions();
      final where =
          conditions.isEmpty ? '' : ' WHERE ${conditions.join(" AND ")}';
      final sql = 'DELETE FROM "$tableName"$where;';
      return isarDeleteQueryJs(isar.instance, txn, sql.toJS).toDartInt;
    });
  }

  @override
  int deleteAllSync() => unsupportedOnWeb();

  // ── Aggregates ─────────────────────────────────────────────────────

  @override
  Future<R> aggregate<R>(AggregationOp op) {
    return isar.getTxn(false, (txn) async {
      final conditions = _buildWhereConditions();
      final where =
          conditions.isEmpty ? '' : ' WHERE ${conditions.join(" AND ")}';

      late final String sql;
      switch (op) {
        case AggregationOp.count:
          sql = 'SELECT COUNT(*) FROM "$tableName"$where;';
          break;
        case AggregationOp.isEmpty:
          sql = 'SELECT COUNT(*) FROM "$tableName"$where LIMIT 1;';
          break;
        case AggregationOp.min:
          sql = 'SELECT MIN("${property ?? "_id"}") FROM "$tableName"$where;';
          break;
        case AggregationOp.max:
          sql = 'SELECT MAX("${property ?? "_id"}") FROM "$tableName"$where;';
          break;
        case AggregationOp.sum:
          sql = 'SELECT SUM("${property ?? "_id"}") FROM "$tableName"$where;';
          break;
        case AggregationOp.average:
          sql = 'SELECT AVG("${property ?? "_id"}") FROM "$tableName"$where;';
          break;
      }

      final json = isarAggregateJs(isar.instance, txn, sql.toJS).toDart;
      final value = jsonDecode(json);

      if (op == AggregationOp.isEmpty) {
        return (value == 0) as R;
      }
      if (op == AggregationOp.count) {
        return (value as num).toInt() as R;
      }
      return value as R;
    });
  }

  // ── Watch (stub) ───────────────────────────────────────────────────

  @override
  Stream<List<T>> watch({bool fireImmediately = false}) {
    // TODO: Implement via polling
    return const Stream.empty();
  }

  @override
  Stream<void> watchLazy({bool fireImmediately = false}) {
    // TODO: Implement via polling
    return const Stream.empty();
  }
}

String _escapeSql(String value) => value.replaceAll("'", "''");
