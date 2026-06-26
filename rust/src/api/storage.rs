use sled::{Db, Tree};

use crate::api::{config::WaffleConfig, models::VectorMetadata};

/// Low-level storage backend using Sled.
pub struct WaffleStorage {
    db: Db,
    vectors_tree: Tree,
    metadata_tree: Tree,
}

impl WaffleStorage {
    /// Initialize the storage using the given configuration.
    pub fn init(config: &WaffleConfig) -> Result<Self, String> {
        let db = sled::Config::new()
            .path(&config.path)
            .cache_capacity(config.cache_size_bytes)
            .open()
            .map_err(|e| e.to_string())?;

        let vectors_tree = db.open_tree("v_grid").map_err(|e| e.to_string())?;
        let metadata_tree = db.open_tree("m_grid").map_err(|e| e.to_string())?;

        Ok(Self {
            db,
            vectors_tree,
            metadata_tree,
        })
    }

    /// Write only the metadata for a record.
    pub fn write_metadata(
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
    pub fn write_record(&self, id: &str, vector: &[f32], metadata: &[u8]) -> Result<(), String> {
        let v_bytes = unsafe {
            std::slice::from_raw_parts(
                vector.as_ptr() as *const u8,
                std::mem::size_of_val(vector),
            )
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
    pub fn read_metadata(&self, id: &str) -> Result<Option<Vec<u8>>, String> {
        if let Some(ivec) = self.metadata_tree.get(id).map_err(|e| e.to_string())? {
            return Ok(Some(ivec.to_vec()));
        }
        Ok(None)
    }

    /// Read a vector by ID, checking against the expected dimension.
    pub fn read_vector(&self, id: &str, dim: usize) -> Result<Option<Vec<f32>>, String> {
        if let Some(ivec) = self.vectors_tree.get(id).map_err(|e| e.to_string())? {
            let expected_bytes = dim * std::mem::size_of::<f32>();
            if ivec.len() != expected_bytes {
                return Err(format!(
                    "Vector size mismatch: expected {} bytes, got {}",
                    expected_bytes,
                    ivec.len()
                ));
            }
            let floats: Vec<f32> = ivec
                .chunks_exact(4)
                .map(|chunk| f32::from_ne_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
                .collect();
            return Ok(Some(floats));
        }
        Ok(None)
    }

    /// Delete a record from storage.
    pub fn delete_record(&self, id: &str) -> Result<bool, String> {
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
    pub fn count(&self) -> u64 {
        self.vectors_tree.len() as u64
    }

    /// Flush pending storage operations to disk.
    pub fn flush(&self) -> Result<(), String> {
        self.db.flush().map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Iterates over stored vectors and yields them in batches to save RAM.
    pub fn load_vectors_in_batches<F>(
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
            let id =
                String::from_utf8(key.to_vec()).map_err(|e| format!("Invalid UTF-8 key: {}", e))?;

            if value.len() != expected_bytes {
                continue; // skip corrupted entries
            }

            let floats: Vec<f32> = value
                .chunks_exact(4)
                .map(|chunk| f32::from_ne_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
                .collect();
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
    pub fn get_all_ids(&self) -> Result<Vec<String>, String> {
        let mut ids = Vec::new();
        for item in self.vectors_tree.iter() {
            let (key, _) = item.map_err(|e| e.to_string())?;
            let id =
                String::from_utf8(key.to_vec()).map_err(|e| format!("Invalid UTF-8 key: {}", e))?;
            ids.push(id);
        }
        Ok(ids)
    }
}
