# 0.1.0
- **dependency overhaul (Rust)**: added `usearch 2` (SIMD vector engine with predicate pre-filtering), `tantivy 0.26` (BM25 text engine, EN+AR stemming), `redb 2` (ACID/MVCC storage), `roaring 0.11` with `serde` (filter bitmaps), `crossbeam-channel 0.5` (background ingestion queue), `cxx 1.0` (usearch error bridge), `anyhow` (single unified error type end to end).
- **Removed (Rust)**: `sled`, `hnsw_rs` (replaced by the  core), direct `rand` (was unused), `criterion` + `rand` dev-dependencies (no Rust benches exist; Dart benchmarks use `benchmark_harness`), `getrandom`/`getrandom_0_2` WASM shims (Flutter Web dropped for v1 and no plugin web platform is declared).
- **Engine rewrite (breaking)**: `redb` (8 tables) + `usearch` (`filtered_search` predicates) + `tantivy` (BM25, EN/AR stemming) + `roaring` bitmaps. Removed `storage.rs`/`models.rs`; `math.rs` keeps only `cosineSimilarity`.
- **Strict schema**: `WaffleSchema` with typed indexed fields is mandatory at open; payloads are validated; schema/dimension mismatches on reopen are hard errors.
- **Dual ID mapping**: external `String` IDs map to dense internal `u32` keys (optimal for bitmaps, zero-cost for `usearch`); deleted keys recycle through a FreeList.
- **Unified search**: `WaffleSearchRequest` (dense and/or sparse + filter AST + alpha + RRF-k) executes in parallel via `rayon::join` and fuses with RRF; numeric EQ/IN resolve through the ordered numeric index.
- **True delete**: physical removal from `usearch`, `tantivy` tombstone + commit, `redb` cleanup, bitmap pruning and FreeList recycling.
- **Chunk relations**: `parentId`/`chunkIndex` with a children index power `getNeighbors` (window context) and `getParent`.
- **Crash recovery**: vectors persisted in `redb`; on open the engine rebuilds `usearch` when it diverges from storage.
- **Dart API**: `insert`/`insertBatch` take text + payload + parent linkage; `search` + `WaffleQueryBuilder` (vector/text/hybrid, eq/inList, alpha); `WaffleFields`/`WaffleFilter` DSL; `newWaffleId()` (UUIDv7); `WaffleHit` replaces `WaffleQueryResult`.
- **Dart**: added `uuid ^4.6.0` (external String/UUIDv7 IDs for the dual-mapping design) and `collection ^1.19.1` (RRF/result utilities); removed unused `ffi`/`ffigen` dev-dependencies; SDK floor raised to `>=3.4.0` (required by `collection`).
- **Docs**: README rewritten around the multi-engine RAG architecture, locked design decisions, 3-month roadmap and v1 platform scope.
- **Tests**: new roundtrip coverage (filtered search, hybrid fusion, keyword search, neighbors, delete-across-engines, schema/duplicate/dimension violations); benchmarks and example app migrated to the new API.
- **Hygiene**: `cargo clippy` is warning-free (bundled `InsertInput`/`IndexedValues`, scoped iterator borrows, `for` loops, `if let` restores); internal engine types are `pub(crate)` so generated bindings stay minimal.
- **Examples**: `Products` demo (faceted hybrid search with pre-filters and alpha blending), `Recipes` demo (ingredient keywords + diet/time/cuisine pre-filters + nutrition similarity), `Contacts` demo (exact name/number match + group/starred pre-filters + interaction-profile similarity), and Arabic `RAG Notes` demo (stemming search, chunk windows, parent lookup, true delete), plus headless `rag_demos_test.dart` / `life_demos_test.dart` coverage.
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
