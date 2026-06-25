import 'dart:typed_data';

import '../core/query/waffle_query_builder.dart';
import '../core/waffle_database.dart';
import '../rust/api/models.dart';
import 'waffle_record.dart';

/// A named collection abstraction over WaffleDB.
///
/// Collections provide a logical grouping of vectors. IDs are automatically
/// namespaced with the collection name to prevent collisions.
///
/// Usage:
/// ```dart
/// final db = await WaffleDatabase.open(config);
/// final collection = WaffleCollection(db, 'documents');
///
/// await collection.add('doc1', embedding, metadata: {'title': 'Hello'});
/// final results = await collection.search(queryVector, topK: 5);
/// ```
class WaffleCollection {
  final WaffleDatabase _db;

  /// The name of this collection.
  final String name;

  WaffleCollection(this._db, this.name);

  /// Prefix an ID with the collection name to avoid collisions.
  String _prefixId(String id) => '$name::$id';

  /// Strip the collection prefix from an ID.
  String _stripPrefix(String id) {
    final prefix = '$name::';
    if (id.startsWith(prefix)) {
      return id.substring(prefix.length);
    }
    return id;
  }

  /// Add a vector to this collection.
  ///
  /// [id] is the user-facing ID (will be namespaced internally).
  /// [vector] must match the configured dimension.
  /// [metadata] is optional arbitrary bytes.
  Future<void> add(String id, Float32List vector, {Uint8List? metadata}) async {
    await _db.insert(_prefixId(id), vector, metadata: metadata);
  }

  /// Batch add multiple records to this collection.
  Future<void> addBatch(List<WaffleRecord> records) async {
    final prefixed = records
        .map(
          (r) => WaffleRecord(
            id: _prefixId(r.id),
            vector: r.vector,
            metadata: r.metadata,
          ),
        )
        .toList();
    await _db.insertBatch(prefixed);
  }

  /// Search this collection for the k nearest neighbors.
  ///
  /// Note: Since HNSW search is global, results may include vectors from
  /// other collections if the same database instance is shared. Use the
  /// returned IDs to filter if needed.
  Future<List<WaffleQueryResult>> search(
    Float32List queryVector, {
    int topK = 10,
    int efSearch = 0,
  }) async {
    final results = _db.query(queryVector, k: topK, efSearch: efSearch);
    // Filter to only this collection's results and strip prefix
    return results
        .where((r) => r.id.startsWith('$name::'))
        .map(
          (r) => WaffleQueryResult(
            id: _stripPrefix(r.id),
            distance: r.distance,
            metadata: r.metadata,
          ),
        )
        .toList();
  }

  /// Delete a vector from this collection by ID.
  Future<bool> delete(String id) async {
    return _db.delete(_prefixId(id));
  }

  /// Get metadata for a vector in this collection.
  Future<Uint8List?> getMetadata(String id) async {
    return _db.getMetadata(_prefixId(id));
  }

  /// Get a stored vector by ID in this collection.
  Future<Float32List?> getVector(String id) async {
    return _db.getVector(_prefixId(id));
  }

  /// Create a query builder scoped to this collection.
  WaffleQueryBuilder query() => WaffleQueryBuilder(_db);
}
