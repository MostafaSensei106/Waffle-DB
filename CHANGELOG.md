## 0.0.2

- **Performance Optimization**: Optimized vector serialization/deserialization on read paths using fast raw pointer copies.
- **Memory Footprint Reduction**: Pre-allocated internal map capacities (`id_map`, `reverse_id_map`, and ID list vectors) based on database size, preventing multiple heap reallocations.
- **Mutex Lock Consolidation & Deadlock Prevention**: Combined separate ID mapping locks into a single `IdRegistry` mutex, avoiding cross-lock deadlock hazards and minimizing locking overhead.
- **Zero-Copy Batch Insertion**: Refactored `waffle_insert_batch` to slice the flat array directly for disk persistence, reducing heap-allocated vector clones by 50%.
- **Correctness & Performance Fix**: Linked `includeMetadata` in `WaffleQueryBuilder` to the underlying Rust API so metadata is correctly retrieved when requested, and omitted when not needed.
- **Dart Namespace Caching**: Cached collection namespace prefixes in `WaffleCollection` to avoid dynamic string creation during filtering.

## 0.0.1+1

- fix unsupported platforms 

## 0.0.1

- Initial release of Waffle-DB.
