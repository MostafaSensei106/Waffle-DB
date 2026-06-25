use flutter_rust_bridge::frb;
use hnsw_rs::anndists::dist::{DistCosine, DistDot, DistL2};
use hnsw_rs::api::AnnT;
use hnsw_rs::hnsw::Hnsw;
use hnsw_rs::hnswio::HnswIo;
use std::path::Path;

use crate::api::config::WaffleMetric;

/// Creates an HNSW index with the correct distance metric based on config.
/// Returns a type-erased wrapper since Hnsw is generic over the distance type.
#[frb(ignore)]
pub enum HnswIndex {
    Cosine(Hnsw<'static, f32, DistCosine>),
    Euclidean(Hnsw<'static, f32, DistL2>),
    DotProduct(Hnsw<'static, f32, DistDot>),
}

impl HnswIndex {
    pub fn new(
        max_elements: usize,
        _dimension: usize,
        m: usize,
        ef_construction: usize,
        metric: &WaffleMetric,
    ) -> Self {
        match metric {
            WaffleMetric::Cosine => {
                HnswIndex::Cosine(Hnsw::new(m, max_elements, 16, ef_construction, DistCosine))
            }
            WaffleMetric::Euclidean => {
                HnswIndex::Euclidean(Hnsw::new(m, max_elements, 16, ef_construction, DistL2))
            }
            WaffleMetric::DotProduct => {
                HnswIndex::DotProduct(Hnsw::new(m, max_elements, 16, ef_construction, DistDot))
            }
        }
    }

    pub fn insert(&self, data: &[f32], id: usize) {
        match self {
            HnswIndex::Cosine(h) => h.insert((data, id)),
            HnswIndex::Euclidean(h) => h.insert((data, id)),
            HnswIndex::DotProduct(h) => h.insert((data, id)),
        }
    }

    pub fn insert_slice(&self, data: &[(&Vec<f32>, usize)]) {
        match self {
            HnswIndex::Cosine(h) => h.parallel_insert(data),
            HnswIndex::Euclidean(h) => h.parallel_insert(data),
            HnswIndex::DotProduct(h) => h.parallel_insert(data),
        }
    }

    pub fn search(&self, query: &[f32], k: usize, ef_search: usize) -> Vec<(usize, f32)> {
        match self {
            HnswIndex::Cosine(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
            HnswIndex::Euclidean(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
            HnswIndex::DotProduct(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
        }
    }

    pub fn get_nb_point(&self) -> usize {
        match self {
            HnswIndex::Cosine(h) => h.get_nb_point(),
            HnswIndex::Euclidean(h) => h.get_nb_point(),
            HnswIndex::DotProduct(h) => h.get_nb_point(),
        }
    }

    pub fn save(&self, path: &Path, file_basename: &str) -> Result<(), String> {
        match self {
            HnswIndex::Cosine(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
            HnswIndex::Euclidean(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
            HnswIndex::DotProduct(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    pub fn load(path: &Path, file_basename: &str, metric: &WaffleMetric) -> Result<Self, String> {
        let reloader = Box::leak(Box::new(HnswIo::new(path, file_basename)));
        match metric {
            WaffleMetric::Cosine => {
                let h: Hnsw<'static, f32, DistCosine> = reloader
                    .load_hnsw::<f32, DistCosine>()
                    .map_err(|e| e.to_string())?;
                Ok(HnswIndex::Cosine(h))
            }
            WaffleMetric::Euclidean => {
                let h: Hnsw<'static, f32, DistL2> = reloader
                    .load_hnsw::<f32, DistL2>()
                    .map_err(|e| e.to_string())?;
                Ok(HnswIndex::Euclidean(h))
            }
            WaffleMetric::DotProduct => {
                let h: Hnsw<'static, f32, DistDot> = reloader
                    .load_hnsw::<f32, DistDot>()
                    .map_err(|e| e.to_string())?;
                Ok(HnswIndex::DotProduct(h))
            }
        }
    }
}

/// Standalone cosine similarity for Dart FFI use.
pub fn cosine_similarity(a: Vec<f32>, b: Vec<f32>) -> f32 {
    let mut dot = 0.0f32;
    let mut norm_a = 0.0f32;
    let mut norm_b = 0.0f32;

    for i in 0..a.len() {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }

    dot / (norm_a.sqrt() * norm_b.sqrt())
}
