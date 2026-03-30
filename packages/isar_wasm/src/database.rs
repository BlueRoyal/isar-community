//! Database lifecycle – open, migrate, close.
//!
//! Each `IsarInstance` owns one SQLite connection.  Storage is backed by
//! OPFS (Origin-Private File System) when available, falling back to
//! in-memory SQLite otherwise.

use wasm_bindgen::prelude::*;
use sqlite_wasm_rs::export::sqlite3;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::schema::CollectionSchema;

// ── Low-level SQLite helpers ────────────────────────────────────────

/// Thin wrapper around a raw `*mut sqlite3` pointer.
pub struct SqliteDb {
    db: *mut sqlite3,
}

// sqlite-wasm-rs database handles are safe to share across the single
// WASM thread (there is only one thread in the browser main context).
unsafe impl Send for SqliteDb {}
unsafe impl Sync for SqliteDb {}

impl SqliteDb {
    /// Open (or create) a named database.
    ///
    /// Tries OPFS-backed storage first (`file:{name}.db?vfs=opfs`),
    /// then falls back to a plain in-memory database.
    pub fn open(name: &str) -> Result<Self, JsValue> {
        let mut db: *mut sqlite3 = ptr::null_mut();

        // Try OPFS first
        let opfs_uri = CString::new(format!("file:{}.db?vfs=opfs", name))
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        let rc = unsafe {
            sqlite_wasm_rs::export::sqlite3_open_v2(
                opfs_uri.as_ptr(),
                &mut db,
                sqlite_wasm_rs::export::SQLITE_OPEN_READWRITE
                    | sqlite_wasm_rs::export::SQLITE_OPEN_CREATE,
                ptr::null(),
            )
        };

        if rc != sqlite_wasm_rs::export::SQLITE_OK {
            // Fallback: in-memory
            let mem_uri = CString::new(format!(":memory:"))
                .map_err(|e| JsValue::from_str(&e.to_string()))?;

            let rc2 = unsafe {
                sqlite_wasm_rs::export::sqlite3_open(mem_uri.as_ptr(), &mut db)
            };
            if rc2 != sqlite_wasm_rs::export::SQLITE_OK {
                return Err(JsValue::from_str(&format!(
                    "Failed to open SQLite database: error code {}",
                    rc2
                )));
            }
            web_sys::console::warn_1(
                &"OPFS not available – using in-memory SQLite (data will not persist across sessions)".into(),
            );
        }

        // Enable WAL mode for better concurrent read performance
        let db_wrapper = SqliteDb { db };
        let _ = db_wrapper.exec("PRAGMA journal_mode=WAL;");
        let _ = db_wrapper.exec("PRAGMA foreign_keys=ON;");

        Ok(db_wrapper)
    }

    /// Execute a statement that returns no rows.
    pub fn exec(&self, sql: &str) -> Result<(), JsValue> {
        let c_sql = CString::new(sql)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;
        let mut err_msg: *mut c_char = ptr::null_mut();

        let rc = unsafe {
            sqlite_wasm_rs::export::sqlite3_exec(
                self.db,
                c_sql.as_ptr(),
                None,
                ptr::null_mut(),
                &mut err_msg,
            )
        };

        if rc != sqlite_wasm_rs::export::SQLITE_OK {
            let msg = if !err_msg.is_null() {
                let s = unsafe { CStr::from_ptr(err_msg) }
                    .to_string_lossy()
                    .to_string();
                unsafe { sqlite_wasm_rs::export::sqlite3_free(err_msg as *mut _) };
                s
            } else {
                format!("SQLite error {}", rc)
            };
            return Err(JsValue::from_str(&msg));
        }
        Ok(())
    }

    /// Return the raw pointer for prepare/step/finalize usage.
    pub fn raw(&self) -> *mut sqlite3 {
        self.db
    }

    /// Close the database.
    pub fn close(self) -> Result<(), JsValue> {
        let rc = unsafe { sqlite_wasm_rs::export::sqlite3_close_v2(self.db) };
        if rc != sqlite_wasm_rs::export::SQLITE_OK {
            return Err(JsValue::from_str(&format!(
                "Failed to close SQLite: error code {}",
                rc
            )));
        }
        Ok(())
    }

    /// Delete the database from storage (OPFS).
    pub fn delete_from_disk(name: &str) -> Result<(), JsValue> {
        // For OPFS: we'd need to use the File System Access API via JS interop
        // For now, log a warning – full OPFS deletion requires async JS calls
        web_sys::console::warn_1(
            &format!("deleteFromDisk for '{}': OPFS cleanup not yet implemented", name).into(),
        );
        Ok(())
    }
}

impl Drop for SqliteDb {
    fn drop(&mut self) {
        if !self.db.is_null() {
            unsafe { sqlite_wasm_rs::export::sqlite3_close_v2(self.db) };
        }
    }
}

// ── IsarInstance (JS-exposed) ────────────────────────────────────────

/// The main database handle exposed to JavaScript / Dart.
#[wasm_bindgen(js_name = "IsarInstance")]
pub struct IsarInstance {
    // Not exposed to JS directly – access via methods only
    name: String,
    db: SqliteDb,
    schemas: HashMap<String, CollectionSchema>,
}

#[wasm_bindgen(js_class = "IsarInstance")]
impl IsarInstance {
    /// Expose instance name.
    #[wasm_bindgen(getter)]
    pub fn name(&self) -> String {
        self.name.clone()
    }

    /// Return raw db pointer (for transaction module).
    pub(crate) fn db(&self) -> &SqliteDb {
        &self.db
    }

    /// Look up a schema by collection name.
    pub(crate) fn schema(&self, name: &str) -> Option<&CollectionSchema> {
        self.schemas.get(name)
    }
}

// ── Free function: openIsar ──────────────────────────────────────────

/// Open an Isar instance.  Called from Dart via JS interop.
///
/// `schemas_json` is the JSON-encoded list of CollectionSchema objects
/// that Dart's `getSchemas()` produces.
#[wasm_bindgen(js_name = "openIsar")]
pub fn open_isar(
    name: &str,
    schemas_json: &str,
    _relaxed_durability: bool,
) -> Result<IsarInstance, JsValue> {
    let schemas: Vec<CollectionSchema> = serde_json::from_str(schemas_json)
        .map_err(|e| JsValue::from_str(&format!("Invalid schema JSON: {}", e)))?;

    let db = SqliteDb::open(name)?;

    // Apply DDL for every collection
    for schema in &schemas {
        db.exec(&schema.create_table_sql())?;
        for idx_sql in schema.create_index_sqls() {
            db.exec(&idx_sql)?;
        }
        for link_sql in schema.create_link_table_sqls() {
            db.exec(&link_sql)?;
        }
    }

    // Build lookup map
    let mut map = HashMap::new();
    for s in schemas {
        map.insert(s.name.clone(), s);
    }

    web_sys::console::log_1(
        &format!("Isar WASM: opened '{}' with {} collection(s)", name, map.len()).into(),
    );

    Ok(IsarInstance {
        name: name.to_string(),
        db,
        schemas: map,
    })
}

/// Close an Isar instance, optionally deleting persisted data.
#[wasm_bindgen(js_name = "closeIsar")]
pub fn close_isar(instance: IsarInstance, delete_from_disk: bool) -> Result<(), JsValue> {
    let name = instance.name.clone();
    instance.db.close()?;
    if delete_from_disk {
        SqliteDb::delete_from_disk(&name)?;
    }
    Ok(())
}
