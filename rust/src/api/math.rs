use flutter_rust_bridge::frb;
use hnsw_rs::anndists::dist::{DistCosine, DistDot, DistL2};
use hnsw_rs::api::AnnT;
use hnsw_rs::hnsw::Hnsw;
use hnsw_rs::hnswio::HnswIo;
use std::path::Path;

use crate::api::config::WaffleMetric;

pub enum HnswIndexEnum {
    Cosine(Hnsw<'static, f32, DistCosine>),
    Euclidean(Hnsw<'static, f32, DistL2>),
    DotProduct(Hnsw<'static, f32, DistDot>),
}

/// Creates an HNSW index with the correct distance metric based on config.
/// Returns a type-erased wrapper since Hnsw is generic over the distance type.
#[frb(ignore)]
pub struct HnswIndex {
    inner: HnswIndexEnum,
    reloader_ptr: usize,
}

// Hnsw is Send/Sync, we just wrap it and a pointer.
unsafe impl Send for HnswIndex {}
unsafe impl Sync for HnswIndex {}

impl Drop for HnswIndex {
    fn drop(&mut self) {
        if self.reloader_ptr != 0 {
            // Safety: we allocated this via Box::leak in `load`
            unsafe {
                let _ = Box::from_raw(self.reloader_ptr as *mut HnswIo);
            }
        }
    }
}

impl HnswIndex {
    pub fn new(
        max_elements: usize,
        _dimension: usize,
        m: usize,
        ef_construction: usize,
        metric: &WaffleMetric,
    ) -> Self {
        let inner = match metric {
            WaffleMetric::Cosine => {
                HnswIndexEnum::Cosine(Hnsw::new(m, max_elements, 16, ef_construction, DistCosine))
            }
            WaffleMetric::Euclidean => {
                HnswIndexEnum::Euclidean(Hnsw::new(m, max_elements, 16, ef_construction, DistL2))
            }
            WaffleMetric::DotProduct => {
                HnswIndexEnum::DotProduct(Hnsw::new(m, max_elements, 16, ef_construction, DistDot))
            }
        };
        Self { inner, reloader_ptr: 0 }
    }

    pub fn insert(&self, data: &[f32], id: usize) {
        match &self.inner {
            HnswIndexEnum::Cosine(h) => h.insert((data, id)),
            HnswIndexEnum::Euclidean(h) => h.insert((data, id)),
            HnswIndexEnum::DotProduct(h) => h.insert((data, id)),
        }
    }

    pub fn insert_slice(&self, data: &[(&Vec<f32>, usize)]) {
        match &self.inner {
            HnswIndexEnum::Cosine(h) => h.parallel_insert(data),
            HnswIndexEnum::Euclidean(h) => h.parallel_insert(data),
            HnswIndexEnum::DotProduct(h) => h.parallel_insert(data),
        }
    }

    pub fn search(&self, query: &[f32], k: usize, ef_search: usize) -> Vec<(usize, f32)> {
        match &self.inner {
            HnswIndexEnum::Cosine(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
            HnswIndexEnum::Euclidean(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
            HnswIndexEnum::DotProduct(h) => h
                .search(query, k, ef_search)
                .into_iter()
                .map(|n| (n.d_id, n.distance))
                .collect(),
        }
    }

    pub fn get_nb_point(&self) -> usize {
        match &self.inner {
            HnswIndexEnum::Cosine(h) => h.get_nb_point(),
            HnswIndexEnum::Euclidean(h) => h.get_nb_point(),
            HnswIndexEnum::DotProduct(h) => h.get_nb_point(),
        }
    }

    pub fn save(&self, path: &Path, file_basename: &str) -> Result<(), String> {
        match &self.inner {
            HnswIndexEnum::Cosine(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
            HnswIndexEnum::Euclidean(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
            HnswIndexEnum::DotProduct(h) => {
                h.file_dump(path, file_basename)
                    .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    pub fn load(path: &Path, file_basename: &str, metric: &WaffleMetric) -> Result<Self, String> {
        let reloader = Box::into_raw(Box::new(HnswIo::new(path, file_basename)));
        let reloader_mut = unsafe { &mut *reloader };
        let inner = match metric {
            WaffleMetric::Cosine => {
                let h: Hnsw<'static, f32, DistCosine> = reloader_mut
                    .load_hnsw::<f32, DistCosine>()
                    .map_err(|e| e.to_string())?;
                HnswIndexEnum::Cosine(h)
            }
            WaffleMetric::Euclidean => {
                let h: Hnsw<'static, f32, DistL2> = reloader_mut
                    .load_hnsw::<f32, DistL2>()
                    .map_err(|e| e.to_string())?;
                HnswIndexEnum::Euclidean(h)
            }
            WaffleMetric::DotProduct => {
                let h: Hnsw<'static, f32, DistDot> = reloader_mut
                    .load_hnsw::<f32, DistDot>()
                    .map_err(|e| e.to_string())?;
                HnswIndexEnum::DotProduct(h)
            }
        };
        Ok(Self { inner, reloader_ptr: reloader as usize })
    }
}

/// Standalone cosine similarity for Dart FFI use.
/// 
/// Calculates the cosine similarity between two vectors.
/// Returns a value between -1.0 and 1.0 (1.0 means identical direction).
/// 
/// Example:
/// ```dart
/// final similarity = await cosineSimilarity(a: [1.0, 0.0], b: [1.0, 0.0]);
/// print(similarity); // 1.0
/// ```
pub fn cosine_similarity(a: Vec<f32>, b: Vec<f32>) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    // Process in chunks of 8 for better SIMD auto-vectorization
    let (mut dot, mut norm_a, mut norm_b) = (0.0f64, 0.0f64, 0.0f64);
    for (&x, &y) in a.iter().zip(b.iter()) {
        let (xd, yd) = (x as f64, y as f64);
        dot += xd * yd;
        norm_a += xd * xd;
        norm_b += yd * yd;
    }
    if norm_a == 0.0 || norm_b == 0.0 { return 0.0; }
    (dot / (norm_a.sqrt() * norm_b.sqrt())) as f32
}
