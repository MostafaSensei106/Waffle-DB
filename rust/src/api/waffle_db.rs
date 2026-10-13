use crate::api::config::WaffleConfig;
use crate::api::engine::WaffleEngine;
use crate::api::query::{WaffleHit, WaffleSearchRequest};
use crate::api::registry::{register, unregister, with_engine};
use crate::api::schema::WaffleSchema;
use crate::api::{reads, writes};

pub fn waffle_open(config: WaffleConfig, schema: WaffleSchema) -> std::result::Result<u64, String> {
    WaffleEngine::open(config, schema)
        .and_then(register)
        .map_err(|e| e.to_string())
}

pub fn waffle_close(handle: u64) -> std::result::Result<(), String> {
    match unregister(handle).map_err(|e| e.to_string())? {
        Some(engine) => engine.flush().map_err(|e| e.to_string()),
        None => Ok(()),
    }
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
        writes::insert(engine, id, vector, text, payload_json, parent_id, chunk_index)
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
        writes::insert_batch(
            engine,
            ids,
            vectors_flat,
            texts,
            payload_jsons,
            parent_ids,
            chunk_indices,
        )
    })
}

pub fn waffle_search(
    handle: u64,
    request: WaffleSearchRequest,
) -> std::result::Result<Vec<WaffleHit>, String> {
    with_engine(handle, |engine| reads::search(engine, &request))
}

pub fn waffle_delete(handle: u64, id: String) -> std::result::Result<bool, String> {
    with_engine(handle, |engine| writes::delete(engine, &id))
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
        writes::upsert(engine, id, vector, text, payload_json, parent_id, chunk_index)
    })
}

pub fn waffle_delete_batch(
    handle: u64,
    ids: Vec<String>,
) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| writes::delete_batch(engine, &ids))
}

pub fn waffle_delete_where(
    handle: u64,
    filter_json: String,
) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| writes::delete_where(engine, &filter_json))
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_metadata(handle: u64, id: String) -> std::result::Result<Option<Vec<u8>>, String> {
    with_engine(handle, |engine| reads::metadata(engine, &id))
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_vector(handle: u64, id: String) -> std::result::Result<Option<Vec<f32>>, String> {
    with_engine(handle, |engine| reads::vector(engine, &id))
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_count(handle: u64) -> std::result::Result<u64, String> {
    with_engine(handle, |engine| engine.store.count())
}

pub fn waffle_flush(handle: u64) -> std::result::Result<(), String> {
    with_engine(handle, |engine| engine.flush())
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
    with_engine(handle, |engine| reads::neighbors(engine, &id, window))
}

#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_parent(handle: u64, id: String) -> std::result::Result<Option<WaffleHit>, String> {
    with_engine(handle, |engine| reads::parent(engine, &id))
}
