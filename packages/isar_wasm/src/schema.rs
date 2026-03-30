//! Schema definitions that mirror the Dart-side CollectionSchema.
//!
//! When Dart calls `openIsar(schemas)` it passes a JSON array describing
//! every collection, its properties, indexes, and links.  This module
//! deserialises that JSON and generates the corresponding SQL DDL.

use serde::{Deserialize, Serialize};

// ── Schema types ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionSchema {
    pub name: String,
    pub properties: Vec<PropertySchema>,
    #[serde(default)]
    pub indexes: Vec<IndexSchema>,
    #[serde(default)]
    pub links: Vec<LinkSchema>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertySchema {
    pub name: String,
    #[serde(rename = "type")]
    pub prop_type: u8, // mirrors IsarType enum ordinal from Dart
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexSchema {
    pub name: String,
    pub properties: Vec<IndexPropertySchema>,
    #[serde(default)]
    pub unique: bool,
    #[serde(default)]
    pub hash: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexPropertySchema {
    pub name: String,
    #[serde(default)]
    pub hash: bool,
    #[serde(rename = "type")]
    pub sort: u8, // 0 = asc, 1 = desc
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinkSchema {
    pub name: String,
    pub target: String,
    #[serde(default)]
    pub single: bool,
}

// ── Isar type constants (must match `IsarType` ordinal in Dart) ──────

pub const ISAR_TYPE_BOOL: u8 = 0;
pub const ISAR_TYPE_BYTE: u8 = 1;
pub const ISAR_TYPE_INT: u8 = 2;
pub const ISAR_TYPE_FLOAT: u8 = 3;
pub const ISAR_TYPE_LONG: u8 = 4;
pub const ISAR_TYPE_DOUBLE: u8 = 5;
pub const ISAR_TYPE_STRING: u8 = 6;
pub const ISAR_TYPE_BYTE_LIST: u8 = 7;
pub const ISAR_TYPE_INT_LIST: u8 = 8;
pub const ISAR_TYPE_FLOAT_LIST: u8 = 9;
pub const ISAR_TYPE_LONG_LIST: u8 = 10;
pub const ISAR_TYPE_DOUBLE_LIST: u8 = 11;
pub const ISAR_TYPE_STRING_LIST: u8 = 12;
pub const ISAR_TYPE_BOOL_LIST: u8 = 13;
pub const ISAR_TYPE_DATE_TIME: u8 = 14;
pub const ISAR_TYPE_DATE_TIME_LIST: u8 = 15;
pub const ISAR_TYPE_OBJECT: u8 = 16;
pub const ISAR_TYPE_OBJECT_LIST: u8 = 17;

// ── SQL DDL generation ───────────────────────────────────────────────

impl CollectionSchema {
    /// Map an Isar property type to a SQLite column affinity.
    fn sql_type(prop_type: u8) -> &'static str {
        match prop_type {
            ISAR_TYPE_BOOL => "INTEGER",
            ISAR_TYPE_BYTE | ISAR_TYPE_INT | ISAR_TYPE_LONG | ISAR_TYPE_DATE_TIME => "INTEGER",
            ISAR_TYPE_FLOAT | ISAR_TYPE_DOUBLE => "REAL",
            ISAR_TYPE_STRING => "TEXT",
            // Lists and embedded objects are stored as JSON blobs
            _ => "TEXT",
        }
    }

    /// Generate `CREATE TABLE` statement for this collection.
    pub fn create_table_sql(&self) -> String {
        let mut cols = vec!["_id INTEGER PRIMARY KEY AUTOINCREMENT".to_string()];
        for prop in &self.properties {
            cols.push(format!(
                "\"{}\" {}",
                prop.name,
                Self::sql_type(prop.prop_type)
            ));
        }
        format!(
            "CREATE TABLE IF NOT EXISTS \"{}\" ({});",
            self.name,
            cols.join(", ")
        )
    }

    /// Generate `CREATE INDEX` statements for every declared index.
    pub fn create_index_sqls(&self) -> Vec<String> {
        self.indexes
            .iter()
            .map(|idx| {
                let unique = if idx.unique { "UNIQUE " } else { "" };
                let cols: Vec<String> = idx
                    .properties
                    .iter()
                    .map(|p| {
                        let dir = if p.sort == 1 { " DESC" } else { "" };
                        format!("\"{}\"{}",  p.name, dir)
                    })
                    .collect();
                format!(
                    "CREATE {}INDEX IF NOT EXISTS \"{}\" ON \"{}\" ({});",
                    unique,
                    idx.name,
                    self.name,
                    cols.join(", ")
                )
            })
            .collect()
    }

    /// Generate `CREATE TABLE` for link junction tables.
    pub fn create_link_table_sqls(&self) -> Vec<String> {
        self.links
            .iter()
            .map(|link| {
                let table_name = format!("_isar_link_{}_{}", self.name, link.name);
                format!(
                    "CREATE TABLE IF NOT EXISTS \"{}\" (\
                     source_id INTEGER NOT NULL, \
                     target_id INTEGER NOT NULL, \
                     PRIMARY KEY (source_id, target_id), \
                     FOREIGN KEY (source_id) REFERENCES \"{}\"(_id) ON DELETE CASCADE, \
                     FOREIGN KEY (target_id) REFERENCES \"{}\"(_id) ON DELETE CASCADE\
                     );",
                    table_name, self.name, link.target
                )
            })
            .collect()
    }
}
