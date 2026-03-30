//! Isar Community WASM — SQLite-backed web storage for isar_community v3
//!
//! This crate compiles the Isar storage layer to WebAssembly using
//! `sqlite-wasm-rs` so that Flutter Web apps can use the same database
//! engine as native platforms.

use wasm_bindgen::prelude::*;

#[cfg(feature = "console_error_panic_hook")]
#[wasm_bindgen(start)]
pub fn _start() {
    console_error_panic_hook::set_once();
}

pub mod database;
pub mod collection;
pub mod transaction;
pub mod query;
pub mod schema;

/// Initialise the WASM module (call once from Dart/JS before opening a DB).
#[wasm_bindgen(js_name = "isarInit")]
pub fn isar_init() {
    #[cfg(feature = "console_error_panic_hook")]
    console_error_panic_hook::set_once();
}

/// Return the core version string so Dart can verify compatibility.
#[wasm_bindgen(js_name = "isarVersion")]
pub fn isar_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
