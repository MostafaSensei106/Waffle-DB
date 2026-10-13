# 0.1.0-dev.1

- **dependency overhaul (Rust)**: `tantivy 0.26` (BM25 text engine, EN+AR stemming), `redb 2` (ACID/MVCC storage), `roaring 0.11` with `serde` (filter bitmaps), `cxx 1.0` (usearch error bridge), `anyhow` (single unified error type end to end).
- **Removed (Rust)**: `sled`, `hnsw_rs` (replaced by the  core), direct `rand` (was unused), `criterion` + `rand` dev-dependencies (no Rust benches exist; Dart benchmarks use `benchmark_harness`), `getrandom`/`getrandom_0_2` WASM shims (Flutter Web dropped for v1 and no plugin web platform is declared).
- **Engine rewrite (breaking)**: `redb` (8 tables) + `usearch` (`filtered_search` predicates) + `tantivy` (BM25, EN/AR stemming) + `roaring` bitmaps. Removed `storage.rs`/`models.rs`; `math.rs` keeps only `cosineSimilarity`.
- **Strict schema**: `WaffleSchema` with typed indexed fields is mandatory at open; payloads are validated; schema/dimension mismatches on reopen are hard errors.
- **Dual ID mapping**: external `String` IDs map to dense internal `u32` keys (optimal for bitmaps, zero-cost for `usearch`); deleted keys recycle through a FreeList.
- **Unified search**: `WaffleSearchRequest` (dense and/or sparse + filter AST + alpha + RRF-k) executes in parallel via `rayon::join` and fuses with RRF; numeric EQ/IN resolve through the ordered numeric index.
- **True delete**: physical removal from `usearch`, `tantivy` tombstone + commit, `redb` cleanup, bitmap pruning and FreeList recycling.
- **Chunk relations**: `parentId`/`chunkIndex` with a children index power `getNeighbors` (window context) and `getParent`.
- **Crash recovery**: vectors persisted in `redb`; on open the engine rebuilds `usearch` when it diverges from storage.
- **Dart API**: `insert`/`insertBatch` take text + payload + parent linkage; `search` + `WaffleQueryBuilder` (vector/text/hybrid, eq/inList, alpha); `WaffleFields`/`WaffleFilter` DSL; `newWaffleId()` (UUIDv7); `WaffleHit` replaces `WaffleQueryResult`.
- **Dart**: added `uuid ^4.6.0` (external String/UUIDv7 IDs for the dual-mapping design); removed unused `ffi`/`ffigen` dev-dependencies; SDK floor raised to `>=3.4.0`.
- **Docs**: README rewritten around the multi-engine RAG architecture, locked design decisions, 3-month roadmap and v1 platform scope.
- **Tests**: new roundtrip coverage (filtered search, hybrid fusion, keyword search, neighbors, delete-across-engines, schema/duplicate/dimension violations); benchmarks and example app migrated to the new API.
- **Hygiene**: `cargo clippy` is warning-free (bundled `InsertInput`/`IndexedValues`, scoped iterator borrows, `for` loops, `if let` restores); internal engine types are `pub(crate)` so generated bindings stay minimal.
- **Examples**: `Docs RAG` (chunked guides, hybrid retrieval, citable windows), `Code Search` (exact symbols, language/kind filters, file context), `Support` (triage filters, upsert-to-resolve, deleteWhere sweeps), `Glossary` (bilingual EN↔AR lookup), plus `Colors`; headless `ai_demos_test.dart` coverage. Demo vectors come from a documented hashed-trigram stand-in, not a real model.
- **Fix**: `NativeLibraryLoader` no longer throws `Unsupported OS` on Android/iOS (correct `libwaffle_db` names, mobile rethrows the real bundled-lib error instead of falling back to a checkout path); verified `app-debug.apk` bundles `libwaffle_db.so` for arm64-v8a, armeabi-v7a and x86_64.
- **API expansion**: `upsert` (insert-or-replace with replacement flag), `deleteBatch`/`deleteWhere` (counted removals, single text commit), `offset` pagination on fused results, `filter`/`and` builder combinators, and collection search via indexed `_collection` pre-filtering (schema must declare it).
- **Fix**: the sparse side of hybrid/text search now applies the same allowed-IDs bitmap (adaptive over-fetch), so filtered text queries can no longer leak excluded records.
- **Fix**: text fields index positions, enabling phrase queries.
- **Performance**: batch inserts share one storage transaction (batch p50 1413ms → 435ms per 1000 vectors).
- **Android**: `rust/build.rs` links NDK `libc++_static.a` + `libc++abi.a` by absolute path and `CXXSTDLIB=c++_static` stops the shared link  the APK carries zero C++ runtime dependency (verified: only libdl/libm/libc NEEDED, zero undefined C++ symbols).
- **Docs**: README rewritten without marketing claims  factual comparison, full API reference, how-it-works (search/write flows), honest limitations and roadmap, measured benchmark tables.
- **Changed**: `rust/src/api/` restructured into focused modules (`engine.rs`, `registry.rs`, `writes.rs`, `reads.rs`) behind a thin `waffle_db.rs` facade. No FFI or Dart API change  regenerated bindings are identical. The engine roundtrip test moved to `rust/tests/enterprise_roundtrip.rs`.

## Upgrading from 0.0.x to 0.1.0-dev.1 (breaking)

- **Storage is incompatible**: databases created by 0.0.x cannot be opened. Reindex your vectors into a fresh path; there is no auto-migration.
- **Schema is now mandatory**: `WaffleDatabase.open` requires a `WaffleSchema`. Declare every field you filter on as indexed; everything else goes in the free payload. Collections additionally require an indexed `_collection` string field.
- **API renames**: `db.query(vector, k:)` → `db.search(vector:, topK:)`; `WaffleQueryResult` → `WaffleHit` (with `score` instead of threshold filtering); `metadata:` bytes → `payload:` map plus `text:`; `threshold()`/`includeMetadata()` builder options are gone (filter with `eq`/`inList` instead).
- **Deletes are real now**: `delete` removes data from every engine (previously the vector stayed until reopen). `getMetadata` returns payload JSON bytes; decode with `getPayload` for a map.
- **Android**: no action needed  the C++ runtime links statically since this version.



# 0.0.3

- **Performance**: Optimized insertion and queries for datasets with 1,000,000+ vectors.
- **Performance**: Replaced `Mutex` with `RwLock` for concurrent read queries.
- **Performance**: Migrated `id_map.json` into the `sled` database for significantly faster load times and reduced memory pressure.
- **Performance**: Improved batch insertions to chunk data and process efficiently.
- **Fix**: Resolved `Box::leak` memory leak during index loading.
- **Config**: Added `WaffleConfig.highVolumeProfile()` for multi-million vector datasets.

# 0.0.2+1

- **OHOS Platform Support**: Introduced OpenHarmony (OHOS) SDK environment variable retrieval in `Environment`, updated `Rustup` toolchain resolution, added target configurations for OHOS in `Target`, updated CMake configuration to handle OHOS builds, and modified Gradle plugin to utilize `ExecOperations`.
- **Dependencies & Bindings**: Updated dependencies in `pubspec.yaml` and `Cargo.toml` to latest versions and regenerated Rust API files using `flutter_rust_bridge` version `2.13.0`.


## 0.0.2

- **HNSW Save Reliability**: Fixed a bug where closing or flushing an empty HNSW index returned an error by skipping index dump if the graph contains 0 elements.
- **Index Load Resiliency**: Fixed a startup crash ("failed to fill whole buffer") by ensuring both the map and the HNSW graph file exist on disk before trying to load them.
- **Asynchronous Benchmark Suite**: Added a comprehensive real-world async performance benchmark suite under `test/vector_db_real_world_benchmark_test.dart` using `benchmark_harness`.
- **Color Semantic Search Example**: Rewrote the example app under `example/lib/main.dart` into an interactive, visual color semantic search demonstration that inserts up to 12 million random colors and queries the 150 closest matches in milliseconds.

- **Performance Optimization**: Optimized vector serialization/deserialization on read paths using fast raw pointer copies.
- **Memory Footprint Reduction**: Pre-allocated internal map capacities (`id_map`, `reverse_id_map`, and ID list vectors) based on database size, preventing multiple heap reallocations.
- **Mutex Lock Consolidation & Deadlock Prevention**: Combined separate ID mapping locks into a single `IdRegistry` mutex, avoiding cross-lock deadlock hazards and minimizing locking overhead.
- ** Batch Insertion**: Refactored `waffle_insert_batch` to slice the flat array directly for disk persistence, reducing heap-allocated vector clones by 50%.
- **Correctness & Performance Fix**: Linked `includeMetadata` in `WaffleQueryBuilder` to the underlying Rust API so metadata is correctly retrieved when requested, and omitted when not needed.
- **Dart Namespace Caching**: Cached collection namespace prefixes in `WaffleCollection` to avoid dynamic string creation during filtering.

## 0.0.1+1

- fix unsupported platforms 

## 0.0.1

- Initial release of Waffle-DB.
