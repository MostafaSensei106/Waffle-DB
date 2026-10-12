import 'dart:typed_data';

import '../core/query/waffle_query_builder.dart';
import '../core/waffle_database.dart';
import '../rust/api/query.dart';
import 'waffle_record.dart';

/// Logical namespace over one database. IDs are prefixed internally
/// with the collection name to prevent collisions.
class WaffleCollection {
  final WaffleDatabase _db;

  /// Collection name used as the ID prefix.
  final String name;

  final String _prefix;

  /// Scopes [db] to the logical [name] namespace.
  WaffleCollection(this._db, this.name) : _prefix = '$name::';

  String _prefixId(String id) => '$_prefix$id';

  String _stripPrefix(String id) {
    if (id.startsWith(_prefix)) {
      return id.substring(_prefix.length);
    }
    return id;
  }

  WaffleHit _unprefix(WaffleHit hit) => WaffleHit(
        id: _stripPrefix(hit.id),
        score: hit.score,
        distance: hit.distance,
        text: hit.text,
        payloadJson: hit.payloadJson,
      );

  /// Adds one vector to this collection.
  Future<void> add(
    String id,
    Float32List vector, {
    String text = '',
    Map<String, dynamic> payload = const {},
    String? parentId,
    int chunkIndex = 0,
  }) async {
    await _db.insert(
      _prefixId(id),
      vector,
      text: text,
      payload: payload,
      parentId: parentId == null ? null : _prefixId(parentId),
      chunkIndex: chunkIndex,
    );
  }

  /// Adds many records to this collection in one batch.
  Future<void> addBatch(List<WaffleRecord> records) async {
    final prefixed = records
        .map(
          (r) => WaffleRecord(
            id: _prefixId(r.id),
            vector: r.vector,
            text: r.text,
            payload: r.payload,
            parentId: r.parentId == null ? null : _prefixId(r.parentId!),
            chunkIndex: r.chunkIndex,
          ),
        )
        .toList();
    await _db.insertBatch(prefixed);
  }

  /// Dense search restricted to this collection's IDs.
  Future<List<WaffleHit>> search(
    Float32List queryVector, {
    int topK = 10,
    int efSearch = 0,
  }) async {
    final results = _db.search(
      vector: queryVector,
      topK: topK,
      efSearch: efSearch,
    );
    return results
        .where((r) => r.id.startsWith(_prefix))
        .map(_unprefix)
        .toList();
  }

  /// Deletes one member by ID.
  Future<bool> delete(String id) async {
    return _db.delete(_prefixId(id));
  }

  /// Returns raw payload bytes for a member, or null when missing.
  Future<Uint8List?> getMetadata(String id) async {
    return _db.getMetadata(_prefixId(id));
  }

  /// Returns the stored vector for a member, or null when missing.
  Future<Float32List?> getVector(String id) async {
    return _db.getVector(_prefixId(id));
  }

  /// Returns neighboring chunks of a member inside its parent.
  Future<List<WaffleHit>> getNeighbors(String id, {int window = 1}) async {
    final hits = _db.getNeighbors(_prefixId(id), window: window);
    return hits.map(_unprefix).toList();
  }

  /// Opens a query builder scoped to the underlying database.
  WaffleQueryBuilder query() => WaffleQueryBuilder(_db);
}
