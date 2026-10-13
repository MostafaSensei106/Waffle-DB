use anyhow::{Result, anyhow};
use roaring::RoaringBitmap;

use crate::api::engine::WaffleEngine;
use crate::api::filter::{evaluate_filter, parse_filter};
use crate::api::query::{WaffleHit, WaffleSearchRequest, rrf_fuse};
use crate::api::store::Store;

fn hit_from_internal(
    store: &Store,
    internal: u32,
    score: f32,
    distance: Option<f32>,
) -> Result<Option<WaffleHit>> {
    Ok(store.read_chunk(internal)?.map(|rec| WaffleHit {
        id: rec.external_id,
        score,
        distance,
        text: Some(rec.text),
        payload_json: Some(rec.payload_json),
    }))
}

pub(crate) fn search(
    engine: &WaffleEngine,
    request: &WaffleSearchRequest,
) -> Result<Vec<WaffleHit>> {
    let dim = engine.config.dimension as usize;
    if let Some(v) = &request.vector {
        if v.len() != dim {
            return Err(anyhow!(
                "dimension mismatch: expected {dim}, got {}",
                v.len()
            ));
        }
    }
    if request.vector.is_none() && request.text.is_none() {
        return Err(anyhow!("search request needs a vector, a text, or both"));
    }
    let top_k = (request.top_k as usize).clamp(1, 10_000);
    let offset = request.offset as usize;
    let fetch = (top_k + offset).min(10_000);
    let allowed: Option<RoaringBitmap> = match &request.filter_json {
        Some(json) => Some(evaluate_filter(
            &engine.store,
            &engine.schema,
            &parse_filter(json)?,
        )?),
        None => None,
    };

    let (dense, sparse) = rayon::join(
        || -> Result<Option<Vec<(u32, f32)>>> {
            match &request.vector {
                Some(v) => {
                    let res = if request.ef_search > 0 {
                        let _guard = engine.ef_guard.lock().map_err(|e| {
                            anyhow!("lock poisoned: {e}")
                        })?;
                        engine
                            .vector
                            .override_expansion_search(request.ef_search as usize);
                        let r = engine.vector.search(v, fetch, allowed.as_ref());
                        engine.vector.override_expansion_search(
                            engine.config.graph_config.ef_search as usize,
                        );
                        r?
                    } else {
                        engine.vector.search(v, fetch, allowed.as_ref())?
                    };
                    Ok(Some(res))
                }
                None => Ok(None),
            }
        },
        || -> Result<Option<Vec<(u32, f32)>>> {
            match &request.text {
                Some(t) => {
                    // Tantivy has no predicate pushdown: over-fetch and
                    // apply the allowed-ids bitmap here, growing the
                    // limit until enough filtered hits are collected.
                    let mut limit = fetch;
                    let mut collected: Vec<(u32, f32)> = Vec::new();
                    for _ in 0..4 {
                        let page = engine.text.search(t, limit)?;
                        if page.is_empty() {
                            break;
                        }
                        collected.clear();
                        for (id, score) in &page {
                            let keep = match &allowed {
                                Some(bm) => bm.contains(*id),
                                None => true,
                            };
                            if keep {
                                collected.push((*id, *score));
                            }
                            if collected.len() >= fetch {
                                break;
                            }
                        }
                        if collected.len() >= fetch || page.len() < limit {
                            break;
                        }
                        limit = (limit * 2).min(10_000);
                    }
                    collected.truncate(fetch);
                    Ok(Some(collected))
                }
                None => Ok(None),
            }
        },
    );
    let dense = dense?;
    let sparse = sparse?;

    // The request validator above guarantees at least one side is set.
    let fused: Vec<(u32, f32, Option<f32>)> = match (dense, sparse) {
        (Some(d), Some(s)) => {
            let rrf_k = request.rrf_k.unwrap_or(60) as usize;
            let alpha = request.alpha.unwrap_or(0.5).clamp(0.0, 1.0);
            rrf_fuse(&d, &s, rrf_k, alpha, fetch)
        }
        (Some(d), None) => {
            let mut v: Vec<(u32, f32, Option<f32>)> = d
                .into_iter()
                .map(|(id, dist)| (id, 1.0 / (1.0 + dist), Some(dist)))
                .collect();
            v.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            v.truncate(fetch);
            v
        }
        (None, Some(s)) => {
            let mut v: Vec<(u32, f32, Option<f32>)> = s
                .into_iter()
                .map(|(id, score)| (id, score, None))
                .collect();
            v.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            v.truncate(fetch);
            v
        }
        (None, None) => Vec::new(),
    };

    let mut hits = Vec::with_capacity(fused.len().min(top_k));
    for (internal, score, distance) in fused.into_iter().skip(offset).take(top_k) {
        if let Some(hit) = hit_from_internal(&engine.store, internal, score, distance)? {
            hits.push(hit);
        }
    }
    Ok(hits)
}

pub(crate) fn metadata(engine: &WaffleEngine, id: &str) -> Result<Option<Vec<u8>>> {
    match engine.store.lookup_internal(id)? {
        Some(internal) => Ok(engine
            .store
            .read_chunk(internal)?
            .map(|rec| rec.payload_json.into_bytes())),
        None => Ok(None),
    }
}

pub(crate) fn vector(engine: &WaffleEngine, id: &str) -> Result<Option<Vec<f32>>> {
    let dim = engine.config.dimension as usize;
    match engine.store.lookup_internal(id)? {
        Some(internal) => Ok(engine.store.read_vector(internal, dim)?),
        None => Ok(None),
    }
}

pub(crate) fn neighbors(
    engine: &WaffleEngine,
    id: &str,
    window: u32,
) -> Result<Vec<WaffleHit>> {
    let internal = engine
        .store
        .lookup_internal(id)?
        .ok_or_else(|| anyhow!("unknown id {id:?}"))?;
    let rec = engine
        .store
        .read_chunk(internal)?
        .ok_or_else(|| anyhow!("missing record for {id:?}"))?;
    let parent = rec.parent_id.clone().ok_or_else(|| {
        anyhow!("record has no parent document")
    })?;
    let lo = rec.chunk_index.saturating_sub(window);
    let hi = rec.chunk_index.saturating_add(window);
    let mut hits = Vec::new();
    for idx in lo..=hi {
        if let Some(sibling) = engine.store.child_lookup(&parent, idx)? {
            if let Some(hit) = hit_from_internal(&engine.store, sibling, 1.0, None)? {
                hits.push(hit);
            }
        }
    }
    Ok(hits)
}

pub(crate) fn parent(engine: &WaffleEngine, id: &str) -> Result<Option<WaffleHit>> {
    let internal = match engine.store.lookup_internal(id)? {
        Some(v) => v,
        None => return Ok(None),
    };
    let rec = match engine.store.read_chunk(internal)? {
        Some(r) => r,
        None => return Ok(None),
    };
    let parent = match rec.parent_id {
        Some(p) => p,
        None => return Ok(None),
    };
    match engine.store.lookup_internal(&parent)? {
        Some(p_internal) => hit_from_internal(&engine.store, p_internal, 1.0, None),
        None => Ok(None),
    }
}
