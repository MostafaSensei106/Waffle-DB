use std::path::{Path, PathBuf};
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
    fn rebuild_vectors(
        dir: &Path,
        config: &WaffleConfig,
        dim: usize,
        store: &Store,
        mutation: u64,
    ) -> Result<VectorEngine> {
        let fresh = VectorEngine::fresh(
            dim,
            &config.graph_config.metric,
            config.graph_config.m as usize,
            config.graph_config.ef_construction as usize,
            config.graph_config.ef_search as usize,
            config.max_elements as usize,
        )?;
        for (_, internal, vec) in store.all_vectors(dim)? {
            fresh.add(internal, &vec)?;
        }
        fresh.save(dir)?;
        store.set_vector_seq(mutation)?;
        Ok(fresh)
    }

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
        let (mutation, vector_stale, text_stale) = store.ensure_generations()?;

        let vector = if vector_stale {
            Self::rebuild_vectors(&dir, &config, dim, &store, mutation)?
        } else {
            match VectorEngine::open(
                &dir,
                dim,
                &config.graph_config.metric,
                config.graph_config.m as usize,
                config.graph_config.ef_construction as usize,
                config.graph_config.ef_search as usize,
                config.max_elements as usize,
            ) {
                Ok(vector) if vector.size() as u64 == store.count()? => vector,
                _ => Self::rebuild_vectors(&dir, &config, dim, &store, mutation)?,
            }
        };
        let tantivy_dir = dir.join("tantivy");
        let existed = tantivy_dir.exists();
        let text = match TextEngine::open(&tantivy_dir, &schema.text_language) {
            Ok(t) if !text_stale && (existed || store.count()? == 0) => t,
            _ => {
                let rebuilt = TextEngine::rebuild(
                    &tantivy_dir,
                    &schema.text_language,
                    &store.all_texts()?,
                )?;
                store.set_text_seq(mutation)?;
                rebuilt
            }
        };
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::config::WaffleGraphConfig;
    use crate::api::config::WaffleMetric;
    use crate::api::query::WaffleSearchRequest;
    use crate::api::schema::{WaffleField, WaffleFieldType, WaffleLanguage};
    use crate::api::{reads, writes};

    fn schema() -> WaffleSchema {
        WaffleSchema {
            fields: vec![WaffleField {
                name: "cat".to_owned(),
                field_type: WaffleFieldType::String,
                indexed: true,
            }],
            text_language: WaffleLanguage::English,
        }
    }

    fn config(path: &str) -> WaffleConfig {
        WaffleConfig {
            dimension: 4,
            path: path.to_owned(),
            graph_config: WaffleGraphConfig {
                m: 8,
                metric: WaffleMetric::Cosine,
                ef_construction: 32,
                ef_search: 16,
            },
            max_elements: 1000,
            use_quantization: false,
            cache_size_bytes: 1024 * 1024,
            worker_threads: 1,
        }
    }

    fn seed(path: &str) -> WaffleEngine {
        let engine = WaffleEngine::open(config(path), schema()).unwrap();
        writes::insert(
            &engine,
            "a".to_owned(),
            vec![1.0, 0.0, 0.0, 0.0],
            "alpha bravo".to_owned(),
            r#"{"cat":"x"}"#.to_owned(),
            None,
            0,
        )
        .unwrap();
        writes::insert(
            &engine,
            "b".to_owned(),
            vec![0.0, 1.0, 0.0, 0.0],
            "charlie delta".to_owned(),
            r#"{"cat":"y"}"#.to_owned(),
            None,
            0,
        )
        .unwrap();
        engine
    }

    fn dense_query(engine: &WaffleEngine, v: Vec<f32>) -> Vec<String> {
        reads::search(
            engine,
            &WaffleSearchRequest {
                vector: Some(v),
                text: None,
                top_k: 5,
                offset: 0,
                filter_json: None,
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap()
        .into_iter()
        .map(|h| h.id)
        .collect()
    }

    fn text_query(engine: &WaffleEngine, q: &str) -> Vec<String> {
        reads::search(
            engine,
            &WaffleSearchRequest {
                vector: None,
                text: Some(q.to_owned()),
                top_k: 5,
                offset: 0,
                filter_json: None,
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap()
        .into_iter()
        .map(|h| h.id)
        .collect()
    }

    #[test]
    fn recovery_after_drop_without_close_or_flush() {
        let path = "/tmp/waffle_recovery_forget";
        let _ = std::fs::remove_dir_all(path);
        {
            // Scope ends without flush or close: the vector file is never
            // saved. Committed storage transactions are durable; dropping
            // releases the file lock exactly like a crash releases it.
            let _ = seed(path);
        }

        let reopened = WaffleEngine::open(config(path), schema()).unwrap();
        assert_eq!(reopened.store.count().unwrap(), 2);
        assert!(dense_query(&reopened, vec![1.0, 0.0, 0.0, 0.0]).contains(&"a".to_owned()));
        assert!(text_query(&reopened, "bravo").contains(&"a".to_owned()));
        reopened.flush().unwrap();
        let _ = std::fs::remove_dir_all(path);
    }

    #[test]
    fn recovery_after_index_files_deleted() {
        let path = "/tmp/waffle_recovery_deleted";
        let _ = std::fs::remove_dir_all(path);
        {
            let engine = seed(path);
            engine.flush().unwrap();
        }

        std::fs::remove_file(PathBuf::from(path).join("vectors.usearch")).unwrap();
        std::fs::remove_dir_all(PathBuf::from(path).join("tantivy")).unwrap();

        let reopened = WaffleEngine::open(config(path), schema()).unwrap();
        assert_eq!(reopened.store.count().unwrap(), 2);
        assert!(dense_query(&reopened, vec![0.0, 1.0, 0.0, 0.0]).contains(&"b".to_owned()));
        assert!(text_query(&reopened, "delta").contains(&"b".to_owned()));
        let _ = std::fs::remove_dir_all(path);
    }
}
