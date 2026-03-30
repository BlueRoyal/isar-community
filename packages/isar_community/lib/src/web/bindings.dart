// ignore_for_file: public_member_api_docs

@JS()
library isar_wasm_bindings;

import 'package:js/js.dart';

// ── Module initialisation ────────────────────────────────────────────

@JS('isarInit')
external void isarInitJs();

@JS('isarVersion')
external String isarVersionJs();

// ── Instance lifecycle ───────────────────────────────────────────────

@JS('openIsar')
external IsarInstanceJs openIsarJs(
  String name,
  String schemasJson,
  bool relaxedDurability,
);

@JS('closeIsar')
external void closeIsarJs(IsarInstanceJs instance, bool deleteFromDisk);

@JS('IsarInstance')
class IsarInstanceJs {
  external String get name;
}

// ── Transactions ─────────────────────────────────────────────────────

@JS('isarBeginTxn')
external IsarTxnJs isarBeginTxnJs(IsarInstanceJs instance, bool write);

@JS('IsarTxn')
class IsarTxnJs {
  external bool get write;
  external void commit();
  external void abort();
}

// ── Collection CRUD ──────────────────────────────────────────────────

@JS('isarGetAll')
external String isarGetAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String collectionName,
  String idsJson,
);

@JS('isarPutAll')
external String isarPutAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String collectionName,
  String objectsJson,
);

@JS('isarDeleteAll')
external int isarDeleteAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String collectionName,
  String idsJson,
);

@JS('isarClear')
external void isarClearJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String collectionName,
);

@JS('isarCount')
external int isarCountJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String collectionName,
);

// ── Query execution ──────────────────────────────────────────────────

@JS('isarQuery')
external String isarQueryJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String sql,
);

@JS('isarAggregate')
external String isarAggregateJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String sql,
);

@JS('isarDeleteQuery')
external int isarDeleteQueryJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String sql,
);

// ── Link operations ──────────────────────────────────────────────────

@JS('isarLinkUpdate')
external void isarLinkUpdateJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String sourceCollection,
  String linkName,
  int sourceId,
  String addTargetIdsJson,
  String removeTargetIdsJson,
);

@JS('isarLinkClear')
external void isarLinkClearJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  String sourceCollection,
  String linkName,
  int sourceId,
);
