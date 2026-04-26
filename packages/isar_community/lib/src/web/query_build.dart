// ignore_for_file: public_member_api_docs
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: deprecated_member_use

/// SQL-generating query builder for the isar_wasm.js (sql.js/SQLite) backend.
/// Replaces the original IndexedDB-based query_build.dart.

import 'package:isar_community/isar.dart';
import 'package:isar_community/src/web/isar_collection_impl.dart';
import 'package:isar_community/src/web/query_impl.dart';

Query<T> buildWebQuery<T, OBJ>(
  IsarCollectionImpl<OBJ> col,
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
  final table = col.schema.name;

  // ── SELECT clause ──────────────────────────────────────────────
  final selectCols = property != null ? '"_id", "$property"' : '*';

  // ── WHERE clause (from WhereClause list) ───────────────────────
  final whereParts = <String>[];
  for (final wc in whereClauses) {
    final part = _buildWhereClause(col.schema, wc);
    if (part != null && part.isNotEmpty) {
      whereParts.add(part);
    }
  }

  // ── FILTER clause ──────────────────────────────────────────────
  final filterSql = filter != null ? _buildFilter(col.schema, filter) : null;

  // Combine: where-clauses are OR'd, then AND'd with filter
  final allConditions = <String>[];
  if (whereParts.isNotEmpty) {
    if (whereParts.length == 1) {
      allConditions.add(whereParts.first);
    } else {
      allConditions.add('(${whereParts.join(' OR ')})');
    }
  }
  if (filterSql != null && filterSql.isNotEmpty) {
    allConditions.add(filterSql);
  }

  final whereStr =
      allConditions.isNotEmpty ? ' WHERE ${allConditions.join(' AND ')}' : '';

  // ── ORDER BY ───────────────────────────────────────────────────
  String orderStr = '';
  if (sortBy.isNotEmpty) {
    final parts = sortBy.map((s) {
      final dir = s.sort == Sort.asc ? 'ASC' : 'DESC';
      return '"${s.property}" $dir';
    });
    orderStr = ' ORDER BY ${parts.join(', ')}';
  } else if (whereClauses.length == 1) {
    // implicit sort by the where-clause index
    final wc = whereClauses.first;
    if (wc is IndexWhereClause) {
      final dir = whereSort == Sort.asc ? 'ASC' : 'DESC';
      final idx = col.schema.index(wc.indexName);
      final cols =
          idx.properties.map((p) => '"${p.name}" $dir').join(', ');
      orderStr = ' ORDER BY $cols';
    } else if (wc is IdWhereClause) {
      final dir = whereSort == Sort.asc ? 'ASC' : 'DESC';
      orderStr = ' ORDER BY "_id" $dir';
    }
  }

  // ── DISTINCT ───────────────────────────────────────────────────
  // SQLite DISTINCT is limited; we handle it via GROUP BY
  String distinctStr = '';
  if (distinctBy.isNotEmpty || whereDistinct) {
    final cols = <String>[];
    if (whereDistinct && whereClauses.length == 1) {
      final wc = whereClauses.first;
      if (wc is IndexWhereClause) {
        final idx = col.schema.index(wc.indexName);
        cols.addAll(idx.properties.map((p) => '"${p.name}"'));
      }
    }
    for (final d in distinctBy) {
      final c = d.caseSensitive != false
          ? '"${d.property}"'
          : 'LOWER("${d.property}")';
      if (!cols.contains(c)) cols.add(c);
    }
    if (cols.isNotEmpty) {
      distinctStr = ' GROUP BY ${cols.join(', ')}';
    }
  }

  // ── LIMIT / OFFSET ────────────────────────────────────────────
  String limitStr = '';
  if (limit != null) {
    limitStr = ' LIMIT $limit';
  }
  if (offset != null && offset > 0) {
    if (limitStr.isEmpty) limitStr = ' LIMIT -1'; // SQLite needs LIMIT for OFFSET
    limitStr += ' OFFSET $offset';
  }

  final sql =
      'SELECT $selectCols FROM "$table"$whereStr$distinctStr$orderStr$limitStr;';

  QueryDeserialize<T> deserialize;
  deserialize = col.deserializeObject as T Function(Object);

  return QueryImpl<T>(col, sql, deserialize, property);
}

// ═══════════════════════════════════════════════════════════════════
// Where-clause → SQL
// ═══════════════════════════════════════════════════════════════════

String? _buildWhereClause(
  CollectionSchema<dynamic> schema,
  WhereClause wc,
) {
  if (wc is IdWhereClause) {
    return _idWhere(wc);
  } else if (wc is IndexWhereClause) {
    return _indexWhere(schema, wc);
  } else if (wc is LinkWhereClause) {
    return _linkWhere(wc);
  }
  return null;
}

String? _idWhere(IdWhereClause wc) {
  final parts = <String>[];
  if (wc.lower != null) {
    final op = wc.includeLower ? '>=' : '>';
    parts.add('"_id" $op ${wc.lower}');
  }
  if (wc.upper != null) {
    final op = wc.includeUpper ? '<=' : '<';
    parts.add('"_id" $op ${wc.upper}');
  }
  return parts.isEmpty ? null : parts.join(' AND ');
}

String? _indexWhere(CollectionSchema<dynamic> schema, IndexWhereClause wc) {
  final idx = schema.index(wc.indexName);
  final props = idx.properties;
  final lower = wc.lower;
  final upper = wc.upper;

  if (lower == null && upper == null) return null; // anyX()

  final parts = <String>[];

  // Single-property index: simple range
  if (props.length == 1) {
    final col = props.first.name;
    if (lower != null && lower.isNotEmpty) {
      final v = _sqlValue(lower.first);
      final op = wc.includeLower ? '>=' : '>';
      parts.add('"$col" $op $v');
    }
    if (upper != null && upper.isNotEmpty) {
      final v = _sqlValue(upper.first);
      final op = wc.includeUpper ? '<=' : '<';
      parts.add('"$col" $op $v');
    }
    // EqualTo shortcut: lower == upper && both inclusive
    if (lower != null &&
        upper != null &&
        lower.isNotEmpty &&
        upper.isNotEmpty &&
        wc.includeLower &&
        wc.includeUpper &&
        _sqlValue(lower.first) == _sqlValue(upper.first)) {
      return '"$col" = ${_sqlValue(lower.first)}';
    }
  } else {
    // Composite index: build conditions per property
    for (var i = 0; i < props.length; i++) {
      final col = props[i].name;
      final hasLower = lower != null && i < lower.length;
      final hasUpper = upper != null && i < upper.length;

      if (hasLower && hasUpper) {
        final lv = _sqlValue(lower[i]);
        final uv = _sqlValue(upper[i]);
        if (lv == uv && wc.includeLower && wc.includeUpper) {
          parts.add('"$col" = $lv');
        } else {
          final lOp = (i == props.length - 1 ? (wc.includeLower ? '>=' : '>') : '>=');
          final uOp = (i == props.length - 1 ? (wc.includeUpper ? '<=' : '<') : '<=');
          parts.add('"$col" $lOp $lv');
          parts.add('"$col" $uOp $uv');
        }
      } else if (hasLower) {
        final lOp = wc.includeLower ? '>=' : '>';
        parts.add('"$col" $lOp ${_sqlValue(lower[i])}');
      } else if (hasUpper) {
        final uOp = wc.includeUpper ? '<=' : '<';
        parts.add('"$col" $uOp ${_sqlValue(upper[i])}');
      }
    }
  }

  return parts.isEmpty ? null : parts.join(' AND ');
}

String? _linkWhere(LinkWhereClause wc) {
  final linkTable = '_isar_link_${wc.linkCollection}_${wc.linkName}';
  return '"_id" IN (SELECT "target_id" FROM "$linkTable" '
      'WHERE "source_id" = ${wc.id})';
}

// ═══════════════════════════════════════════════════════════════════
// Filter → SQL
// ═══════════════════════════════════════════════════════════════════

String? _buildFilter(
  CollectionSchema<dynamic> schema,
  FilterOperation filter,
) {
  if (filter is FilterGroup) {
    return _buildFilterGroup(schema, filter);
  } else if (filter is FilterCondition) {
    return _buildCondition(schema, filter);
  } else if (filter is LinkFilter) {
    // LinkFilter is not trivially translatable; skip for now
    return null;
  }
  return null;
}

String? _buildFilterGroup(CollectionSchema<dynamic> schema, FilterGroup group) {
  final parts = group.filters
      .map((f) => _buildFilter(schema, f))
      .where((s) => s != null && s.isNotEmpty)
      .toList();

  if (parts.isEmpty) return null;
  if (parts.length == 1 && group.type == FilterGroupType.not) {
    return 'NOT (${parts.first})';
  }
  if (parts.length == 1) return parts.first;

  switch (group.type) {
    case FilterGroupType.and:
      return '(${parts.join(' AND ')})';
    case FilterGroupType.or:
      return '(${parts.join(' OR ')})';
    case FilterGroupType.xor:
      // XOR for 2 conditions: (A OR B) AND NOT (A AND B)
      if (parts.length == 2) {
        return '((${parts[0]} OR ${parts[1]}) AND NOT (${parts[0]} AND ${parts[1]}))';
      }
      // Fallback: just OR
      return '(${parts.join(' OR ')})';
    case FilterGroupType.not:
      return 'NOT (${parts.first})';
  }
}

String? _buildCondition(
  CollectionSchema<dynamic> schema,
  FilterCondition cond,
) {
  final prop = cond.property;
  final col = prop == schema.idName ? '"_id"' : '"$prop"';
  final v1 = cond.value1;
  final v2 = cond.value2;
  final ci = !cond.caseSensitive;
  final accessor = ci && v1 is String ? 'LOWER($col)' : col;

  final propSchema = prop == schema.idName ? null : schema.property(prop);
  final isList = propSchema != null && propSchema.type.isList;

  // For list properties stored as JSON text, we use json_each or LIKE
  // For simplicity, use LIKE-based approach for list element queries

  switch (cond.type) {
    case FilterConditionType.equalTo:
      if (v1 == null) {
        return '($col IS NULL)';
      }
      if (isList) {
        // List element equal: JSON array contains value
        return _listContains(col, v1, ci);
      }
      return '$accessor = ${_sqlValue(v1, lowerCase: ci)}';

    case FilterConditionType.greaterThan:
      if (v1 == null) {
        return cond.include1 ? '1=1' : '($col IS NOT NULL)';
      }
      final op = cond.include1 ? '>=' : '>';
      return '$accessor $op ${_sqlValue(v1, lowerCase: ci)}';

    case FilterConditionType.lessThan:
      if (v1 == null) {
        return cond.include1 ? '($col IS NULL)' : '0=1';
      }
      final op = cond.include1 ? '<=' : '<';
      return '($col IS NOT NULL AND $accessor $op ${_sqlValue(v1, lowerCase: ci)})';

    case FilterConditionType.between:
      final parts = <String>[];
      if (v1 != null) {
        final op = cond.include1 ? '>=' : '>';
        parts.add('$accessor $op ${_sqlValue(v1, lowerCase: ci)}');
      }
      if (v2 != null) {
        final op = cond.include2 ? '<=' : '<';
        parts.add('$accessor $op ${_sqlValue(v2, lowerCase: ci)}');
      }
      if (parts.isEmpty) return null;
      return '(${parts.join(' AND ')})';

    case FilterConditionType.startsWith:
      final sv = _escapeLike(v1 as String, ci: ci);
      return '$accessor LIKE ${_sqlStr('$sv%', lowerCase: ci)}';

    case FilterConditionType.endsWith:
      final sv = _escapeLike(v1 as String, ci: ci);
      return '$accessor LIKE ${_sqlStr('%$sv', lowerCase: ci)}';

    case FilterConditionType.contains:
      final sv = _escapeLike(v1 as String, ci: ci);
      return '$accessor LIKE ${_sqlStr('%$sv%', lowerCase: ci)}';

    case FilterConditionType.matches:
      // Wildcard: * -> %, ? -> _
      var pattern = v1 as String;
      pattern = pattern.replaceAll('*', '%').replaceAll('?', '_');
      if (ci) pattern = pattern.toLowerCase();
      return '$accessor LIKE ${_sqlStr(pattern)}';

    case FilterConditionType.isNull:
      return '($col IS NULL)';

    case FilterConditionType.listLength:
      // For JSON arrays stored as TEXT, estimate length
      // json_array_length is available in newer SQLite
      if (v1 != null && v2 != null && v1 == v2) {
        return '(json_array_length($col) = ${v1 as int})';
      }
      final parts = <String>[];
      if (v1 != null) {
        final op = cond.include1 ? '>=' : '>';
        parts.add('json_array_length($col) $op ${v1 as int}');
      }
      if (v2 != null) {
        final op = cond.include2 ? '<=' : '<';
        parts.add('json_array_length($col) $op ${v2 as int}');
      }
      return parts.isEmpty ? null : '(${parts.join(' AND ')})';
  }
}

/// Check if a JSON array column contains a value.
String _listContains(String col, dynamic value, bool ci) {
  if (value is String) {
    final sv = ci ? value.toLowerCase() : value;
    // Use json_each for proper checking
    return 'EXISTS (SELECT 1 FROM json_each($col) '
        'WHERE ${ci ? "LOWER(value)" : "value"} = ${_sqlStr(sv)})';
  } else {
    return 'EXISTS (SELECT 1 FROM json_each($col) WHERE value = ${_sqlValue(value)})';
  }
}

// ═══════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════

String _sqlValue(dynamic value, {bool lowerCase = false}) {
  if (value == null) return 'NULL';
  if (value is bool) return value ? '1' : '0';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isNaN || value.isInfinite) return 'NULL';
    return '$value';
  }
  if (value is DateTime) return '${value.toUtc().millisecondsSinceEpoch}';
  if (value is String) return _sqlStr(value, lowerCase: lowerCase);
  if (value is List) return _sqlStr(_jsonEncode(value));
  return _sqlStr('$value');
}

String _sqlStr(String s, {bool lowerCase = false}) {
  final v = lowerCase ? s.toLowerCase() : s;
  return "'${v.replaceAll("'", "''")}'";
}

String _escapeLike(String s, {bool ci = false}) {
  var v = s.replaceAll('%', '').replaceAll('_', '');
  if (ci) v = v.toLowerCase();
  return v;
}

String _jsonEncode(dynamic value) {
  if (value is List) {
    final items = value.map(_jsonEncode).join(',');
    return '[$items]';
  }
  if (value is String) return '"${value.replaceAll('"', '\\"')}"';
  if (value is bool) return value ? 'true' : 'false';
  return '$value';
}
