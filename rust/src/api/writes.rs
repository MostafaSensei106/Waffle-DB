use anyhow::{Result, anyhow};

use crate::api::engine::WaffleEngine;
use crate::api::filter::{evaluate_filter, parse_filter};
use crate::api::schema::{
    ChunkRecord, WaffleFieldType, field_hash, numeric_index_key,
};

pub(crate) type IndexedValues = Vec<(String, WaffleFieldType, String, Option<f64>)>;

pub(crate) struct InsertInput<'a> {
    id: &'a str,
    vector: &'a [f32],
    text: &'a str,
    payload_json: &'a str,
    parent_id: Option<String>,
    chunk_index: u32,
    commit_text: bool,
}

pub(crate) fn indexed_values(
    schema: &crate::api::schema::WaffleSchema,
    payload: &serde_json::Value,
) -> Result<IndexedValues> {
    let obj = payload
        .as_object()
        .ok_or_else(|| anyhow!("payload must be a JSON object"))?;
    schema
        .fields
        .iter()
        .filter(|f| f.indexed)
        .map(|field| {
            let v = obj.get(&field.name).ok_or_else(|| {
                anyhow!("payload is missing indexed field {:?}", field.name)
            })?;
            let (canonical, numeric) = match &field.field_type {
                WaffleFieldType::String | WaffleFieldType::Text => match v {
                    serde_json::Value::String(s) => (s.clone(), None),
                    _ => {
                        return Err(anyhow!(
                            "field {:?} expects a string",
                            field.name
                        ))
                    }
                },
                WaffleFieldType::Boolean => match v {
                    serde_json::Value::Bool(b) => (b.to_string(), None),
                    _ => {
                        return Err(anyhow!(
                            "field {:?} expects true/false",
                            field.name
                        ))
                    }
                },
                WaffleFieldType::Integer => match v.as_i64() {
                    Some(i) => (i.to_string(), Some(i as f64)),
                    None => {
                        return Err(anyhow!(
                            "field {:?} expects an integer",
                            field.name
                        ))
                    }
                },
                WaffleFieldType::Double => match v.as_f64() {
                    Some(f) => (f.to_string(), Some(f)),
                    None => {
                        return Err(anyhow!(
                            "field {:?} expects a number",
                            field.name
                        ))
                    }
                },
            };
            Ok((field.name.clone(), field.field_type.clone(), canonical, numeric))
        })
        .collect()
}

fn insert_one(engine: &WaffleEngine, input: InsertInput<'_>) -> Result<()> {
    insert_many(engine, &[input])
}

fn insert_many(engine: &WaffleEngine, inputs: &[InsertInput<'_>]) -> Result<()> {
    let dim = engine.config.dimension as usize;
    struct Prepared {
        internal: u32,
    }
    let tx = engine.store.begin_write()?;
    let mut prepared = Vec::with_capacity(inputs.len());
    let mut seen_chunks = std::collections::HashSet::new();
    for input in inputs {
        if input.vector.len() != dim {
            return Err(anyhow!(
                "dimension mismatch: expected {dim}, got {}",
                input.vector.len()
            ));
        }
        let payload: serde_json::Value = if input.payload_json.trim().is_empty() {
            serde_json::Value::Object(Default::default())
        } else {
            serde_json::from_str(input.payload_json).map_err(|e| {
                anyhow!("payload is not valid JSON: {e}")
            })?
        };
        let values = indexed_values(&engine.schema, &payload)?;
        if engine.store.lookup_internal(input.id)?.is_some() {
            return Err(anyhow!("duplicate id: {}", input.id));
        }
        let internal = engine.store.alloc_id(&tx)?;
        if let Some(parent) = input.parent_id.as_deref() {
            let key = (parent.to_owned(), input.chunk_index);
            if !seen_chunks.insert(key) {
                return Err(anyhow!(
                    "duplicate chunk index {} for parent {parent:?}",
                    input.chunk_index
                ));
            }
            if crate::api::store::Store::child_exists_in(&tx, parent, input.chunk_index)? {
                return Err(anyhow!(
                    "chunk index {} for parent {parent:?} already exists",
                    input.chunk_index
                ));
            }
        }
        let record = ChunkRecord {
            external_id: input.id.to_owned(),
            parent_id: input.parent_id.clone(),
            chunk_index: input.chunk_index,
            text: input.text.to_owned(),
            payload_json: input.payload_json.to_owned(),
        };
        engine
            .store
            .write_record(&tx, input.id, internal, &record, input.vector)?;
        for (field, _ft, canonical, numeric) in &values {
            match numeric {
                Some(n) => {
                    let key = numeric_index_key(field_hash(field), *n, internal);
                    engine.store.numeric_put(&tx, &key)?;
                }
                None => {
                    engine.store.bitmap_add(&tx, field, canonical, internal)?;
                }
            }
        }
        prepared.push(Prepared { internal });
    }
    tx.commit()?;

    for (input, item) in inputs.iter().zip(prepared.iter()) {
        engine.vector.add(item.internal, input.vector)?;
        if !input.text.trim().is_empty() {
            engine.text.add(item.internal, input.text)?;
        }
    }
    Ok(mutation)
}

fn delete_internal(engine: &WaffleEngine, internal: u32, commit_text: bool) -> Result<bool> {
    let rec = match engine.store.read_chunk(internal)? {
        Some(r) => r,
        None => return Ok(false),
    };
    let tx = engine.store.begin_write()?;
    engine
        .store
        .remove_record(&tx, &rec.external_id, internal)?;
    if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&rec.payload_json) {
        if let Ok(values) = indexed_values(&engine.schema, &payload) {
            for (field, _ft, canonical, numeric) in &values {
                match numeric {
                    Some(n) => {
                        let key = numeric_index_key(field_hash(field), *n, internal);
                        engine.store.numeric_remove(&tx, &key)?;
                    }
                    None => {
                        engine.store.bitmap_remove(&tx, field, canonical, internal)?;
                    }
                }
            }
        }
    }
    tx.commit()?;
    engine.vector.remove(internal)?;
    engine.text.delete(internal)?;
    if commit_text {
        engine.text.commit()?;
    }
    Ok(true)
}

pub(crate) fn insert(
    engine: &WaffleEngine,
    id: String,
    vector: Vec<f32>,
    text: String,
    payload_json: String,
    parent_id: Option<String>,
    chunk_index: u32,
) -> Result<()> {
    insert_one(
        engine,
        InsertInput {
            id: &id,
            vector: &vector,
            text: &text,
            payload_json: &payload_json,
            parent_id,
            chunk_index,
            commit_text: true,
        },
    )
}

pub(crate) fn insert_batch(
    engine: &WaffleEngine,
    ids: Vec<String>,
    vectors_flat: Vec<f32>,
    texts: Vec<String>,
    payload_jsons: Vec<String>,
    parent_ids: Vec<String>,
    chunk_indices: Vec<u32>,
) -> Result<()> {
    let dim = engine.config.dimension as usize;
    let n = ids.len();
    if vectors_flat.len() != n * dim {
        return Err(anyhow!(
            "flat vector length {} does not match {n} ids",
            vectors_flat.len()
        ));
    }
    for (list_len, name) in [
        (texts.len(), "texts"),
        (payload_jsons.len(), "payload_jsons"),
        (chunk_indices.len(), "chunk_indices"),
        (parent_ids.len(), "parent_ids"),
    ] {
        if list_len != n {
            return Err(anyhow!("{name} length {list_len} != {n} ids"));
        }
    }
    let inputs: Vec<InsertInput<'_>> = ids
        .iter()
        .zip(vectors_flat.chunks_exact(dim))
        .zip(texts.iter())
        .zip(payload_jsons.iter())
        .zip(chunk_indices.iter())
        .zip(parent_ids)
        .map(|(((((id, vector), text), payload_json), chunk_index), parent)| {
            InsertInput {
                id: id.as_str(),
                vector,
                text,
                payload_json,
                parent_id: if parent.is_empty() { None } else { Some(parent) },
                chunk_index: *chunk_index,
                commit_text: false,
            }
        })
        .collect();
    insert_many(engine, &inputs)?;
    engine.text.commit()?;
    Ok(())
}

pub(crate) fn upsert(
    engine: &WaffleEngine,
    id: String,
    vector: Vec<f32>,
    text: String,
    payload_json: String,
    parent_id: Option<String>,
    chunk_index: u32,
) -> Result<bool> {
    let replaced = match engine.store.lookup_internal(&id)? {
        Some(internal) => delete_internal(engine, internal, false)?,
        None => false,
    };
    insert(
        engine,
        id,
        vector,
        text,
        payload_json,
        parent_id,
        chunk_index,
    )?;
    Ok(replaced)
}

pub(crate) fn delete(engine: &WaffleEngine, id: &str) -> Result<bool> {
    match engine.store.lookup_internal(id)? {
        Some(internal) => delete_internal(engine, internal, true),
        None => Ok(false),
    }
}

pub(crate) fn delete_batch(engine: &WaffleEngine, ids: &[String]) -> Result<u64> {
    let mut removed = 0u64;
    for id in ids {
        if let Some(internal) = engine.store.lookup_internal(id)? {
            removed += u64::from(delete_internal(engine, internal, false)?);
        }
    }
    if removed > 0 {
        engine.text.commit()?;
    }
    Ok(removed)
}

pub(crate) fn delete_where(engine: &WaffleEngine, filter_json: &str) -> Result<u64> {
    let bitmap =
        evaluate_filter(&engine.store, &engine.schema, &parse_filter(filter_json)?)?;
    let removed: u64 = bitmap
        .iter()
        .collect::<Vec<u32>>()
        .iter()
        .try_fold(0u64, |acc, &internal| {
            delete_internal(engine, internal, false).map(|ok| acc + u64::from(ok))
        })?;
    if removed > 0 {
        engine.text.commit()?;
    }
    Ok(removed)
}
