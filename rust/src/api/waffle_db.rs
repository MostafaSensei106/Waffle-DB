use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

use roaring::RoaringBitmap;

use crate::api::config::WaffleConfig;
use anyhow::{Result, anyhow};
use crate::api::filter::{evaluate_filter, parse_filter};
use crate::api::query::{WaffleHit, WaffleSearchRequest, rrf_fuse};
use crate::api::schema::{
    ChunkRecord, WaffleFieldType, WaffleSchema, field_hash, numeric_index_key,
};
use crate::api::store::Store;
use crate::api::text::TextEngine;
use crate::api::vector::VectorEngine;

struct WaffleEngine {
    config: WaffleConfig,
    schema: WaffleSchema,
    store: Store,
    vector: VectorEngine,
    text: TextEngine,
    ef_guard: Mutex<()>,
    dir: PathBuf,
}

static HANDLE_COUNTER: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static RwLock<HashMap<u64, WaffleEngine>> {
    static REGISTRY: OnceLock<RwLock<HashMap<u64, WaffleEngine>>> = OnceLock::new();
    REGISTRY.get_or_init(|| RwLock::new(HashMap::new()))
}

fn with_engine<F, R>(handle: u64, f: F) -> std::result::Result<R, String>
where
    F: FnOnce(&WaffleEngine) -> Result<R>,
{
    let reg = registry()
        .read()
        .map_err(|e| format!("lock poisoned: {e}"))?;
    let engine = reg
        .get(&handle)
        .ok_or_else(|| format!("invalid WaffleDB handle: {handle}"))?;
    f(engine).map_err(|e| e.to_string())
}

fn hit_from_internal(store: &Store, internal: u32, score: f32, distance: Option<f32>) -> Result<Option<WaffleHit>> {
    match store.read_chunk(internal)? {
        Some(rec) => Ok(Some(WaffleHit {
            id: rec.external_id,
            score,
            distance,
            text: Some(rec.text),
            payload_json: Some(rec.payload_json),
        })),
        None => Ok(None),
    }
}

fn indexed_values(
    schema: &WaffleSchema,
    payload: &serde_json::Value,
) -> Result<IndexedValues> {
    let obj = payload.as_object().ok_or_else(|| {
        anyhow!("payload must be a JSON object")
    })?;
    let mut out = Vec::new();
    for field in schema.fields.iter().filter(|f| f.indexed) {
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
                    ));
                }
            },
            WaffleFieldType::Boolean => match v {
                serde_json::Value::Bool(b) => (b.to_string(), None),
                _ => {
                    return Err(anyhow!(
                        "field {:?} expects true/false",
                        field.name
                    ));
                }
            },
            WaffleFieldType::Integer => match v.as_i64() {
                Some(i) => (i.to_string(), Some(i as f64)),
                None => {
                    return Err(anyhow!(
                        "field {:?} expects an integer",
                        field.name
                    ));
                }
            },
            WaffleFieldType::Double => match v.as_f64() {
                Some(f) => (f.to_string(), Some(f)),
                None => {
                    return Err(anyhow!(
                        "field {:?} expects a number",
                        field.name
                    ));
                }
            },
        };
        out.push((field.name.clone(), field.field_type.clone(), canonical, numeric));
    }
    Ok(out)
}

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

    let mut texts_added = false;
    for (input, item) in inputs.iter().zip(prepared.iter()) {
        engine.vector.add(item.internal, input.vector)?;
        if !input.text.trim().is_empty() {
            engine.text.add(item.internal, input.text)?;
            texts_added = true;
        }
    }
    if texts_added || inputs.iter().any(|i| i.commit_text) {
        engine.text.commit()?;
    }
    Ok(())
}

pub fn waffle_open(config: WaffleConfig, schema: WaffleSchema) -> std::result::Result<u64, String> {
    (|| -> Result<u64> {
        let dir = PathBuf::from(&config.path);
        std::fs::create_dir_all(&dir)
            .map_err(|e| anyhow!("cannot create db dir: {e}"))?;
        let dim = config.dimension as usize;
        let store = Store::open(&dir, &schema, config.dimension)?;
        let vector = VectorEngine::open(
            &dir,
            dim,
            &config.graph_config.metric,
            config.graph_config.m as usize,
            config.graph_config.ef_construction as usize,
            config.graph_config.ef_search as usize,
            config.max_elements as usize,
        )?;
        if vector.size() as u64 != store.count()? {
            for (_, internal, vec) in store.all_vectors(dim)? {
                if !vector.contains(internal) {
                    vector.add(internal, &vec)?;
                }
            }
            vector.save(&dir)?;
        }
        let text = TextEngine::open(&dir.join("tantivy"), &schema.text_language)?;
        let engine = WaffleEngine {
            config,
            schema,
            store,
            vector,
            text,
            ef_guard: Mutex::new(()),
            dir,
        };
        let handle = HANDLE_COUNTER.fetch_add(1, Ordering::Relaxed);
        registry()
            .write()
            .map_err(|e| anyhow!("lock poisoned: {e}"))?
            .insert(handle, engine);
        Ok(handle)
    })()
    .map_err(|e| e.to_string())
}

pub fn waffle_close(handle: u64) -> std::result::Result<(), String> {
    let mut reg = registry()
        .write()
        .map_err(|e| format!("lock poisoned: {e}"))?;
    if let Some(engine) = reg.remove(&handle) {
        engine
            .text
            .commit()
            .map_err(|e| e.to_string())?;
        engine.vector.save(&engine.dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn waffle_insert(
    handle: u64,
    id: String,
    vector: Vec<f32>,
    text: String,
    payload_json: String,
    parent_id: Option<String>,
    chunk_index: u32,
) -> std::result::Result<(), String> {
    with_engine(handle, |engine| {
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
    })
}

pub fn waffle_insert_batch(
    handle: u64,
    ids: Vec<String>,
    vectors_flat: Vec<f32>,
    texts: Vec<String>,
    payload_jsons: Vec<String>,
    parent_ids: Vec<String>,
    chunk_indices: Vec<u32>,
) -> std::result::Result<(), String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        let n = ids.len();
        if vectors_flat.len() != n * dim {
            return Err(anyhow!(
                "flat vector length {} does not match {n} ids",
                vectors_flat.len()
            ));
        }
        if texts.len() != n {
            return Err(anyhow!(
                "texts length {} != {n} ids",
                texts.len()
            ));
        }
        if payload_jsons.len() != n {
            return Err(anyhow!(
                "payload_jsons length {} != {n} ids",
                payload_jsons.len()
            ));
        }
        if chunk_indices.len() != n {
            return Err(anyhow!(
                "chunk_indices length {} != {n} ids",
                chunk_indices.len()
            ));
        }
        if parent_ids.len() != n {
            return Err(anyhow!(
                "parent_ids length {} != {n} ids",
                parent_ids.len()
            ));
        }
        let mut parent_iter = parent_ids.into_iter();
        let mut inputs = Vec::with_capacity(n);
        for i in 0..n {
            let start = i * dim;
            let parent = parent_iter.next().unwrap_or_default();
            let parent = if parent.is_empty() { None } else { Some(parent) };
            inputs.push(InsertInput {
                id: &ids[i],
                vector: &vectors_flat[start..start + dim],
                text: &texts[i],
                payload_json: &payload_jsons[i],
                parent_id: parent,
                chunk_index: chunk_indices[i],
                commit_text: false,
            });
        }
        insert_many(engine, &inputs)?;
        engine.text.commit()?;
        Ok(())
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_search(
    handle: u64,
    request: WaffleSearchRequest,
) -> std::result::Result<Vec<WaffleHit>, String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        if let Some(v) = &request.vector {
            if v.len() != dim {
                return Err(anyhow!(
                    "dimension mismatch: expected {dim}, got {}",
                    v.len()
                ));
            }
        }
        if request.vector.is_none() && request.text.is_none() {
            return Err(anyhow!("search request needs a vector, a text, or both"));
        }
        let top_k = (request.top_k as usize).clamp(1, 10_000);
        let offset = request.offset as usize;
        let fetch = (top_k + offset).min(10_000);
        let allowed: Option<RoaringBitmap> = match &request.filter_json {
            Some(json) => Some(evaluate_filter(&engine.store, &engine.schema, &parse_filter(json)?)?),
            None => None,
        };

        let (dense, sparse) = rayon::join(
            || -> Result<Option<Vec<(u32, f32)>>> {
                match &request.vector {
                    Some(v) => {
                        let res = if request.ef_search > 0 {
                            let _guard = engine.ef_guard.lock().map_err(|e| {
                                anyhow!("lock poisoned: {e}")
                            })?;
                            engine.vector.override_expansion_search(request.ef_search as usize);
                            let r = engine.vector.search(v, fetch, allowed.as_ref());
                            engine.vector.override_expansion_search(
                                engine.config.graph_config.ef_search as usize,
                            );
                            r?
                        } else {
                            engine.vector.search(v, fetch, allowed.as_ref())?
                        };
                        Ok(Some(res))
                    }
                    None => Ok(None),
                }
            },
            || -> Result<Option<Vec<(u32, f32)>>> {
                match &request.text {
                    Some(t) => {
                        // Tantivy has no predicate pushdown: over-fetch and
                        // apply the allowed-ids bitmap here, growing the
                        // limit until enough filtered hits are collected.
                        let mut limit = fetch;
                        let mut collected: Vec<(u32, f32)> = Vec::new();
                        for _ in 0..4 {
                            let page = engine.text.search(t, limit)?;
                            if page.is_empty() {
                                break;
                            }
                            collected.clear();
                            for (id, score) in &page {
                                let keep = match &allowed {
                                    Some(bm) => bm.contains(*id),
                                    None => true,
                                };
                                if keep {
                                    collected.push((*id, *score));
                                }
                                if collected.len() >= fetch {
                                    break;
                                }
                            }
                            if collected.len() >= fetch || page.len() < limit {
                                break;
                            }
                            limit = (limit * 2).min(10_000);
                        }
                        collected.truncate(fetch);
                        Ok(Some(collected))
                    }
                    None => Ok(None),
                }
            },
        );
        let dense = dense?;
        let sparse = sparse?;

        let fused: Vec<(u32, f32, Option<f32>)> = match (dense, sparse) {
            (Some(d), Some(s)) => {
                let rrf_k = request.rrf_k.unwrap_or(60) as usize;
                let alpha = request.alpha.unwrap_or(0.5).clamp(0.0, 1.0);
                rrf_fuse(&d, &s, rrf_k, alpha, fetch)
            }
            (Some(d), None) => {
                let mut v: Vec<(u32, f32, Option<f32>)> = d
                    .into_iter()
                    .map(|(id, dist)| (id, 1.0 / (1.0 + dist), Some(dist)))
                    .collect();
                v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                v.truncate(fetch);
                v
            }
            (None, Some(s)) => {
                let mut v: Vec<(u32, f32, Option<f32>)> =
                    s.into_iter().map(|(id, score)| (id, score, None)).collect();
                v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                v.truncate(fetch);
                v
            }
            (None, None) => unreachable!(),
        };

        let mut hits = Vec::with_capacity(fused.len().min(top_k));
        for (internal, score, distance) in fused.into_iter().skip(offset).take(top_k) {
            if let Some(hit) = hit_from_internal(&engine.store, internal, score, distance)? {
                hits.push(hit);
            }
        }
        Ok(hits)
    })
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

pub fn waffle_delete(handle: u64, id: String) -> std::result::Result<bool, String> {
    with_engine(handle, |engine| {
        match engine.store.lookup_internal(&id)? {
            Some(internal) => delete_internal(engine, internal, true),
            None => Ok(false),
        }
    })
}

pub fn waffle_upsert(
    handle: u64,
    id: String,
    vector: Vec<f32>,
    text: String,
    payload_json: String,
    parent_id: Option<String>,
    chunk_index: u32,
) -> std::result::Result<bool, String> {
    with_engine(handle, |engine| {
        let replaced = match engine.store.lookup_internal(&id)? {
            Some(internal) => delete_internal(engine, internal, false)?,
            None => false,
        };
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
        )?;
        Ok(replaced)
    })
}

pub fn waffle_delete_batch(
    handle: u64,
    ids: Vec<String>,
) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| {
        let mut removed = 0u64;
        for id in &ids {
            if let Some(internal) = engine.store.lookup_internal(id)? {
                if delete_internal(engine, internal, false)? {
                    removed += 1;
                }
            }
        }
        if removed > 0 {
            engine.text.commit()?;
        }
        Ok(removed)
    })
}

pub fn waffle_delete_where(
    handle: u64,
    filter_json: String,
) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| {
        let bitmap =
            evaluate_filter(&engine.store, &engine.schema, &parse_filter(&filter_json)?)?;
        let targets: Vec<u32> = bitmap.iter().collect();
        let mut removed = 0u64;
        for internal in targets {
            if delete_internal(engine, internal, false)? {
                removed += 1;
            }
        }
        if removed > 0 {
            engine.text.commit()?;
        }
        Ok(removed)
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_metadata(handle: u64, id: String) -> std::result::Result<Option<Vec<u8>>, String> {
    with_engine(handle, |engine| match engine.store.lookup_internal(&id)? {
        Some(internal) => Ok(engine
            .store
            .read_chunk(internal)?
            .map(|rec| rec.payload_json.into_bytes())),
        None => Ok(None),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_vector(handle: u64, id: String) -> std::result::Result<Option<Vec<f32>>, String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        match engine.store.lookup_internal(&id)? {
            Some(internal) => Ok(engine.store.read_vector(internal, dim)?),
            None => Ok(None),
        }
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_count(handle: u64) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| engine.store.count())
}

pub fn waffle_flush(handle: u64) -> std::result::Result<(), String> {
    with_engine(handle, |engine| {
        engine.text.commit()?;
        engine.vector.save(&engine.dir)?;
        Ok(())
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_all_ids(handle: u64) -> std::result::Result<Vec<String>, String> {
    with_engine(handle, |engine| engine.store.all_external_ids())
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_neighbors(
    handle: u64,
    id: String,
    window: u32,
) -> std::result::Result<Vec<WaffleHit>, String> {
    with_engine(handle, |engine| {
        let internal = engine.store.lookup_internal(&id)?.ok_or_else(|| {
            anyhow!("unknown id {id:?}")
        })?;
        let rec = engine.store.read_chunk(internal)?.ok_or_else(|| {
            anyhow!("missing record for {id:?}")
        })?;
        let parent = rec.parent_id.clone().ok_or_else(|| {
            anyhow!("record has no parent document")
        })?;
        let mut hits = Vec::new();
        let lo = rec.chunk_index.saturating_sub(window);
        let hi = rec.chunk_index.saturating_add(window);
        for idx in lo..=hi {
            if let Some(sibling) = engine.store.child_lookup(&parent, idx)? {
                if let Some(hit) = hit_from_internal(&engine.store, sibling, 1.0, None)? {
                    hits.push(hit);
                }
            }
        }
        Ok(hits)
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_parent(handle: u64, id: String) -> std::result::Result<Option<WaffleHit>, String> {
    with_engine(handle, |engine| {
        let internal = match engine.store.lookup_internal(&id)? {
            Some(v) => v,
            None => return Ok(None),
        };
        let rec = match engine.store.read_chunk(internal)? {
            Some(r) => r,
            None => return Ok(None),
        };
        let parent = match rec.parent_id {
            Some(p) => p,
            None => return Ok(None),
        };
        match engine.store.lookup_internal(&parent)? {
            Some(p_internal) => Ok(hit_from_internal(&engine.store, p_internal, 1.0, None)?),
            None => Ok(None),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
    use crate::api::schema::{WaffleField, WaffleFieldType, WaffleLanguage};

    fn test_schema() -> WaffleSchema {
        WaffleSchema {
            fields: vec![
                WaffleField {
                    name: "category".to_owned(),
                    field_type: WaffleFieldType::String,
                    indexed: true,
                },
                WaffleField {
                    name: "price".to_owned(),
                    field_type: WaffleFieldType::Integer,
                    indexed: true,
                },
            ],
            text_language: WaffleLanguage::English,
        }
    }

    fn test_config(path: &str) -> WaffleConfig {
        WaffleConfig {
            dimension: 8,
            path: path.to_owned(),
            graph_config: WaffleGraphConfig {
                m: 16,
                metric: WaffleMetric::Cosine,
                ef_construction: 64,
                ef_search: 32,
            },
            max_elements: 1000,
            use_quantization: false,
            cache_size_bytes: 8 * 1024 * 1024,
            worker_threads: 2,
        }
    }

    #[test]
    fn enterprise_roundtrip() {
        let path = "/tmp/waffle_enterprise_test_db";
        let _ = std::fs::remove_dir_all(path);
        let handle = waffle_open(test_config(path), test_schema()).unwrap();

        let vec_a = vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        let vec_b = vec![0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        waffle_insert(
            handle,
            "doc-a".to_owned(),
            vec_a.clone(),
            "fast red car".to_owned(),
            r#"{"category":"auto","price":100}"#.to_owned(),
            Some("parent-1".to_owned()),
            0,
        )
        .unwrap();
        waffle_insert(
            handle,
            "doc-b".to_owned(),
            vec_b.clone(),
            "slow blue boat".to_owned(),
            r#"{"category":"marine","price":200}"#.to_owned(),
            Some("parent-1".to_owned()),
            1,
        )
        .unwrap();

        assert_eq!(waffle_count(handle).unwrap(), 2);

        let hits = waffle_search(
            handle,
            WaffleSearchRequest {
                vector: Some(vec_a.clone()),
                text: None,
                top_k: 5,
                offset: 0,
                filter_json: Some(r#"{"op":"eq","field":"category","value":"auto"}"#.to_owned()),
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, "doc-a");

        let empty = waffle_search(
            handle,
            WaffleSearchRequest {
                vector: Some(vec_a.clone()),
                text: None,
                top_k: 5,
                offset: 0,
                filter_json: Some(r#"{"op":"eq","field":"category","value":"marine"}"#.to_owned()),
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap();
        assert_eq!(empty.len(), 1);
        assert_eq!(empty[0].id, "doc-b");

        let neighbors = waffle_get_neighbors(handle, "doc-a".to_owned(), 1).unwrap();
        assert_eq!(neighbors.len(), 2);

        assert!(waffle_delete(handle, "doc-a".to_owned()).unwrap());
        assert_eq!(waffle_count(handle).unwrap(), 1);
        let after = waffle_search(
            handle,
            WaffleSearchRequest {
                vector: Some(vec_a),
                text: None,
                top_k: 5,
                offset: 0,
                filter_json: None,
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap();
        assert!(after.iter().all(|h| h.id != "doc-a"));

        let replaced = waffle_upsert(
            handle,
            "doc-b".to_owned(),
            vec![0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            "updated boat text".to_owned(),
            r#"{"category":"marine","price":250}"#.to_owned(),
            None,
            0,
        )
        .unwrap();
        assert!(replaced);
        assert_eq!(waffle_count(handle).unwrap(), 1);

        let page = waffle_search(
            handle,
            WaffleSearchRequest {
                vector: None,
                text: Some("boat".to_owned()),
                top_k: 5,
                offset: 1,
                filter_json: None,
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap();
        assert!(page.is_empty());

        let wiped = waffle_delete_where(
            handle,
            r#"{"op":"eq","field":"category","value":"marine"}"#.to_owned(),
        )
        .unwrap();
        assert_eq!(wiped, 1);
        assert_eq!(waffle_count(handle).unwrap(), 0);

        waffle_close(handle).unwrap();
        let _ = std::fs::remove_dir_all(path);
    }
}
