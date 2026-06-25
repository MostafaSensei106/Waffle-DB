use hnsw_rs::{anndists::dist::DistCosine, hnsw::Hnsw};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::api::{config::WaffleConfig, storage::WaffleStorage};

pub mod api;
mod frb_generated;

pub struct WaffleEngine {
    pub index: Hnsw<'static, f32, DistCosine>,
    pub storage: WaffleStorage,
    pub config: WaffleConfig,
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

        let index = Hnsw::new(
            config.max_elements as usize,
            config.dimension as usize,
            config.graph_config.m as usize,
            config.graph_config.ef_construction as usize,
            DistCosine,
        );
        let engine = WaffleEngine {
            index,
            storage,
            config: config.clone(),
        };

        Ok(Self {
            inner: Arc::new(RwLock::new(engine)),
            runtime,
        })
    }

    pub fn insert_async(
        &self,
        internal_id: u128,
        string_id: String,
        vector: Vec<f32>,
        metadata: Vec<u8>,
    ) {
        let engine_clone = self.inner.clone();

        self.runtime.spawn(async move {
            let lock = engine_clone.write().await;

            if let Err(e) = lock.storage.write_record(&string_id, &vector, &metadata) {
                eprintln!("[WaffleDB Error] Failed to write to disk: {}", e);
                return;
            }

            lock.index.insert((&vector, internal_id as usize));
        });
    }

    pub async fn query(&self, query_vector: Vec<f32>, k: usize) -> Vec<(u128, f32)> {
        let lock = self.inner.read().await;

        let ef_search = lock.config.graph_config.ef_search;
        let neighbors = lock.index.search(&query_vector, k, ef_search as usize);

        neighbors
            .into_iter()
            .map(|neighbor| (neighbor.d_id as u128, neighbor.distance))
            .collect()
    }
}
