//! Collection-level CRUD.
//!
//! Each Isar collection maps to one SQLite table.  Objects are passed
//! between Dart and WASM as JSON strings (serialised on the Dart side,
//! deserialised here for INSERT, and vice-versa for SELECT).

use wasm_bindgen::prelude::*;
use sqlite_wasm_rs::export::*;
use std::ffi::CString;
use std::ptr;

use crate::database::IsarInstance;
use crate::transaction::IsarTxn;

// ── getAll ───────────────────────────────────────────────────────────

/// Fetch objects by their `_id` values.  Returns a JSON array of objects
/// (or `null` for missing ids).
#[wasm_bindgen(js_name = "isarGetAll")]
pub fn get_all(
    instance: &IsarInstance,
    txn: &IsarTxn,
    collection_name: &str,
    ids_json: &str,
) -> Result<String, JsValue> {
    let ids: Vec<i64> = serde_json::from_str(ids_json)
        .map_err(|e| JsValue::from_str(&format!("Invalid ids JSON: {}", e)))?;

    let schema = instance
        .schema(collection_name)
        .ok_or_else(|| JsValue::from_str(&format!("Collection '{}' not found", collection_name)))?;

    let placeholders: Vec<String> = ids.iter().map(|_| "?".to_string()).collect();
    let sql = format!(
        "SELECT _id, * FROM \"{}\" WHERE _id IN ({});",
        collection_name,
        placeholders.join(", ")
    );

    let db = txn.db_ptr();
    let results = exec_query_with_params(db, &sql, &ids, schema)?;

    // Reorder results to match input id order, inserting null for missing
    let mut ordered: Vec<serde_json::Value> = Vec::with_capacity(ids.len());
    for id in &ids {
        let found = results.iter().find(|row| {
            row.get("_id")
                .and_then(|v| v.as_i64())
                .map(|v| v == *id)
                .unwrap_or(false)
        });
        ordered.push(found.cloned().unwrap_or(serde_json::Value::Null));
    }

    serde_json::to_string(&ordered)
        .map_err(|e| JsValue::from_str(&format!("Serialize error: {}", e)))
}

// ── putAll ───────────────────────────────────────────────────────────

/// Insert or replace objects.  Returns a JSON array of the assigned `_id`s.
///
/// `objects_json` is a JSON array of objects.  If an object has `_id` set
/// to the auto-increment sentinel (−9007199254740991) the id is omitted
/// from the INSERT so SQLite auto-generates it.
#[wasm_bindgen(js_name = "isarPutAll")]
pub fn put_all(
    instance: &IsarInstance,
    txn: &IsarTxn,
    collection_name: &str,
    objects_json: &str,
) -> Result<String, JsValue> {
    let schema = instance
        .schema(collection_name)
        .ok_or_else(|| JsValue::from_str(&format!("Collection '{}' not found", collection_name)))?;

    let objects: Vec<serde_json::Value> = serde_json::from_str(objects_json)
        .map_err(|e| JsValue::from_str(&format!("Invalid objects JSON: {}", e)))?;

    let db = txn.db_ptr();
    let mut result_ids: Vec<i64> = Vec::with_capacity(objects.len());

    for obj in &objects {
        let obj_map = obj
            .as_object()
            .ok_or_else(|| JsValue::from_str("Each object must be a JSON object"))?;

        // Check if _id is the auto-increment sentinel or missing
        let has_real_id = obj_map
            .get("_id")
            .and_then(|v| v.as_i64())
            .map(|v| v != -9007199254740991i64 && v > 0)
            .unwrap_or(false);

        let mut col_names: Vec<String> = Vec::new();
        let mut placeholders: Vec<String> = Vec::new();
        let mut values: Vec<String> = Vec::new();

        if has_real_id {
            col_names.push("_id".to_string());
            placeholders.push("?".to_string());
            values.push(obj_map["_id"].to_string());
        }

        for prop in &schema.properties {
            if let Some(val) = obj_map.get(&prop.name) {
                col_names.push(format!("\"{}\"", prop.name));
                placeholders.push("?".to_string());
                // Store lists/objects as JSON text
                if val.is_array() || val.is_object() {
                    values.push(val.to_string());
                } else if val.is_null() {
                    values.push("__NULL__".to_string());
                } else if val.is_string() {
                    values.push(val.as_str().unwrap().to_string());
                } else {
                    values.push(val.to_string());
                }
            }
        }

        let sql = if has_real_id {
            format!(
                "INSERT OR REPLACE INTO \"{}\" ({}) VALUES ({});",
                collection_name,
                col_names.join(", "),
                placeholders.join(", ")
            )
        } else {
            format!(
                "INSERT INTO \"{}\" ({}) VALUES ({});",
                collection_name,
                col_names.join(", "),
                placeholders.join(", ")
            )
        };

        exec_insert(db, &sql, &values)?;

        let last_id = unsafe { sqlite3_last_insert_rowid(db) };
        result_ids.push(last_id);
    }

    serde_json::to_string(&result_ids)
        .map_err(|e| JsValue::from_str(&format!("Serialize error: {}", e)))
}

// ── deleteAll ────────────────────────────────────────────────────────

/// Delete objects by `_id`.  Returns the number of deleted rows.
#[wasm_bindgen(js_name = "isarDeleteAll")]
pub fn delete_all(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    collection_name: &str,
    ids_json: &str,
) -> Result<i32, JsValue> {
    let ids: Vec<i64> = serde_json::from_str(ids_json)
        .map_err(|e| JsValue::from_str(&format!("Invalid ids JSON: {}", e)))?;

    if ids.is_empty() {
        return Ok(0);
    }

    let placeholders: Vec<String> = ids.iter().map(|_| "?".to_string()).collect();
    let sql = format!(
        "DELETE FROM \"{}\" WHERE _id IN ({});",
        collection_name,
        placeholders.join(", ")
    );

    let db = txn.db_ptr();
    exec_delete(db, &sql, &ids)?;
    let changes = unsafe { sqlite3_changes(db) };
    Ok(changes)
}

// ── clear ────────────────────────────────────────────────────────────

/// Delete all objects in a collection.
#[wasm_bindgen(js_name = "isarClear")]
pub fn clear(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    collection_name: &str,
) -> Result<(), JsValue> {
    let sql = format!("DELETE FROM \"{}\";", collection_name);
    exec_simple(txn.db_ptr(), &sql)
}

// ── count ────────────────────────────────────────────────────────────

/// Count all objects in a collection.
#[wasm_bindgen(js_name = "isarCount")]
pub fn count(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    collection_name: &str,
) -> Result<i64, JsValue> {
    let sql = format!("SELECT COUNT(*) FROM \"{}\";", collection_name);
    exec_scalar_i64(txn.db_ptr(), &sql)
}

// ── Link operations ──────────────────────────────────────────────────

/// Add/remove links between objects.
#[wasm_bindgen(js_name = "isarLinkUpdate")]
pub fn link_update(
    instance: &IsarInstance,
    txn: &IsarTxn,
    source_collection: &str,
    link_name: &str,
    source_id: i64,
    add_target_ids_json: &str,
    remove_target_ids_json: &str,
) -> Result<(), JsValue> {
    let add_ids: Vec<i64> = serde_json::from_str(add_target_ids_json)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    let remove_ids: Vec<i64> = serde_json::from_str(remove_target_ids_json)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let table = format!("_isar_link_{}_{}", source_collection, link_name);
    let db = txn.db_ptr();

    // Add links
    for target_id in &add_ids {
        let sql = format!(
            "INSERT OR IGNORE INTO \"{}\" (source_id, target_id) VALUES (?, ?);",
            table
        );
        exec_insert(db, &sql, &[source_id.to_string(), target_id.to_string()])?;
    }

    // Remove links
    for target_id in &remove_ids {
        let sql = format!(
            "DELETE FROM \"{}\" WHERE source_id = ? AND target_id = ?;",
            table
        );
        exec_delete_raw(db, &sql, &[source_id, *target_id])?;
    }

    Ok(())
}

/// Clear all links for a source object.
#[wasm_bindgen(js_name = "isarLinkClear")]
pub fn link_clear(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    source_collection: &str,
    link_name: &str,
    source_id: i64,
) -> Result<(), JsValue> {
    let table = format!("_isar_link_{}_{}", source_collection, link_name);
    let sql = format!("DELETE FROM \"{}\" WHERE source_id = ?;", table);
    exec_delete_raw(txn.db_ptr(), &sql, &[source_id])
}

// ══════════════════════════════════════════════════════════════════════
//  Internal SQLite helpers
// ══════════════════════════════════════════════════════════════════════

fn exec_simple(db: *mut sqlite3, sql: &str) -> Result<(), JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut err: *mut std::os::raw::c_char = ptr::null_mut();
    let rc = unsafe { sqlite3_exec(db, c_sql.as_ptr(), None, ptr::null_mut(), &mut err) };
    if rc != SQLITE_OK {
        let msg = sqlite_err_msg(err, rc);
        return Err(JsValue::from_str(&msg));
    }
    Ok(())
}

fn exec_scalar_i64(db: *mut sqlite3, sql: &str) -> Result<i64, JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    let result = if unsafe { sqlite3_step(stmt) } == SQLITE_ROW {
        unsafe { sqlite3_column_int64(stmt, 0) }
    } else {
        0
    };

    unsafe { sqlite3_finalize(stmt) };
    Ok(result)
}

fn exec_query_with_params(
    db: *mut sqlite3,
    sql: &str,
    ids: &[i64],
    schema: &crate::schema::CollectionSchema,
) -> Result<Vec<serde_json::Value>, JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    // Bind id parameters
    for (i, id) in ids.iter().enumerate() {
        unsafe { sqlite3_bind_int64(stmt, (i + 1) as i32, *id) };
    }

    let mut results = Vec::new();
    let col_count = unsafe { sqlite3_column_count(stmt) };

    loop {
        let step = unsafe { sqlite3_step(stmt) };
        if step == SQLITE_ROW {
            let mut row = serde_json::Map::new();
            for col in 0..col_count {
                let name = unsafe {
                    let ptr = sqlite3_column_name(stmt, col);
                    if ptr.is_null() {
                        continue;
                    }
                    std::ffi::CStr::from_ptr(ptr)
                        .to_string_lossy()
                        .to_string()
                };

                let col_type = unsafe { sqlite3_column_type(stmt, col) };
                let value = match col_type {
                    SQLITE_INTEGER => {
                        serde_json::Value::Number(
                            serde_json::Number::from(unsafe { sqlite3_column_int64(stmt, col) })
                        )
                    }
                    SQLITE_FLOAT => {
                        let f = unsafe { sqlite3_column_double(stmt, col) };
                        serde_json::Number::from_f64(f)
                            .map(serde_json::Value::Number)
                            .unwrap_or(serde_json::Value::Null)
                    }
                    SQLITE_TEXT => {
                        let ptr = unsafe { sqlite3_column_text(stmt, col) };
                        if ptr.is_null() {
                            serde_json::Value::Null
                        } else {
                            let s = unsafe { std::ffi::CStr::from_ptr(ptr as *const _) }
                                .to_string_lossy()
                                .to_string();
                            // Try to parse as JSON (for list/object properties)
                            serde_json::from_str(&s).unwrap_or(serde_json::Value::String(s))
                        }
                    }
                    SQLITE_NULL | _ => serde_json::Value::Null,
                };
                row.insert(name, value);
            }
            results.push(serde_json::Value::Object(row));
        } else {
            break;
        }
    }

    unsafe { sqlite3_finalize(stmt) };
    Ok(results)
}

fn exec_insert(db: *mut sqlite3, sql: &str, values: &[String]) -> Result<(), JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    for (i, val) in values.iter().enumerate() {
        if val == "__NULL__" {
            unsafe { sqlite3_bind_null(stmt, (i + 1) as i32) };
        } else if let Ok(n) = val.parse::<i64>() {
            unsafe { sqlite3_bind_int64(stmt, (i + 1) as i32, n) };
        } else if let Ok(f) = val.parse::<f64>() {
            unsafe { sqlite3_bind_double(stmt, (i + 1) as i32, f) };
        } else {
            let c_val = CString::new(val.as_str()).map_err(|e| JsValue::from_str(&e.to_string()))?;
            unsafe {
                sqlite3_bind_text(
                    stmt,
                    (i + 1) as i32,
                    c_val.as_ptr(),
                    val.len() as i32,
                    SQLITE_TRANSIENT(),
                )
            };
        }
    }

    let step = unsafe { sqlite3_step(stmt) };
    unsafe { sqlite3_finalize(stmt) };

    if step != SQLITE_DONE && step != SQLITE_ROW {
        return Err(JsValue::from_str(&format!("Insert step error: {}", step)));
    }
    Ok(())
}

fn exec_delete(db: *mut sqlite3, sql: &str, ids: &[i64]) -> Result<(), JsValue> {
    exec_delete_raw(db, sql, ids)
}

fn exec_delete_raw(db: *mut sqlite3, sql: &str, params: &[i64]) -> Result<(), JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    for (i, val) in params.iter().enumerate() {
        unsafe { sqlite3_bind_int64(stmt, (i + 1) as i32, *val) };
    }

    let step = unsafe { sqlite3_step(stmt) };
    unsafe { sqlite3_finalize(stmt) };

    if step != SQLITE_DONE && step != SQLITE_ROW {
        return Err(JsValue::from_str(&format!("Delete step error: {}", step)));
    }
    Ok(())
}

/// SQLITE_TRANSIENT sentinel for sqlite3_bind_text.
unsafe fn SQLITE_TRANSIENT() -> Option<unsafe extern "C" fn(*mut std::ffi::c_void)> {
    std::mem::transmute::<isize, Option<unsafe extern "C" fn(*mut std::ffi::c_void)>>(-1)
}

fn sqlite_err_msg(err: *mut std::os::raw::c_char, rc: i32) -> String {
    if !err.is_null() {
        let s = unsafe { std::ffi::CStr::from_ptr(err) }
            .to_string_lossy()
            .to_string();
        unsafe { sqlite3_free(err as *mut _) };
        s
    } else {
        format!("SQLite error {}", rc)
    }
}
