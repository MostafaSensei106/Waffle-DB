use sled::{Db, Tree};

use crate::api::{config::WaffleConfig, models::VectorMetadata};

pub struct WaffleStorage {
    db: Db,
    vectors_tree: Tree,
    metadata_tree: Tree,
}

impl WaffleStorage {
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

    pub fn write_metadata(
        &self,
        id: &str,
        vector: &[f32],
        metadata: VectorMetadata,
    ) -> Result<bool, String> {
        let serialized =
            to_bytes::<_, 256>(metadata).map_err(|e| format!("Serialization error: {}", e))?;

        self.metadata_tree
            .insert(id, serialized.as_slice())
            .map_err(|e| e.to_string())?;

        Ok(true)
    }

    pub fn read_metadata(&self, id: &str) -> Result<Option<Vec<u8>>, String> {
        if let Some(ivec) = self.metadata_tree.get(id).map_err(|e| e.to_string())? {
            let archived = unsafe { rkyv::archived_root::<VectorMetadata>(&ivec) };
            println!("Reading archived category directly: {}", archived.category);
            return Ok(Some(ivec.to_vec()));
        }
        Ok(None)
    }
}
