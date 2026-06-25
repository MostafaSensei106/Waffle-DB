use sled::Tree;

use crate::api::{
    config::WaffleConfig,
    models::{ArchivedVectorMetadata, VectorMetadata},
};

pub struct WaffleStorage {
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
            vectors_tree,
            metadata_tree,
        })
    }

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

    pub fn write_record(&self, id: &str, vector: &[f32], metadata: &[u8]) -> Result<(), String> {
        let v_bytes = unsafe {
            std::slice::from_raw_parts(
                vector.as_ptr() as *const u8,
                vector.len() * std::mem::size_of::<f32>(),
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

    pub fn read_metadata(&self, id: &str) -> Result<Option<Vec<u8>>, String> {
        if let Some(ivec) = self.metadata_tree.get(id).map_err(|e| e.to_string())? {
            let archived = unsafe { rkyv::access_unchecked::<ArchivedVectorMetadata>(&ivec) };
            println!("Reading archived category directly: {}", archived.category);
            return Ok(Some(ivec.to_vec()));
        }
        Ok(None)
    }
}
