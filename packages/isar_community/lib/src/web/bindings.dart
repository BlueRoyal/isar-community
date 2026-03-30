// ignore_for_file: public_member_api_docs
//
// JS interop bindings for the isar-wasm WASM module.
//
// These replace the old IndexedDB-based bindings.  Every function here
// corresponds to a #[wasm_bindgen] export in the Rust crate.

import 'dart:js_interop';

// ── Module initialisation ────────────────────────────────────────────

@JS('isarInit')
external void isarInitJs();

@JS('isarVersion')
external JSString isarVersionJs();

String isarVersion() => isarVersionJs().toDart;

// ── Instance lifecycle ───────────────────────────────────────────────

@JS('openIsar')
external IsarInstanceJs openIsarJs(
  JSString name,
  JSString schemasJson,
  JSBoolean relaxedDurability,
);

@JS('closeIsar')
external void closeIsarJs(IsarInstanceJs instance, JSBoolean deleteFromDisk);

/// Opaque handle to a WASM-side IsarInstance.
extension type IsarInstanceJs(JSObject _) implements JSObject {
  external JSString get name;
}

// ── Transactions ─────────────────────────────────────────────────────

@JS('isarBeginTxn')
external IsarTxnJs isarBeginTxnJs(IsarInstanceJs instance, JSBoolean write);

/// Opaque transaction handle.
extension type IsarTxnJs(JSObject _) implements JSObject {
  external JSBoolean get write;
  external void commit();
  external void abort();
}

// ── Collection CRUD ──────────────────────────────────────────────────

@JS('isarGetAll')
external JSString isarGetAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString collectionName,
  JSString idsJson,
);

@JS('isarPutAll')
external JSString isarPutAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString collectionName,
  JSString objectsJson,
);

@JS('isarDeleteAll')
external JSNumber isarDeleteAllJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString collectionName,
  JSString idsJson,
);

@JS('isarClear')
external void isarClearJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString collectionName,
);

@JS('isarCount')
external JSNumber isarCountJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString collectionName,
);

// ── Query execution ──────────────────────────────────────────────────

@JS('isarQuery')
external JSString isarQueryJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString sql,
);

@JS('isarAggregate')
external JSString isarAggregateJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString sql,
);

@JS('isarDeleteQuery')
external JSNumber isarDeleteQueryJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString sql,
);

// ── Link operations ──────────────────────────────────────────────────

@JS('isarLinkUpdate')
external void isarLinkUpdateJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString sourceCollection,
  JSString linkName,
  JSNumber sourceId,
  JSString addTargetIdsJson,
  JSString removeTargetIdsJson,
);

@JS('isarLinkClear')
external void isarLinkClearJs(
  IsarInstanceJs instance,
  IsarTxnJs txn,
  JSString sourceCollection,
  JSString linkName,
  JSNumber sourceId,
);
