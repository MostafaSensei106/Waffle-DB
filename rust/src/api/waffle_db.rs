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

/// Internal engine holding both the HNSW index and the sled storage.
struct WaffleEngine {
    index: HnswIndex,
    storage: WaffleStorage,
    config: WaffleConfig,
    /// Monotonically increasing internal ID counter for HNSW node IDs.
    next_internal_id: AtomicU64,
    /// Maps HNSW internal integer IDs → user-facing string IDs.
    id_map: Mutex<HashMap<usize, String>>,
    /// Maps user-facing string IDs → HNSW internal integer IDs (for delete tracking).
    reverse_id_map: Mutex<HashMap<String, usize>>,
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
pub fn waffle_open(config: WaffleConfig) -> Result<u64, String> {
    let storage = WaffleStorage::init(&config)?;

    let index = HnswIndex::new(
        config.max_elements as usize,
        config.dimension as usize,
        config.graph_config.m as usize,
        config.graph_config.ef_construction as usize,
        &config.graph_config.metric,
    );

    // Rebuild ID maps and HNSW index from persisted data
    let dim = config.dimension as usize;
    let all_vectors = storage.get_all_vectors(dim)?;

    let mut id_map = HashMap::new();
    let mut reverse_id_map = HashMap::new();
    let mut next_id: u64 = 0;

    if !all_vectors.is_empty() {
        // Prepare data for parallel insert
        let mut insert_data: Vec<(Vec<f32>, usize)> = Vec::with_capacity(all_vectors.len());

        for (string_id, vec_data) in &all_vectors {
            let internal_id = next_id as usize;
            id_map.insert(internal_id, string_id.clone());
            reverse_id_map.insert(string_id.clone(), internal_id);
            insert_data.push((vec_data.clone(), internal_id));
            next_id += 1;
        }

        // Build refs for parallel_insert
        let refs: Vec<(&Vec<f32>, usize)> = insert_data
            .iter()
            .map(|(v, id)| (v, *id))
            .collect();

        index.insert_slice(&refs);
    }

    let engine = WaffleEngine {
        index,
        storage,
        config,
        next_internal_id: AtomicU64::new(next_id),
        id_map: Mutex::new(id_map),
        reverse_id_map: Mutex::new(reverse_id_map),
    };

    let handle = HANDLE_COUNTER.fetch_add(1, Ordering::Relaxed);
    registry()
        .lock()
        .map_err(|e| format!("Lock poisoned: {}", e))?
        .insert(handle, engine);

    Ok(handle)
}

/// Close a WaffleDB instance: flush to disk and release resources.
pub fn waffle_close(handle: u64) -> Result<(), String> {
    let mut reg = registry()
        .lock()
        .map_err(|e| format!("Lock poisoned: {}", e))?;
    if let Some(engine) = reg.remove(&handle) {
        engine.storage.flush()?;
    }
    Ok(())
}

/// Insert a single vector with metadata.
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

        // Update maps
        {
            let mut map = engine.id_map.lock().map_err(|e| format!("Lock: {}", e))?;
            map.insert(internal_id, id.clone());
        }
        {
            let mut rmap = engine.reverse_id_map.lock().map_err(|e| format!("Lock: {}", e))?;
            rmap.insert(id, internal_id);
        }

        // Insert into HNSW index
        engine.index.insert(&vector, internal_id);

        Ok(())
    })
}

/// Batch insert multiple vectors. Vectors are passed as a flat f32 array.
/// `vectors_flat` has length `ids.len() * dimension`.
/// `metadata_list` has the same length as `ids`.
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

        // Split flat vector into individual vectors
        let vectors: Vec<Vec<f32>> = vectors_flat.chunks_exact(dim).map(|c| c.to_vec()).collect();

        // Assign internal IDs
        let base_id = engine
            .next_internal_id
            .fetch_add(n as u64, Ordering::Relaxed) as usize;

        let mut insert_data: Vec<(Vec<f32>, usize)> = Vec::with_capacity(n);

        {
            let mut id_map = engine.id_map.lock().map_err(|e| format!("Lock: {}", e))?;
            let mut rmap = engine.reverse_id_map.lock().map_err(|e| format!("Lock: {}", e))?;

            for (i, string_id) in ids.iter().enumerate() {
                let internal_id = base_id + i;
                id_map.insert(internal_id, string_id.clone());
                rmap.insert(string_id.clone(), internal_id);
                insert_data.push((vectors[i].clone(), internal_id));
            }
        }

        // Persist all records to disk
        for (i, string_id) in ids.iter().enumerate() {
            engine
                .storage
                .write_record(string_id, &vectors[i], &metadata_list[i])?;
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
pub fn waffle_query(
    handle: u64,
    vector: Vec<f32>,
    k: u32,
    ef_search: u32,
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

        let id_map = engine.id_map.lock().map_err(|e| format!("Lock: {}", e))?;

        let mut results: Vec<WaffleQueryResult> = Vec::with_capacity(raw_results.len());
        for (internal_id, distance) in raw_results {
            let string_id = id_map
                .get(&internal_id)
                .cloned()
                .unwrap_or_else(|| format!("__unknown_{}", internal_id));

            // Optionally fetch metadata
            let metadata = engine.storage.read_metadata(&string_id)?;

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
pub fn waffle_delete(handle: u64, id: String) -> Result<bool, String> {
    with_engine(handle, |engine| {
        let removed = engine.storage.delete_record(&id)?;

        // Remove from reverse map (HNSW entry stays as stale — filtered at query time)
        {
            let mut rmap = engine.reverse_id_map.lock().map_err(|e| format!("Lock: {}", e))?;
            if let Some(internal_id) = rmap.remove(&id) {
                let mut map = engine.id_map.lock().map_err(|e| format!("Lock: {}", e))?;
                map.remove(&internal_id);
            }
        }

        Ok(removed)
    })
}

/// Get metadata bytes for a vector by ID.
pub fn waffle_get_metadata(handle: u64, id: String) -> Result<Option<Vec<u8>>, String> {
    with_engine(handle, |engine| engine.storage.read_metadata(&id))
}

/// Get a stored vector by ID.
pub fn waffle_get_vector(handle: u64, id: String) -> Result<Option<Vec<f32>>, String> {
    with_engine(handle, |engine| {
        let dim = engine.config.dimension as usize;
        engine.storage.read_vector(&id, dim)
    })
}

/// Get the number of vectors stored on disk.
pub fn waffle_count(handle: u64) -> Result<u64, String> {
    with_engine(handle, |engine| Ok(engine.storage.count()))
}

/// Force flush all pending writes to disk.
pub fn waffle_flush(handle: u64) -> Result<(), String> {
    with_engine(handle, |engine| engine.storage.flush())
}

/// Get all stored string IDs.
pub fn waffle_get_all_ids(handle: u64) -> Result<Vec<String>, String> {
    with_engine(handle, |engine| engine.storage.get_all_ids())
}
