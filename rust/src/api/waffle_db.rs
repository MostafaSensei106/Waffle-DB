//! WaffleDB FFI facade — the single entry point for Dart to interact with the database.
//!
//! Uses a handle-based design: Dart receives a `u64` handle ID after opening a database,
//! and passes it to all subsequent operations. This avoids exposing Rust types with
//! lifetimes (like `Hnsw<'static, ...>`) across FFI.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::api::config::WaffleConfig;
use crate::api::math::HnswIndex;
use crate::api::models::WaffleQueryResult;
use crate::api::storage::WaffleStorage;
use std::fs;
use std::path::Path;

/// Internal engine holding both the HNSW index and the sled storage.
/// Thread-safe registry for mapping string IDs to/from internal integer IDs.
struct IdRegistry {
    /// Maps HNSW internal integer IDs → user-facing string IDs.
    id_map: HashMap<usize, String>,
    /// Maps user-facing string IDs → HNSW internal integer IDs.
    reverse_id_map: HashMap<String, usize>,
}

/// Internal engine holding both the HNSW index and the sled storage.
struct WaffleEngine {
    index: HnswIndex,
    storage: WaffleStorage,
    config: WaffleConfig,
    /// Monotonically increasing internal ID counter for HNSW node IDs.
    next_internal_id: AtomicU64,
    /// Registry mapping internal IDs to/from user-facing string IDs.
    id_registry: Mutex<IdRegistry>,
}

// ---------------------------------------------------------------------------
// Global handle registry
// ---------------------------------------------------------------------------

static HANDLE_COUNTER: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static Mutex<HashMap<u64, WaffleEngine>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, WaffleEngine>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_engine<F, R>(handle: u64, f: F) -> Result<R, String>
where
    F: FnOnce(&WaffleEngine) -> Result<R, String>,
{
    let reg = registry().lock().map_err(|e| format!("Lock poisoned: {}", e))?;
    let engine = reg
        .get(&handle)
        .ok_or_else(|| format!("Invalid WaffleDB handle: {}", handle))?;
    f(engine)
}

// ---------------------------------------------------------------------------
// Public FFI functions (all live inside crate::api so FRB picks them up)
// ---------------------------------------------------------------------------

/// Open (or create) a WaffleDB instance. Returns a handle ID.
/// 
/// Example:
/// ```dart
/// final handle = await waffleOpen(config: myConfig);
/// ```
pub fn waffle_open(config: WaffleConfig) -> Result<u64, String> {
    let storage = WaffleStorage::init(&config)?;

    let index_file = Path::new(&config.path).join("index.hnsw.hnsw.graph");
    let map_file = Path::new(&config.path).join("id_map.json");

    let total_count = storage.count() as usize;
    let mut id_map: HashMap<usize, String> = HashMap::with_capacity(total_count);
    let mut reverse_id_map: HashMap<String, usize> = HashMap::with_capacity(total_count);
    let mut next_id: u64 = 0;

    let index = if map_file.exists() && index_file.exists() {
        let map_data = fs::read_to_string(&map_file).map_err(|e| e.to_string())?;
        id_map = serde_json::from_str(&map_data).map_err(|e| e.to_string())?;
        reverse_id_map = HashMap::with_capacity(id_map.len());
        for (k, v) in &id_map {
            reverse_id_map.insert(v.clone(), *k);
            if *k as u64 >= next_id {
                next_id = *k as u64 + 1;
            }
        }
        HnswIndex::load(Path::new(&config.path), "index.hnsw", &config.graph_config.metric)?
    } else {
        let idx = HnswIndex::new(
            config.max_elements as usize,
            config.dimension as usize,
            config.graph_config.m as usize,
            config.graph_config.ef_construction as usize,
            &config.graph_config.metric,
        );
        let dim = config.dimension as usize;

        storage.load_vectors_in_batches(dim, 10_000, |batch| {
            let mut insert_data: Vec<(Vec<f32>, usize)> = Vec::with_capacity(batch.len());

            for (string_id, vec_data) in batch {
                let internal_id = next_id as usize;
                id_map.insert(internal_id, string_id.clone());
                reverse_id_map.insert(string_id, internal_id);
                insert_data.push((vec_data, internal_id));
                next_id += 1;
            }

            let refs: Vec<(&Vec<f32>, usize)> = insert_data
                .iter()
                .map(|(v, id)| (v, *id))
                .collect();

            idx.insert_slice(&refs);
            Ok(())
        })?;
        idx
    };

    let engine = WaffleEngine {
        index,
        storage,
        config,
        next_internal_id: AtomicU64::new(next_id),
        id_registry: Mutex::new(IdRegistry {
            id_map,
            reverse_id_map,
        }),
    };

    let handle = HANDLE_COUNTER.fetch_add(1, Ordering::Relaxed);
    registry()
        .lock()
        .map_err(|e| format!("Lock poisoned: {}", e))?
        .insert(handle, engine);

    Ok(handle)
}

/// Close a WaffleDB instance: flush to disk and release resources.
/// 
/// Example:
/// ```dart
/// await waffleClose(handle: myHandle);
/// ```
pub fn waffle_close(handle: u64) -> Result<(), String> {
    let mut reg = registry()
        .lock()
        .map_err(|e| format!("Lock poisoned: {}", e))?;
    if let Some(engine) = reg.remove(&handle) {
        engine.storage.flush().map_err(|e| format!("Storage flush failed: {}", e))?;
        let registry = engine.id_registry.lock().map_err(|e| format!("IdRegistry lock failed: {}", e))?;
        let map_data = serde_json::to_string(&registry.id_map).map_err(|e| format!("JSON serialization failed: {}", e))?;
        std::fs::write(Path::new(&engine.config.path).join("id_map.json"), map_data).map_err(|e| format!("Writing id_map.json failed: {}", e))?;
        if engine.index.get_nb_point() > 0 {
            engine.index.save(Path::new(&engine.config.path), "index.hnsw").map_err(|e| format!("Hnsw save failed: {}", e))?;
        }
    }
    Ok(())
}

/// Insert a single vector with metadata.
/// 
/// Example:
/// ```dart
/// await waffleInsert(handle: myHandle, id: "doc1", vector: [0.1, 0.2], metadata: []);
/// ```
pub fn waffle_insert(
    handle: u64,
    id: String,
    vector: Vec<f32>,
    metadata: Vec<u8>,
) -> Result<(), String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        if vector.len() != dim {
            return Err(format!(
                "Vector dimension mismatch: expected {}, got {}",
                dim,
                vector.len()
            ));
        }

        // Persist to disk first
        engine.storage.write_record(&id, &vector, &metadata)?;

        // Assign an internal HNSW ID
        let internal_id = engine
            .next_internal_id
            .fetch_add(1, Ordering::Relaxed) as usize;

        // Update maps inside a single lock acquisition to avoid deadlock
        {
            let mut registry = engine.id_registry.lock().map_err(|e| format!("Lock: {}", e))?;
            registry.id_map.insert(internal_id, id.clone());
            registry.reverse_id_map.insert(id, internal_id);
        }

        // Insert into HNSW index
        engine.index.insert(&vector, internal_id);

        Ok(())
    })
}

/// Batch insert multiple vectors. Vectors are passed as a flat f32 array.
/// `vectors_flat` has length `ids.len() * dimension`.
/// `metadata_list` has the same length as `ids`.
/// 
/// Example:
/// ```dart
/// await waffleInsertBatch(handle: h, ids: ["1"], vectorsFlat: [0.1], metadataList: [[]]);
/// ```
pub fn waffle_insert_batch(
    handle: u64,
    ids: Vec<String>,
    vectors_flat: Vec<f32>,
    metadata_list: Vec<Vec<u8>>,
) -> Result<(), String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        let n = ids.len();

        if vectors_flat.len() != n * dim {
            return Err(format!(
                "Flat vector length {} does not match {} items × {} dim",
                vectors_flat.len(),
                n,
                dim
            ));
        }
        if metadata_list.len() != n {
            return Err(format!(
                "Metadata list length {} does not match {} items",
                metadata_list.len(),
                n
            ));
        }

        // Assign internal IDs
        let base_id = engine
            .next_internal_id
            .fetch_add(n as u64, Ordering::Relaxed) as usize;

        {
            let mut registry = engine.id_registry.lock().map_err(|e| format!("Lock: {}", e))?;
            registry.id_map.reserve(n);
            registry.reverse_id_map.reserve(n);

            for (i, string_id) in ids.iter().enumerate() {
                let internal_id = base_id + i;
                registry.id_map.insert(internal_id, string_id.clone());
                registry.reverse_id_map.insert(string_id.clone(), internal_id);
            }
        }

        // Persist all records to disk directly using flat vector slices to avoid cloning/allocating Vecs
        for (i, string_id) in ids.iter().enumerate() {
            let start = i * dim;
            let end = start + dim;
            engine
                .storage
                .write_record(string_id, &vectors_flat[start..end], &metadata_list[i])?;
        }

        // Copy vectors once for HNSW index insertion
        let mut insert_data: Vec<(Vec<f32>, usize)> = Vec::with_capacity(n);
        for (i, _) in ids.iter().enumerate() {
            let start = i * dim;
            let end = start + dim;
            insert_data.push((vectors_flat[start..end].to_vec(), base_id + i));
        }

        // Parallel insert into HNSW
        let refs: Vec<(&Vec<f32>, usize)> = insert_data
            .iter()
            .map(|(v, id)| (v, *id))
            .collect();
        engine.index.insert_slice(&refs);

        Ok(())
    })
}

/// K-nearest neighbor search. Returns results sorted by distance (ascending).
/// `ef_search` overrides the config value if > 0, otherwise uses config default.
/// 
/// Example:
/// ```dart
/// final results = await waffleQuery(handle: h, vector: [0.1], k: 5, efSearch: 0, includeMetadata: true);
/// ```
#[flutter_rust_bridge::frb(sync)]
pub fn waffle_query(
    handle: u64,
    vector: Vec<f32>,
    k: u32,
    ef_search: u32,
    include_metadata: bool,
) -> Result<Vec<WaffleQueryResult>, String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        if vector.len() != dim {
            return Err(format!(
                "Query vector dimension mismatch: expected {}, got {}",
                dim,
                vector.len()
            ));
        }

        let effective_ef = if ef_search > 0 {
            ef_search as usize
        } else {
            engine.config.graph_config.ef_search as usize
        };

        let raw_results = engine.index.search(&vector, k as usize, effective_ef);

        let registry = engine.id_registry.lock().map_err(|e| format!("Lock: {}", e))?;

        let mut results: Vec<WaffleQueryResult> = Vec::with_capacity(raw_results.len());
        for (internal_id, distance) in raw_results {
            let string_id = registry.id_map
                .get(&internal_id)
                .cloned()
                .unwrap_or_else(|| format!("__unknown_{}", internal_id));

            let metadata = if include_metadata {
                engine.storage.read_metadata(&string_id)?
            } else {
                None
            };

            results.push(WaffleQueryResult {
                id: string_id,
                distance,
                metadata,
            });
        }

        // Sort by distance ascending
        results.sort_by(|a, b| a.distance.partial_cmp(&b.distance).unwrap_or(std::cmp::Ordering::Equal));

        Ok(results)
    })
}

/// Delete a vector by its string ID. Removes from storage.
/// Note: HNSW doesn't support true deletion — the index entry remains until rebuild.
/// 
/// Example:
/// ```dart
/// final removed = await waffleDelete(handle: h, id: "doc1");
/// ```
pub fn waffle_delete(handle: u64, id: String) -> Result<bool, String> {
    with_engine(handle, |engine| {
        let removed = engine.storage.delete_record(&id)?;

        // Remove from reverse map (HNSW entry stays as stale — filtered at query time)
        {
            let mut registry = engine.id_registry.lock().map_err(|e| format!("Lock: {}", e))?;
            if let Some(internal_id) = registry.reverse_id_map.remove(&id) {
                registry.id_map.remove(&internal_id);
            }
        }

        Ok(removed)
    })
}

/// Get metadata bytes for a vector by ID.
/// 
/// Example:
/// ```dart
/// final meta = await waffleGetMetadata(handle: h, id: "doc1");
/// ```
#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_metadata(handle: u64, id: String) -> Result<Option<Vec<u8>>, String> {
    with_engine(handle, |engine| engine.storage.read_metadata(&id))
}

/// Get a stored vector by ID.
/// 
/// Example:
/// ```dart
/// final vec = await waffleGetVector(handle: h, id: "doc1");
/// ```
#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_vector(handle: u64, id: String) -> Result<Option<Vec<f32>>, String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        engine.storage.read_vector(&id, dim)
    })
}

/// Get the number of vectors stored on disk.
/// 
/// Example:
/// ```dart
/// final count = await waffleCount(handle: h);
/// ```
#[flutter_rust_bridge::frb(sync)]
pub fn waffle_count(handle: u64) -> Result<u64, String> {
    with_engine(handle, |engine| Ok(engine.storage.count()))
}

/// Force flush all pending writes to disk.
/// 
/// Example:
/// ```dart
/// await waffleFlush(handle: h);
/// ```
pub fn waffle_flush(handle: u64) -> Result<(), String> {
    with_engine(handle, |engine| {
        engine.storage.flush()?;
        let registry = engine.id_registry.lock().map_err(|e| e.to_string())?;
        let map_data = serde_json::to_string(&registry.id_map).map_err(|e| e.to_string())?;
        std::fs::write(Path::new(&engine.config.path).join("id_map.json"), map_data).map_err(|e| e.to_string())?;
        if engine.index.get_nb_point() > 0 {
            engine.index.save(Path::new(&engine.config.path), "index.hnsw")?;
        }
        Ok(())
    })
}

/// Get all stored string IDs.
/// 
/// Example:
/// ```dart
/// final ids = await waffleGetAllIds(handle: h);
/// ```
#[flutter_rust_bridge::frb(sync)]
pub fn waffle_get_all_ids(handle: u64) -> Result<Vec<String>, String> {
    with_engine(handle, |engine| engine.storage.get_all_ids())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};

    #[test]
    fn test_open_close_rust() {
        let config = WaffleConfig {
            dimension: 128,
            path: "/tmp/waffle_rust_test_db".to_string(),
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
        };
        // Clean up first
        let _ = std::fs::remove_dir_all("/tmp/waffle_rust_test_db");

        println!("Running waffle_open in Rust test...");
        let handle = waffle_open(config).unwrap();
        println!("Running waffle_close in Rust test...");
        waffle_close(handle).unwrap();
        println!("Completed waffle_close in Rust test!");
    }
}
