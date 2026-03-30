//! Transaction management.
//!
//! Isar distinguishes read and write transactions.  On SQLite-WASM we map
//! them to `BEGIN` / `BEGIN IMMEDIATE` respectively.

use wasm_bindgen::prelude::*;
use sqlite_wasm_rs::export::sqlite3;

use crate::database::IsarInstance;

/// A live SQLite transaction.
#[wasm_bindgen(js_name = "IsarTxn")]
pub struct IsarTxn {
    db_ptr: *mut sqlite3,
    is_write: bool,
    finished: bool,
}

// Single-threaded WASM – safe to send.
unsafe impl Send for IsarTxn {}
unsafe impl Sync for IsarTxn {}

#[wasm_bindgen(js_class = "IsarTxn")]
impl IsarTxn {
    /// Whether this is a write transaction.
    #[wasm_bindgen(getter)]
    pub fn write(&self) -> bool {
        self.is_write
    }

    /// Commit the transaction.
    #[wasm_bindgen]
    pub fn commit(&mut self) -> Result<(), JsValue> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        exec_raw(self.db_ptr, "COMMIT;")
    }

    /// Roll back the transaction.
    #[wasm_bindgen]
    pub fn abort(&mut self) {
        if self.finished {
            return;
        }
        self.finished = true;
        let _ = exec_raw(self.db_ptr, "ROLLBACK;");
    }

    /// Internal: return raw db pointer for SQL execution within this txn.
    pub(crate) fn db_ptr(&self) -> *mut sqlite3 {
        self.db_ptr
    }
}

impl Drop for IsarTxn {
    fn drop(&mut self) {
        // Auto-rollback if not explicitly finished
        if !self.finished {
            let _ = exec_raw(self.db_ptr, "ROLLBACK;");
        }
    }
}

// ── Begin transaction ────────────────────────────────────────────────

/// Begin a new transaction on the given Isar instance.
#[wasm_bindgen(js_name = "isarBeginTxn")]
pub fn begin_txn(instance: &IsarInstance, write: bool) -> Result<IsarTxn, JsValue> {
    let db_ptr = instance.db().raw();
    let sql = if write {
        "BEGIN IMMEDIATE;"
    } else {
        "BEGIN;"
    };
    exec_raw(db_ptr, sql)?;

    Ok(IsarTxn {
        db_ptr,
        is_write: write,
        finished: false,
    })
}

// ── Helper ───────────────────────────────────────────────────────────

fn exec_raw(db: *mut sqlite3, sql: &str) -> Result<(), JsValue> {
    use std::ffi::CString;
    use std::os::raw::c_char;
    use std::ptr;

    let c_sql = CString::new(sql).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut err: *mut c_char = ptr::null_mut();

    let rc = unsafe {
        sqlite_wasm_rs::export::sqlite3_exec(db, c_sql.as_ptr(), None, ptr::null_mut(), &mut err)
    };

    if rc != sqlite_wasm_rs::export::SQLITE_OK {
        let msg = if !err.is_null() {
            let s = unsafe { std::ffi::CStr::from_ptr(err) }
                .to_string_lossy()
                .to_string();
            unsafe { sqlite_wasm_rs::export::sqlite3_free(err as *mut _) };
            s
        } else {
            format!("SQLite error {}", rc)
        };
        return Err(JsValue::from_str(&msg));
    }
    Ok(())
}
