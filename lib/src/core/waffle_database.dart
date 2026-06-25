import 'dart:typed_data';

import '../modules/waffle_record.dart';
import '../rust/api/config.dart';
import '../rust/api/models.dart';
import '../rust/api/waffle_db.dart' as ffi;

/// High-level Dart API for WaffleDB — a vector database powered by HNSW
/// (Hierarchical Navigable Small World) graphs in Rust via FFI.
///
/// Usage:
/// ```dart
/// final db = await WaffleDatabase.open(
///   await WaffleConfig.mobileProfile(path: '/path/to/db', dimension: 384),
/// );
///
/// await db.insert('doc1', Float32List.fromList([0.1, 0.2, ...]), metadata: utf8.encode('hello'));
/// final results = await db.query(Float32List.fromList([0.1, 0.2, ...]), k: 5);
/// await db.close();
/// ```
class WaffleDatabase {
  final BigInt _handle;
  bool _closed = false;

  WaffleDatabase._(this._handle);

  /// Open (or create) a WaffleDB instance with the given configuration.
  /// If data already exists at the configured path, it will be loaded and
  /// the HNSW index will be rebuilt from persisted vectors.
  static Future<WaffleDatabase> open(WaffleConfig config) async {
    final handle = await ffi.waffleOpen(config: config);
    return WaffleDatabase._(handle);
  }

  /// Close the database, flushing all pending writes to disk.
  /// After calling this, all other methods will throw.
  Future<void> close() async {
    _assertOpen();
    await ffi.waffleClose(handle: _handle);
    _closed = true;
  }

  /// Insert a single vector with optional metadata.
  ///
  /// [id] must be a unique string identifier.
  /// [vector] must have length equal to the configured dimension.
  /// [metadata] is optional arbitrary bytes.
  Future<void> insert(
    String id,
    Float32List vector, {
    Uint8List? metadata,
  }) async {
    _assertOpen();
    await ffi.waffleInsert(
      handle: _handle,
      id: id,
      vector: vector,
      metadata: metadata ?? Uint8List(0),
    );
  }

  /// Batch insert multiple records. Uses Rayon-powered parallel insertion
  /// on the Rust side for maximum throughput.
  ///
  /// All vectors must have the same dimension matching the config.
  Future<void> insertBatch(List<WaffleRecord> records) async {
    _assertOpen();
    if (records.isEmpty) return;

    final ids = <String>[];
    final metadataList = <Uint8List>[];
    final dim = records.first.vector.length;
    final flatVectors = Float32List(records.length * dim);
    int offset = 0;

    for (final record in records) {
      ids.add(record.id);
      metadataList.add(record.metadata ?? Uint8List(0));
      flatVectors.setAll(offset, record.vector);
      offset += dim;
    }

    await ffi.waffleInsertBatch(
      handle: _handle,
      ids: ids,
      vectorsFlat: flatVectors,
      metadataList: metadataList,
    );
  }

  /// K-nearest neighbor search.
  ///
  /// [vector] is the query embedding (must match configured dimension).
  /// [k] is the number of nearest neighbors to return.
  /// [efSearch] overrides the configured ef_search for this query.
  ///   Higher values = more accurate but slower. Pass 0 to use config default.
  ///
  /// Returns results sorted by distance (ascending = most similar first).
  Future<List<WaffleQueryResult>> query(
    Float32List vector, {
    int k = 10,
    int efSearch = 0,
  }) async {
    _assertOpen();
    return ffi.waffleQuery(
      handle: _handle,
      vector: vector,
      k: k,
      efSearch: efSearch,
    );
  }

  /// Delete a vector by its string ID.
  ///
  /// Returns `true` if the record existed and was removed.
  /// Note: The HNSW index entry remains stale until the database is
  /// reopened (which triggers a full index rebuild from disk).
  Future<bool> delete(String id) async {
    _assertOpen();
    return ffi.waffleDelete(handle: _handle, id: id);
  }

  /// Retrieve the metadata bytes for a vector by ID.
  /// Returns `null` if not found.
  Future<Uint8List?> getMetadata(String id) async {
    _assertOpen();
    return ffi.waffleGetMetadata(handle: _handle, id: id);
  }

  /// Retrieve a stored vector by ID.
  /// Returns `null` if not found.
  Future<Float32List?> getVector(String id) async {
    _assertOpen();
    return ffi.waffleGetVector(handle: _handle, id: id);
  }

  /// Get the number of vectors stored on disk.
  Future<int> count() async {
    _assertOpen();
    final c = await ffi.waffleCount(handle: _handle);
    return c.toInt();
  }

  /// Force flush all pending writes to disk.
  Future<void> flush() async {
    _assertOpen();
    await ffi.waffleFlush(handle: _handle);
  }

  /// Get all stored string IDs.
  Future<List<String>> getAllIds() async {
    _assertOpen();
    return ffi.waffleGetAllIds(handle: _handle);
  }

  /// Whether this database instance is still open.
  bool get isOpen => !_closed;

  void _assertOpen() {
    if (_closed) {
      throw StateError('WaffleDatabase is already closed');
    }
  }
}
