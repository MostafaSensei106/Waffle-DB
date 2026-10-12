use std::path::Path;

use roaring::RoaringBitmap;
use usearch::{Index, IndexOptions, MetricKind, ScalarKind};

use crate::api::config::WaffleMetric;
use anyhow::{Result, anyhow};

pub(crate) struct VectorEngine {
    index: Index,
}

fn map_metric(metric: &WaffleMetric) -> MetricKind {
    match metric {
        WaffleMetric::Cosine => MetricKind::Cos,
        WaffleMetric::Euclidean => MetricKind::L2sq,
        WaffleMetric::DotProduct => MetricKind::IP,
    }
}

impl VectorEngine {
    pub(crate) fn open(
        dir: &Path,
        dimension: usize,
        metric: &WaffleMetric,
        connectivity: usize,
        expansion_add: usize,
        expansion_search: usize,
        capacity: usize,
    ) -> Result<Self> {
        let file = dir.join("vectors.usearch");
        if file.exists() {
            if let Ok(index) = Index::restore(file.to_string_lossy().as_ref()) {
                return Ok(Self { index });
            }
        }
        let options = IndexOptions {
            dimensions: dimension,
            metric: map_metric(metric),
            quantization: ScalarKind::F32,
            connectivity,
            expansion_add,
            expansion_search,
            multi: false,
        };
        let index = Index::new(&options)?;
        index.reserve(capacity.max(1024))?;
        Ok(Self { index })
    }

    pub(crate) fn add(&self, internal: u32, vector: &[f32]) -> Result<()> {
        self.index.add(internal as u64, vector)?;
        Ok(())
    }

    pub(crate) fn search(
        &self,
        query: &[f32],
        k: usize,
        allowed: Option<&RoaringBitmap>,
    ) -> Result<Vec<(u32, f32)>> {
        if k == 0 {
            return Ok(Vec::new());
        }
        let matches = match allowed {
            Some(bitmap) => self
                .index
                .filtered_search(query, k, |key: u64| bitmap.contains(key as u32))?,
            None => self.index.search(query, k)?,
        };
        Ok(matches
            .keys
            .iter()
            .zip(matches.distances.iter())
            .map(|(&key, &dist)| (key as u32, dist))
            .collect())
    }

    pub(crate) fn override_expansion_search(&self, ef: usize) {
        self.index.change_expansion_search(ef);
    }

    pub(crate) fn remove(&self, internal: u32) -> Result<bool> {
        Ok(self.index.remove(internal as u64)? > 0)
    }

    pub(crate) fn contains(&self, internal: u32) -> bool {
        self.index.contains(internal as u64)
    }

    pub(crate) fn size(&self) -> usize {
        self.index.size()
    }

    pub(crate) fn save(&self, dir: &Path) -> Result<()> {
        if self.index.size() == 0 {
            return Ok(());
        }
        std::fs::create_dir_all(dir)
            .map_err(|e| anyhow!("cannot create dir: {e}"))?;
        self.index
            .save(dir.join("vectors.usearch").to_string_lossy().as_ref())?;
        Ok(())
    }
}
