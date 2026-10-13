use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{Context, Result};

use crate::api::config::WaffleConfig;
use crate::api::schema::WaffleSchema;
use crate::api::store::Store;
use crate::api::text::TextEngine;
use crate::api::vector::VectorEngine;

/// The live database: one handle owns all four engines plus its config.
pub(crate) struct WaffleEngine {
    pub(crate) config: WaffleConfig,
    pub(crate) schema: WaffleSchema,
    pub(crate) store: Store,
    pub(crate) vector: VectorEngine,
    pub(crate) text: TextEngine,
    pub(crate) ef_guard: Mutex<()>,
    pub(crate) dir: PathBuf,
}

impl WaffleEngine {
    pub(crate) fn open(config: WaffleConfig, schema: WaffleSchema) -> Result<Self> {
        let dir = PathBuf::from(&config.path);
        std::fs::create_dir_all(&dir)
            .with_context(|| format!("cannot create db dir {}", config.path))?;
        let dim = config.dimension as usize;
        let store = Store::open(&dir, &schema, config.dimension)
            .context("open storage engine")?;
        // Generation protocol: every committed mutation bumps mutation_seq;
        // each index stamps its own sequence only after its own work
        // completes. Any lagging index is rebuilt from storage, which is
        // always ahead. Missing keys (pre-generation databases) force a
        // one-time rebuild of both indexes.
        let (mutation, vector_seq, text_seq) = match store.seq_triple()? {
            (Some(m), Some(v), Some(t)) => (m, v, t),
            _ => (1, 0, 0),
        };
        let vector_stale = vector_seq != mutation;
        let text_stale = text_seq != mutation;
            &dir,
            dim,
            &config.graph_config.metric,
            config.graph_config.m as usize,
            config.graph_config.ef_construction as usize,
            config.graph_config.ef_search as usize,
            config.max_elements as usize,
        )
        .context("open vector engine")?;
        if vector.size() as u64 != store.count()? {
            // Storage is the source of truth. Any size mismatch means a
            // previous run crashed between engines (or the index file is
            // foreign): rebuild from scratch so neither missing vectors
            // nor stale entries survive.
            vector.reset()?;
            for (_, internal, vec) in store.all_vectors(dim)? {
                vector.add(internal, &vec)?;
            }
            vector.save(&dir)?;
        }
        let text = TextEngine::open(&dir.join("tantivy"), &schema.text_language)
            .context("open text engine")?;
        Ok(Self {
            config,
            schema,
            store,
            vector,
            text,
            ef_guard: Mutex::new(()),
            dir,
        })
    }

    pub(crate) fn flush(&self) -> Result<()> {
        self.text.commit()?;
        self.vector.save(&self.dir)?;
        Ok(())
    }
}
