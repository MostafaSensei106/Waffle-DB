use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{OnceLock, RwLock};

use anyhow::Result;

use crate::api::engine::WaffleEngine;

static HANDLE_COUNTER: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static RwLock<HashMap<u64, WaffleEngine>> {
    static REGISTRY: OnceLock<RwLock<HashMap<u64, WaffleEngine>>> = OnceLock::new();
    REGISTRY.get_or_init(|| RwLock::new(HashMap::new()))
}

pub(crate) fn with_engine<F, R>(handle: u64, f: F) -> std::result::Result<R, String>
where
    F: FnOnce(&WaffleEngine) -> Result<R>,
{
    let reg = registry()
        .read()
        .map_err(|e| format!("lock poisoned: {e}"))?;
    let engine = reg
        .get(&handle)
        .ok_or_else(|| format!("invalid WaffleDB handle: {handle}"))?;
    f(engine).map_err(|e| e.to_string())
}

pub(crate) fn register(engine: WaffleEngine) -> Result<u64> {
    let handle = HANDLE_COUNTER.fetch_add(1, Ordering::Relaxed);
    registry()
        .write()
        .map_err(|e| anyhow::anyhow!("lock poisoned: {e}"))?
        .insert(handle, engine);
    Ok(handle)
}

pub(crate) fn unregister(handle: u64) -> Result<Option<WaffleEngine>> {
    Ok(registry()
        .write()
        .map_err(|e| anyhow::anyhow!("lock poisoned: {e}"))?
        .remove(&handle))
}
