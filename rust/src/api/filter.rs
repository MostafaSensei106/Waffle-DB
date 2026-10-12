use roaring::RoaringBitmap;

use crate::api::error::{Result, WaffleError};
use crate::api::schema::{
    WaffleFieldType, WaffleSchema, field_hash, field_value_key, numeric_index_key,
    numeric_index_prefix,
};
use crate::api::store::Store;

#[derive(Debug, serde::Deserialize)]
#[serde(tag = "op")]
pub enum FilterNode {
    #[serde(rename = "eq")]
    Eq { field: String, value: serde_json::Value },
    #[serde(rename = "in")]
    In { field: String, values: Vec<serde_json::Value> },
    #[serde(rename = "and")]
    And { filters: Vec<FilterNode> },
    #[serde(rename = "or")]
    Or { filters: Vec<FilterNode> },
    #[serde(rename = "not")]
    Not { filter: Box<FilterNode> },
}

fn json_scalar_to_canonical(field_type: &WaffleFieldType, v: &serde_json::Value) -> Result<(String, Option<f64>)> {
    match field_type {
        WaffleFieldType::String | WaffleFieldType::Text => match v {
            serde_json::Value::String(s) => Ok((s.clone(), None)),
            _ => Err(WaffleError::Filter("string field requires a string value".to_owned())),
        },
        WaffleFieldType::Boolean => match v {
            serde_json::Value::Bool(b) => Ok((b.to_string(), None)),
            _ => Err(WaffleError::Filter("boolean field requires true/false".to_owned())),
        },
        WaffleFieldType::Integer => match v {
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Ok((i.to_string(), Some(i as f64)))
                } else {
                    Err(WaffleError::Filter("integer field requires an integer value".to_owned()))
                }
            }
            _ => Err(WaffleError::Filter("integer field requires a number".to_owned())),
        },
        WaffleFieldType::Double => match v {
            serde_json::Value::Number(n) => {
                if let Some(f) = n.as_f64() {
                    Ok((f.to_string(), Some(f)))
                } else {
                    Err(WaffleError::Filter("double field requires a number".to_owned()))
                }
            }
            _ => Err(WaffleError::Filter("double field requires a number".to_owned())),
        },
    }
}

fn numeric_eq_bitmap(store: &Store, field: &str, n: f64) -> Result<RoaringBitmap> {
    let prefix = numeric_index_prefix(field_hash(field));
    let ids = store.numeric_scan_prefix(&prefix)?;
    let target = numeric_index_key(field_hash(field), n, 0);
    Ok(ids
        .into_iter()
        .filter(|id| numeric_index_key(field_hash(field), n, *id)[0..16] == target[0..16])
        .collect())
}

pub fn evaluate_filter(
    store: &Store,
    schema: &WaffleSchema,
    node: &FilterNode,
) -> Result<RoaringBitmap> {
    match node {
        FilterNode::Eq { field, value } => {
            let def = schema.indexed_field(field).ok_or_else(|| {
                WaffleError::Filter(format!("field {field:?} is not indexed"))
            })?;
            let (canonical, numeric) = json_scalar_to_canonical(&def.field_type, value)?;
            match numeric {
                Some(n) => numeric_eq_bitmap(store, field, n),
                None => {
                    let key = field_value_key(field, &canonical);
                    store.bitmap_get(&key)
                }
            }
        }
        FilterNode::In { field, values } => {
            let def = schema.indexed_field(field).ok_or_else(|| {
                WaffleError::Filter(format!("field {field:?} is not indexed"))
            })?;
            let mut acc = RoaringBitmap::new();
            for v in values {
                let (canonical, numeric) = json_scalar_to_canonical(&def.field_type, v)?;
                match numeric {
                    Some(n) => acc |= numeric_eq_bitmap(store, field, n)?,
                    None => {
                        let key = field_value_key(field, &canonical);
                        acc |= store.bitmap_get(&key)?;
                    }
                }
            }
            Ok(acc)
        }
        FilterNode::And { filters } => {
            let mut acc: Option<RoaringBitmap> = None;
            for f in filters {
                let bm = evaluate_filter(store, schema, f)?;
                acc = Some(match acc {
                    Some(a) => a & bm,
                    None => bm,
                });
            }
            Ok(acc.unwrap_or_default())
        }
        FilterNode::Or { filters } => {
            let mut acc = RoaringBitmap::new();
            for f in filters {
                acc |= evaluate_filter(store, schema, f)?;
            }
            Ok(acc)
        }
        FilterNode::Not { filter: _ } => Err(WaffleError::NotSupported(
            "NOT filters require a universe bitmap; use positive filters".to_owned(),
        )),
    }
}

pub fn parse_filter(json: &str) -> Result<FilterNode> {
    serde_json::from_str(json).map_err(|e| WaffleError::Filter(format!("invalid filter: {e}")))
}
