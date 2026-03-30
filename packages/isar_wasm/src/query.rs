//! Query execution.
//!
//! Dart builds a query plan (WHERE clauses, filters, sorts, limits) and
//! sends it as a JSON descriptor.  This module translates that to SQL
//! and executes it.

use wasm_bindgen::prelude::*;
use sqlite_wasm_rs::export::*;
use std::ffi::CString;
use std::ptr;

use crate::database::IsarInstance;
use crate::transaction::IsarTxn;

// ── Generic SQL query execution ──────────────────────────────────────

/// Execute an arbitrary SQL SELECT and return rows as JSON.
///
/// Used by the Dart-side query builder which compiles Isar filter trees
/// into SQL WHERE expressions.
#[wasm_bindgen(js_name = "isarQuery")]
pub fn query(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    sql: &str,
) -> Result<String, JsValue> {
    let rows = exec_select(txn.db_ptr(), sql)?;
    serde_json::to_string(&rows)
        .map_err(|e| JsValue::from_str(&format!("Serialize error: {}", e)))
}

/// Execute an aggregate query (COUNT, MIN, MAX, SUM, AVG) and return
/// the scalar result as a JSON value.
#[wasm_bindgen(js_name = "isarAggregate")]
pub fn aggregate(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    sql: &str,
) -> Result<String, JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let db = txn.db_ptr();
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    let result = if unsafe { sqlite3_step(stmt) } == SQLITE_ROW {
        let col_type = unsafe { sqlite3_column_type(stmt, 0) };
        match col_type {
            SQLITE_INTEGER => {
                let v = unsafe { sqlite3_column_int64(stmt, 0) };
                serde_json::Value::Number(serde_json::Number::from(v))
            }
            SQLITE_FLOAT => {
                let f = unsafe { sqlite3_column_double(stmt, 0) };
                serde_json::Number::from_f64(f)
                    .map(serde_json::Value::Number)
                    .unwrap_or(serde_json::Value::Null)
            }
            _ => serde_json::Value::Null,
        }
    } else {
        serde_json::Value::Null
    };

    unsafe { sqlite3_finalize(stmt) };

    serde_json::to_string(&result)
        .map_err(|e| JsValue::from_str(&format!("Serialize error: {}", e)))
}

/// Execute a DELETE query and return the number of affected rows.
#[wasm_bindgen(js_name = "isarDeleteQuery")]
pub fn delete_query(
    _instance: &IsarInstance,
    txn: &IsarTxn,
    sql: &str,
) -> Result<i32, JsValue> {
    exec_non_query(txn.db_ptr(), sql)?;
    let changes = unsafe { sqlite3_changes(txn.db_ptr()) };
    Ok(changes)
}

// ── Internal helpers ─────────────────────────────────────────────────

fn exec_select(
    db: *mut sqlite3,
    sql: &str,
) -> Result<Vec<serde_json::Value>, JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut stmt: *mut sqlite3_stmt = ptr::null_mut();

    let rc = unsafe { sqlite3_prepare_v2(db, c_sql.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
    if rc != SQLITE_OK {
        return Err(JsValue::from_str(&format!("Prepare error: {}", rc)));
    }

    let col_count = unsafe { sqlite3_column_count(stmt) };
    let mut results = Vec::new();

    loop {
        let step = unsafe { sqlite3_step(stmt) };
        if step == SQLITE_ROW {
            let mut row = serde_json::Map::new();
            for col in 0..col_count {
                let name = unsafe {
                    let ptr = sqlite3_column_name(stmt, col);
                    if ptr.is_null() { continue; }
                    std::ffi::CStr::from_ptr(ptr).to_string_lossy().to_string()
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
                            // Try to parse JSON (list/object columns)
                            serde_json::from_str(&s).unwrap_or(serde_json::Value::String(s))
                        }
                    }
                    SQLITE_BLOB => {
                        let len = unsafe { sqlite3_column_bytes(stmt, col) } as usize;
                        let ptr = unsafe { sqlite3_column_blob(stmt, col) } as *const u8;
                        if ptr.is_null() || len == 0 {
                            serde_json::Value::Null
                        } else {
                            let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
                            serde_json::Value::String(base64_encode(bytes))
                        }
                    }
                    _ => serde_json::Value::Null,
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

fn exec_non_query(db: *mut sqlite3, sql: &str) -> Result<(), JsValue> {
    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut err: *mut std::os::raw::c_char = ptr::null_mut();
    let rc = unsafe { sqlite3_exec(db, c_sql.as_ptr(), None, ptr::null_mut(), &mut err) };
    if rc != SQLITE_OK {
        let msg = if !err.is_null() {
            let s = unsafe { std::ffi::CStr::from_ptr(err) }.to_string_lossy().to_string();
            unsafe { sqlite3_free(err as *mut _) };
            s
        } else {
            format!("SQLite error {}", rc)
        };
        return Err(JsValue::from_str(&msg));
    }
    Ok(())
}

fn base64_encode(bytes: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        result.push(CHARS[((triple >> 18) & 0x3F) as usize] as char);
        result.push(CHARS[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            result.push(CHARS[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            result.push('=');
        }
        if chunk.len() > 2 {
            result.push(CHARS[(triple & 0x3F) as usize] as char);
        } else {
            result.push('=');
        }
    }
    result
}
