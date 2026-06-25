use std::sync::Arc;
use tokio::sync::RwLock;

use crate::api::{config::WaffleConfig, storage::WaffleStorage};

pub mod api;
mod frb_generated;

pub struct WaffleEngine {
    storage: WaffleStorage,
    config: WaffleConfig,
}

pub struct WaffleDB {
    inner: Arc<RwLock<WaffleEngine>>,
    runtime: tokio::runtime::Runtime,
}

impl WaffleDB {
    pub fn start(config: WaffleConfig) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(config.worker_threads as usize)
            .enable_all() // Enable all runtime features (timers, I/O, etc.)
            .build()
            .map_err(|e| e.to_string())?;

        let storage = WaffleStorage::init(&config)?;
        let engine = WaffleEngine { storage, config };

        Ok(Self {
            inner: Arc::new(RwLock::new(engine)),
            runtime,
        })
    }

    pub fn insert_async(&self, id: String, vector: Vec<f32>, metadata: Vec<u8>) {
        let engine_clone = self.inner.clone();

        self.runtime.spawn(async move {
            let lock = engine_clone.write().await;
            if let Err(e) = lock.storage.write_record(&id, &vector, &metadata) {
                eprintln!("[WaffleDB Error] Failed to write async: {}", e);
            }
        });
    }
}
