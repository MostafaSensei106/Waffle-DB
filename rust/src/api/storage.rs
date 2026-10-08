use sled::{Db, Tree};

use crate::api::{config::WaffleConfig, models::VectorMetadata};

/// Low-level storage backend using Sled.
pub(crate) struct WaffleStorage {
    db: Db,
    vectors_tree: Tree,
    metadata_tree: Tree,
    pub(crate) id_map_tree: Tree,
}

impl WaffleStorage {
    /// Initialize the storage using the given configuration.
    pub(crate) fn init(config: &WaffleConfig) -> Result<Self, String> {
        let db = sled::Config::new()
            .path(&config.path)
            .cache_capacity(config.cache_size_bytes)
            .open()
            .map_err(|e| e.to_string())?;

        let vectors_tree = db.open_tree("v_grid").map_err(|e| e.to_string())?;
        let metadata_tree = db.open_tree("m_grid").map_err(|e| e.to_string())?;
        let id_map_tree = db.open_tree("id_map").map_err(|e| e.to_string())?;

        Ok(Self {
            db,
            vectors_tree,
            metadata_tree,
            id_map_tree,
        })
    }

    /// Write only the metadata for a record.
    #[allow(dead_code)]
    pub(crate) fn write_metadata(
        &self,
        id: &str,
        _vector: &[f32],
        metadata: VectorMetadata,
    ) -> Result<bool, String> {
        let serialized = rkyv::to_bytes::<rkyv::rancor::Error>(&metadata)
            .map_err(|e| format!("Serialization error: {}", e))?;

        self.metadata_tree
            .insert(id, serialized.as_slice())
            .map_err(|e| e.to_string())?;

        Ok(true)
    }

    /// Write a full record (vector and metadata bytes) to disk.
    pub(crate) fn write_record(
        &self,
        id: &str,
        vector: &[f32],
        metadata: &[u8],
    ) -> Result<(), String> {
        let v_bytes = unsafe {
            std::slice::from_raw_parts(vector.as_ptr() as *const u8, std::mem::size_of_val(vector))
        };
        self.vectors_tree
            .insert(id, v_bytes)
            .map_err(|e| e.to_string())?;
        self.metadata_tree
            .insert(id, metadata)
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Read raw metadata bytes by ID.
    pub(crate) fn read_metadata(&self, id: &str) -> Result<Option<Vec<u8>>, String> {
        if let Some(ivec) = self.metadata_tree.get(id).map_err(|e| e.to_string())? {
            return Ok(Some(ivec.to_vec()));
        }
        Ok(None)
    }

    /// Read a vector by ID, checking against the expected dimension.
    pub(crate) fn read_vector(&self, id: &str, dim: usize) -> Result<Option<Vec<f32>>, String> {
        if let Some(ivec) = self.vectors_tree.get(id).map_err(|e| e.to_string())? {
            let expected_bytes = dim * std::mem::size_of::<f32>();
            if ivec.len() != expected_bytes {
                return Err(format!(
                    "Vector size mismatch: expected {} bytes, got {}",
                    expected_bytes,
                    ivec.len()
                ));
            }
            let mut floats = vec![0.0f32; dim];
            unsafe {
                std::ptr::copy_nonoverlapping(
                    ivec.as_ptr(),
                    floats.as_mut_ptr() as *mut u8,
                    expected_bytes,
                );
            }
            return Ok(Some(floats));
        }
        Ok(None)
    }

    /// Delete a record from storage.
    pub(crate) fn delete_record(&self, id: &str) -> Result<bool, String> {
        let v_removed = self
            .vectors_tree
            .remove(id)
            .map_err(|e| e.to_string())?
            .is_some();
        let m_removed = self
            .metadata_tree
            .remove(id)
            .map_err(|e| e.to_string())?
            .is_some();
        Ok(v_removed || m_removed)
    }

    /// Count the total number of stored vectors.
    pub(crate) fn count(&self) -> u64 {
        self.vectors_tree.len() as u64
    }

    /// Flush pending storage operations to disk.
    pub(crate) fn flush(&self) -> Result<(), String> {
        self.db.flush().map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Iterates over stored vectors and yields them in batches to save RAM.
    pub(crate) fn load_vectors_in_batches<F>(
        &self,
        dim: usize,
        batch_size: usize,
        mut f: F,
    ) -> Result<(), String>
    where
        F: FnMut(Vec<(String, Vec<f32>)>) -> Result<(), String>,
    {
        let mut batch = Vec::with_capacity(batch_size);
        let expected_bytes = dim * std::mem::size_of::<f32>();

        for item in self.vectors_tree.iter() {
            let (key, value) = item.map_err(|e| e.to_string())?;
            let id = std::str::from_utf8(&key)
                .map_err(|e| format!("Invalid UTF-8 key: {}", e))?
                .to_owned();

            if value.len() != expected_bytes {
                continue; // skip corrupted entries
            }

            let mut floats = vec![0.0f32; dim];
            unsafe {
                std::ptr::copy_nonoverlapping(
                    value.as_ptr(),
                    floats.as_mut_ptr() as *mut u8,
                    expected_bytes,
                );
            }
            batch.push((id, floats));

            if batch.len() >= batch_size {
                f(std::mem::replace(
                    &mut batch,
                    Vec::with_capacity(batch_size),
                ))?;
            }
        }

        if !batch.is_empty() {
            f(batch)?;
        }

        Ok(())
    }

    /// Returns all stored string IDs.
    pub(crate) fn get_all_ids(&self) -> Result<Vec<String>, String> {
        let count = self.vectors_tree.len();
        let mut ids = Vec::with_capacity(count);
        for item in self.vectors_tree.iter() {
            let (key, _) = item.map_err(|e| e.to_string())?;
            let id = std::str::from_utf8(&key)
                .map_err(|e| format!("Invalid UTF-8 key: {}", e))?
                .to_owned();
            ids.push(id);
        }
        Ok(ids)
    }

    /// Write a forward (internal→string) and reverse (string→internal) mapping.
    pub(crate) fn write_id_mapping(
        &self,
        internal_id: usize,
        string_id: &str,
    ) -> Result<(), String> {
        let fwd_key = format!("fwd:{}", internal_id);
        let rev_key = format!("rev:{}", string_id);
        self.id_map_tree
            .insert(fwd_key.as_bytes(), string_id.as_bytes())
            .map_err(|e| e.to_string())?;
        self.id_map_tree
            .insert(rev_key.as_bytes(), &internal_id.to_le_bytes())
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Batch write ID mappings efficiently.
    pub(crate) fn write_id_mappings_batch(&self, mappings: &[(usize, &str)]) -> Result<(), String> {
        let mut batch = sled::Batch::default();
        for (internal_id, string_id) in mappings {
            let fwd_key = format!("fwd:{}", internal_id);
            let rev_key = format!("rev:{}", string_id);
            batch.insert(fwd_key.as_bytes(), string_id.as_bytes());
            batch.insert(rev_key.as_bytes(), &internal_id.to_le_bytes());
        }
        self.id_map_tree
            .apply_batch(batch)
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Read string ID by internal ID.
    #[allow(dead_code)]
    pub(crate) fn get_string_id(&self, internal_id: usize) -> Result<Option<String>, String> {
        let fwd_key = format!("fwd:{}", internal_id);
        if let Some(ivec) = self
            .id_map_tree
            .get(fwd_key.as_bytes())
            .map_err(|e| e.to_string())?
        {
            let string_id = std::str::from_utf8(&ivec)
                .map_err(|e| e.to_string())?
                .to_owned();
            return Ok(Some(string_id));
        }
        Ok(None)
    }

    /// Read internal ID by string ID.
    #[allow(dead_code)]
    pub(crate) fn get_internal_id(&self, string_id: &str) -> Result<Option<usize>, String> {
        let rev_key = format!("rev:{}", string_id);
        if let Some(ivec) = self
            .id_map_tree
            .get(rev_key.as_bytes())
            .map_err(|e| e.to_string())?
        {
            let mut bytes = [0u8; 8];
            let len = std::cmp::min(ivec.len(), 8);
            bytes[..len].copy_from_slice(&ivec[..len]);
            return Ok(Some(usize::from_le_bytes(bytes)));
        }
        Ok(None)
    }

    /// Remove an ID mapping.
    pub(crate) fn remove_id_mapping(
        &self,
        internal_id: usize,
        string_id: &str,
    ) -> Result<(), String> {
        let fwd_key = format!("fwd:{}", internal_id);
        let rev_key = format!("rev:{}", string_id);
        self.id_map_tree
            .remove(fwd_key.as_bytes())
            .map_err(|e| e.to_string())?;
        self.id_map_tree
            .remove(rev_key.as_bytes())
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Load all ID mappings into memory (for HNSW rebuild).
    pub(crate) fn load_all_id_mappings(
        &self,
    ) -> Result<
        (
            std::collections::HashMap<usize, String>,
            std::collections::HashMap<String, usize>,
            u64,
        ),
        String,
    > {
        let mut id_map = std::collections::HashMap::new();
        let mut reverse_id_map = std::collections::HashMap::new();
        let mut next_id: u64 = 0;

        for item in self.id_map_tree.iter() {
            let (key, value) = item.map_err(|e| e.to_string())?;
            if key.starts_with(b"fwd:") {
                let internal_id_str = std::str::from_utf8(&key[4..]).map_err(|e| e.to_string())?;
                if let Ok(internal_id) = internal_id_str.parse::<usize>() {
                    let string_id = std::str::from_utf8(&value)
                        .map_err(|e| e.to_string())?
                        .to_owned();
                    id_map.insert(internal_id, string_id);
                    if internal_id as u64 >= next_id {
                        next_id = internal_id as u64 + 1;
                    }
                }
            } else if key.starts_with(b"rev:") {
                let string_id = std::str::from_utf8(&key[4..])
                    .map_err(|e| e.to_string())?
                    .to_owned();
                let mut bytes = [0u8; 8];
                let len = std::cmp::min(value.len(), 8);
                bytes[..len].copy_from_slice(&value[..len]);
                let internal_id = usize::from_le_bytes(bytes);
                reverse_id_map.insert(string_id, internal_id);
            }
        }
        Ok((id_map, reverse_id_map, next_id))
    }
}
