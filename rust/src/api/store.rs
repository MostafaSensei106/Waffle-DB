use std::path::Path;
use std::sync::RwLock;

use redb::{Database, ReadableTable, TableDefinition};
use roaring::RoaringBitmap;

use crate::api::error::{Result, WaffleError};
use crate::api::schema::{
    ChunkRecord, WaffleSchema, archive_chunk, field_value_key, unarchive_chunk,
};

const T_EXT2INT: TableDefinition<&str, u32> = TableDefinition::new("ext2int");
const T_DATA: TableDefinition<u32, &[u8]> = TableDefinition::new("chunks");
const T_VECTORS: TableDefinition<u32, &[u8]> = TableDefinition::new("vectors");
const T_BITMAP_STR: TableDefinition<&str, &[u8]> = TableDefinition::new("bitmap_str");
const T_NUMERIC_IDX: TableDefinition<&[u8], u8> = TableDefinition::new("numeric_idx");
const T_CHILDREN: TableDefinition<&str, u32> = TableDefinition::new("children");
const T_FREELIST: TableDefinition<u32, u8> = TableDefinition::new("freelist");
const T_META: TableDefinition<&str, &[u8]> = TableDefinition::new("meta");

const META_SCHEMA: &str = "schema_json";
const META_NEXT_ID: &str = "next_id";
const META_DIM: &str = "dimension";

pub struct Store {
    db: Database,
    bitmap_cache: RwLock<std::collections::HashMap<String, RoaringBitmap>>,
}

impl Store {
    pub fn open(path: &Path, schema: &WaffleSchema, dimension: u32) -> Result<Self> {
        schema.validate()?;
        std::fs::create_dir_all(path)
            .map_err(|e| WaffleError::Storage(format!("cannot create db dir: {e}")))?;
        let db_path = path.join("store.redb");
        let db = Database::create(&db_path)?;
        let store = Self {
            db,
            bitmap_cache: RwLock::new(std::collections::HashMap::new()),
        };
        store.init_tables()?;

        let canonical = schema.canonical_json()?;
        match store.meta_get(META_SCHEMA)? {
            Some(existing) => {
                if existing != canonical.as_bytes() {
                    return Err(WaffleError::Schema(
                        "stored schema differs from the provided schema; reindex into a fresh path"
                            .to_owned(),
                    ));
                }
                match store.meta_get(META_DIM)? {
                    Some(dim_bytes) => {
                        let mut arr = [0u8; 4];
                        arr.copy_from_slice(&dim_bytes[0..4]);
                        let stored = u32::from_le_bytes(arr);
                        if stored != dimension {
                            return Err(WaffleError::Schema(format!(
                                "stored dimension {stored} != requested {dimension}"
                            )));
                        }
                    }
                    None => {
                        return Err(WaffleError::Schema(
                            "database is missing dimension metadata; reindex into a fresh path"
                                .to_owned(),
                        ));
                    }
                }
            }
            None => {
                store.meta_put(META_SCHEMA, canonical.as_bytes())?;
                store.meta_put(META_DIM, &dimension.to_le_bytes())?;
                store.meta_put(META_NEXT_ID, &0u64.to_le_bytes())?;
            }
        }
        Ok(store)
    }

    fn init_tables(&self) -> Result<()> {
        let tx = self.db.begin_write()?;
        {
            let _ = tx.open_table(T_EXT2INT)?;
            let _ = tx.open_table(T_DATA)?;
            let _ = tx.open_table(T_VECTORS)?;
            let _ = tx.open_table(T_BITMAP_STR)?;
            let _ = tx.open_table(T_NUMERIC_IDX)?;
            let _ = tx.open_table(T_CHILDREN)?;
            let _ = tx.open_table(T_FREELIST)?;
            let _ = tx.open_table(T_META)?;
        }
        tx.commit()?;
        Ok(())
    }

    fn meta_get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_META)?;
        Ok(table.get(key)?.map(|g| g.value().to_vec()))
    }

    fn meta_put(&self, key: &str, value: &[u8]) -> Result<()> {
        let tx = self.db.begin_write()?;
        {
            let mut table = tx.open_table(T_META)?;
            table.insert(key, value)?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn next_id_value(&self) -> Result<u64> {
        let raw = self.meta_get(META_NEXT_ID)?.ok_or_else(|| {
            WaffleError::Storage("missing next_id metadata".to_owned())
        })?;
        let mut arr = [0u8; 8];
        arr.copy_from_slice(&raw[0..8]);
        Ok(u64::from_le_bytes(arr))
    }

    fn set_next_id(&self, tx: &redb::WriteTransaction, next: u64) -> Result<()> {
        let mut table = tx.open_table(T_META)?;
        table.insert(META_NEXT_ID, &next.to_le_bytes()[..])?;
        Ok(())
    }

    pub fn lookup_internal(&self, external: &str) -> Result<Option<u32>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_EXT2INT)?;
        Ok(table.get(external)?.map(|g| g.value()))
    }

    pub fn alloc_id(&self, tx: &redb::WriteTransaction, external: &str) -> Result<u32> {
        let mut free_table = tx.open_table(T_FREELIST)?;
        if let Some(entry) = free_table.range::<u32>(..)?.next() {
            let (k, _) = entry?;
            let id = k.value();
            free_table.remove(id)?;
            return Ok(id);
        }
        drop(free_table);
        let raw = {
            let meta = tx.open_table(T_META)?;
            meta.get(META_NEXT_ID)?
                .map(|g| g.value().to_vec())
                .ok_or_else(|| WaffleError::Storage("missing next_id metadata".to_owned()))?
        };
        let mut arr = [0u8; 8];
        arr.copy_from_slice(&raw[0..8]);
        let next = u64::from_le_bytes(arr);
        if next > u32::MAX as u64 {
            return Err(WaffleError::Storage("internal id space exhausted".to_owned()));
        }
        self.set_next_id(tx, next + 1)?;
        let _ = external;
        Ok(next as u32)
    }

    pub fn child_key(parent: &str, chunk_index: u32) -> String {
        format!("{parent}\0{chunk_index:010}")
    }

    pub fn write_record(
        &self,
        tx: &redb::WriteTransaction,
        external: &str,
        internal: u32,
        record: &ChunkRecord,
        vector: &[f32],
    ) -> Result<()> {
        {
            let mut ext = tx.open_table(T_EXT2INT)?;
            ext.insert(external, internal)?;
        }
        {
            let bytes = archive_chunk(record)?;
            let mut data = tx.open_table(T_DATA)?;
            data.insert(internal, &bytes[..])?;
        }
        {
            let v_bytes: &[u8] = unsafe {
                std::slice::from_raw_parts(
                    vector.as_ptr() as *const u8,
                    std::mem::size_of_val(vector),
                )
            };
            let mut vecs = tx.open_table(T_VECTORS)?;
            vecs.insert(internal, v_bytes)?;
        }
        if record.parent_id.is_some() {
            let key = Self::child_key(
                record.parent_id.as_deref().unwrap_or_default(),
                record.chunk_index,
            );
            let mut children = tx.open_table(T_CHILDREN)?;
            children.insert(key.as_str(), internal)?;
        }
        Ok(())
    }

    pub fn read_chunk(&self, internal: u32) -> Result<Option<ChunkRecord>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_DATA)?;
        match table.get(internal)? {
            Some(g) => Ok(Some(unarchive_chunk(g.value())?)),
            None => Ok(None),
        }
    }

    pub fn read_vector(&self, internal: u32, dim: usize) -> Result<Option<Vec<f32>>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_VECTORS)?;
        match table.get(internal)? {
            Some(g) => {
                let bytes = g.value();
                if bytes.len() != dim * 4 {
                    return Err(WaffleError::Storage(format!(
                        "stored vector size {} != dimension {dim}",
                        bytes.len()
                    )));
                }
                let mut out = vec![0.0f32; dim];
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        bytes.as_ptr(),
                        out.as_mut_ptr() as *mut u8,
                        bytes.len(),
                    );
                }
                Ok(Some(out))
            }
            None => Ok(None),
        }
    }

    pub fn remove_record(&self, tx: &redb::WriteTransaction, external: &str, internal: u32) -> Result<Option<ChunkRecord>> {
        let record = {
            let data = tx.open_table(T_DATA)?;
            match data.get(internal)? {
                Some(g) => Some(unarchive_chunk(g.value())?),
                None => None,
            }
        };
        {
            let mut data = tx.open_table(T_DATA)?;
            data.remove(internal)?;
        }
        {
            let mut vecs = tx.open_table(T_VECTORS)?;
            vecs.remove(internal)?;
        }
        {
            let mut ext = tx.open_table(T_EXT2INT)?;
            ext.remove(external)?;
        }
        if let Some(rec) = &record {
            if rec.parent_id.is_some() {
                let key = Self::child_key(
                    rec.parent_id.as_deref().unwrap_or_default(),
                    rec.chunk_index,
                );
                let mut children = tx.open_table(T_CHILDREN)?;
                children.remove(key.as_str())?;
            }
        }
        {
            let mut free_table = tx.open_table(T_FREELIST)?;
            free_table.insert(internal, 0u8)?;
        }
        Ok(record)
    }

    pub fn numeric_put(&self, tx: &redb::WriteTransaction, key: &[u8]) -> Result<()> {
        let mut table = tx.open_table(T_NUMERIC_IDX)?;
        table.insert(key, 0u8)?;
        Ok(())
    }

    pub fn numeric_remove(&self, tx: &redb::WriteTransaction, key: &[u8]) -> Result<()> {
        let mut table = tx.open_table(T_NUMERIC_IDX)?;
        table.remove(key)?;
        Ok(())
    }

    pub fn numeric_scan_prefix(&self, prefix: &[u8]) -> Result<Vec<u32>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_NUMERIC_IDX)?;
        let mut ids = Vec::new();
        let mut iter = table.range::<&[u8]>(prefix..)?;
        while let Some(entry) = iter.next() {
            let (k, _) = entry?;
            let bytes = k.value();
            if bytes.len() < prefix.len() || &bytes[..prefix.len()] != prefix {
                break;
            }
            if bytes.len() != 20 {
                continue;
            }
            let mut arr = [0u8; 4];
            arr.copy_from_slice(&bytes[16..20]);
            ids.push(u32::from_be_bytes(arr));
        }
        Ok(ids)
    }

    pub fn bitmap_get(&self, key: &str) -> Result<RoaringBitmap> {
        {
            let cache = self
                .bitmap_cache
                .read()
                .map_err(|e| WaffleError::Storage(format!("lock poisoned: {e}")))?;
            if let Some(bm) = cache.get(key) {
                return Ok(bm.clone());
            }
        }
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_BITMAP_STR)?;
        let bitmap = match table.get(key)? {
            Some(g) => RoaringBitmap::deserialize_from(&mut &g.value()[..])
                .map_err(|e| WaffleError::Storage(format!("bitmap decode: {e}")))?,
            None => RoaringBitmap::new(),
        };
        self.bitmap_cache
            .write()
            .map_err(|e| WaffleError::Storage(format!("lock poisoned: {e}")))?
            .insert(key.to_owned(), bitmap.clone());
        Ok(bitmap)
    }

    pub fn bitmap_put(&self, tx: &redb::WriteTransaction, key: &str, bitmap: &RoaringBitmap) -> Result<()> {
        let mut buf = Vec::new();
        bitmap
            .serialize_into(&mut buf)
            .map_err(|e| WaffleError::Storage(format!("bitmap encode: {e}")))?;
        {
            let mut table = tx.open_table(T_BITMAP_STR)?;
            table.insert(key, &buf[..])?;
        }
        self.bitmap_cache
            .write()
            .map_err(|e| WaffleError::Storage(format!("lock poisoned: {e}")))?
            .insert(key.to_owned(), bitmap.clone());
        Ok(())
    }

    pub fn bitmap_add(&self, tx: &redb::WriteTransaction, field: &str, value: &str, internal: u32) -> Result<()> {
        let key = field_value_key(field, value);
        let mut bitmap = self.bitmap_get(&key)?;
        bitmap.insert(internal);
        self.bitmap_put(tx, &key, &bitmap)
    }

    pub fn bitmap_remove(&self, tx: &redb::WriteTransaction, field: &str, value: &str, internal: u32) -> Result<()> {
        let key = field_value_key(field, value);
        let mut bitmap = self.bitmap_get(&key)?;
        bitmap.remove(internal);
        self.bitmap_put(tx, &key, &bitmap)
    }

    pub fn child_lookup(&self, parent: &str, chunk_index: u32) -> Result<Option<u32>> {
        let key = Self::child_key(parent, chunk_index);
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_CHILDREN)?;
        Ok(table.get(key.as_str())?.map(|g| g.value()))
    }

    pub fn count(&self) -> Result<u64> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_DATA)?;
        Ok(table.len()?)
    }

    pub fn all_external_ids(&self) -> Result<Vec<String>> {
        let tx = self.db.begin_read()?;
        let table = tx.open_table(T_EXT2INT)?;
        let mut ids = Vec::new();
        let mut iter = table.range::<&str>(..)??;
        while let Some(entry) = iter.next() {
            let (k, _) = entry?;
            ids.push(k.value().to_owned());
        }
        Ok(ids)
    }

    pub fn all_vectors(&self, dim: usize) -> Result<Vec<(String, u32, Vec<f32>)>> {
        let tx = self.db.begin_read()?;
        let ext = tx.open_table(T_EXT2INT)?;
        let vecs = tx.open_table(T_VECTORS)?;
        let mut out = Vec::new();
        let mut iter = ext.range::<&str>(..)??;
        while let Some(entry) = iter.next() {
            let (k, v) = entry?;
            let external = k.value().to_owned();
            let internal = v.value();
            if let Some(g) = vecs.get(internal)? {
                let bytes = g.value();
                if bytes.len() != dim * 4 {
                    continue;
                }
                let mut floats = vec![0.0f32; dim];
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        bytes.as_ptr(),
                        floats.as_mut_ptr() as *mut u8,
                        bytes.len(),
                    );
                }
                out.push((external, internal, floats));
            }
        }
        Ok(out)
    }

    pub fn begin_write(&self) -> Result<redb::WriteTransaction> {
        Ok(self.db.begin_write()?)
    }
}
