use flutter_rust_bridge::frb;
use hnsw_rs::anndists::dist::{DistCosine, DistDot, DistL2};
use hnsw_rs::hnsw::Hnsw;

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
        dimension: usize,
        m: usize,
        ef_construction: usize,
        metric: &WaffleMetric,
    ) -> Self {
        match metric {
            WaffleMetric::Cosine => {
                HnswIndex::Cosine(Hnsw::new(max_elements, dimension, m, ef_construction, DistCosine))
            }
            WaffleMetric::Euclidean => {
                HnswIndex::Euclidean(Hnsw::new(max_elements, dimension, m, ef_construction, DistL2))
            }
            WaffleMetric::DotProduct => {
                HnswIndex::DotProduct(Hnsw::new(max_elements, dimension, m, ef_construction, DistDot))
            }
        }
    }

    pub fn insert(&self, data: &Vec<f32>, id: usize) {
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
