use rkyv::{Archive, Deserialize, Serialize};

use crate::api::error::{Result, WaffleError};

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum WaffleFieldType {
    String,
    Integer,
    Double,
    Boolean,
    Text,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct WaffleField {
    pub name: String,
    pub field_type: WaffleFieldType,
    pub indexed: bool,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum WaffleLanguage {
    English,
    Arabic,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct WaffleSchema {
    pub fields: Vec<WaffleField>,
    pub text_language: WaffleLanguage,
}

impl WaffleSchema {
    pub fn validate(&self) -> Result<()> {
        if self.fields.is_empty() {
            return Err(WaffleError::Schema(
                "schema must declare at least one field".to_owned(),
            ));
        }
        let mut seen = std::collections::HashSet::new();
        for f in &self.fields {
            if f.name.trim().is_empty() {
                return Err(WaffleError::Schema("field name must not be empty".to_owned()));
            }
            if f.name.contains('\0') || f.name.contains('#') {
                return Err(WaffleError::Schema(format!(
                    "field name {:?} contains a reserved character",
                    f.name
                )));
            }
            if !seen.insert(f.name.clone()) {
                return Err(WaffleError::Schema(format!(
                    "duplicate field name {:?}",
                    f.name
                )));
            }
        }
        Ok(())
    }

    pub fn canonical_json(&self) -> Result<String> {
        serde_json::to_string(self).map_err(WaffleError::from)
    }

    pub fn indexed_field(&self, name: &str) -> Option<&WaffleField> {
        self.fields.iter().find(|f| f.name == name && f.indexed)
    }
}

#[derive(Archive, Serialize, Deserialize, Debug, Clone)]
pub struct ChunkRecord {
    pub external_id: String,
    pub parent_id: Option<String>,
    pub chunk_index: u32,
    pub text: String,
    pub payload_json: String,
}

pub fn archive_chunk(record: &ChunkRecord) -> Result<Vec<u8>> {
    rkyv::to_bytes::<rkyv::rancor::Error>(record)
        .map(|b| b.to_vec())
        .map_err(|e| WaffleError::Serialization(e.to_string()))
}

pub fn unarchive_chunk(bytes: &[u8]) -> Result<ChunkRecord> {
    rkyv::from_bytes::<ChunkRecord, rkyv::rancor::Error>(bytes)
        .map_err(|e| WaffleError::Serialization(e.to_string()))
}

pub fn field_value_key(field: &str, value: &str) -> String {
    let mut key = String::with_capacity(field.len() + value.len() + 1);
    key.push_str(field);
    key.push('\0');
    key.push_str(value);
    key
}

pub fn f64_to_ordered_u64(v: f64) -> u64 {
    let bits = v.to_bits();
    if bits & (1u64 << 63) == 0 {
        bits ^ (1u64 << 63)
    } else {
        !bits
    }
}

pub fn numeric_index_key(field_hash: u64, value: f64, internal_id: u32) -> [u8; 20] {
    let mut key = [0u8; 20];
    key[0..8].copy_from_slice(&field_hash.to_be_bytes());
    key[8..16].copy_from_slice(&f64_to_ordered_u64(value).to_be_bytes());
    key[16..20].copy_from_slice(&internal_id.to_be_bytes());
    key
}

pub fn numeric_index_prefix(field_hash: u64) -> [u8; 8] {
    field_hash.to_be_bytes()
}

pub fn field_hash(field: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    field.hash(&mut h);
    h.finish()
}
