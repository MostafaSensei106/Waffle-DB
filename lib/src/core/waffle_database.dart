import 'dart:convert';
import 'dart:typed_data';

import '../modules/waffle_record.dart';
import '../rust/api/config.dart';
import '../rust/api/query.dart';
import '../rust/api/schema.dart';
import '../rust/api/waffle_db.dart' as ffi;
import 'schema/waffle_dsl.dart';

///  multi-engine database: dense vectors (usearch),
/// BM25 text (tantivy) and ACID storage (redb) behind one handle.
class WaffleDatabase {
  final BigInt _handle;
  bool _closed = false;

  WaffleDatabase._(this._handle);

  /// Opens or creates a database. The [schema] must match stored data.
  static Future<WaffleDatabase> open(
    WaffleConfig config, {
    required WaffleSchema schema,
  }) async {
    final handle = await ffi.waffleOpen(config: config, schema: schema);
    return WaffleDatabase._(handle);
  }

  /// Flushes pending writes and releases the engine handle.
  Future<void> close() async {
    _assertOpen();
    await ffi.waffleClose(handle: _handle);
    _closed = true;
  }

  /// Inserts one chunk with its vector, text and structured [payload].
  Future<void> insert(
    String id,
    Float32List vector, {
    String text = '',
    Map<String, dynamic> payload = const {},
    String? parentId,
    int chunkIndex = 0,
  }) async {
    _assertOpen();
    await ffi.waffleInsert(
      handle: _handle,
      id: id,
      vector: vector,
      text: text,
      payloadJson: jsonEncode(payload),
      parentId: parentId,
      chunkIndex: chunkIndex,
    );
  }

  /// Inserts many chunks in one durable batch with a single text commit.
  Future<void> insertBatch(List<WaffleRecord> records) async {
    _assertOpen();
    if (records.isEmpty) return;

    final ids = <String>[];
    final texts = <String>[];
    final payloadJsons = <String>[];
    final parentIds = <String>[];
    final chunkIndices = <int>[];
    final dim = records.first.vector.length;
    final flatVectors = Float32List(records.length * dim);
    int offset = 0;

    for (final record in records) {
      ids.add(record.id);
      texts.add(record.text);
      payloadJsons.add(record.payloadJson);
      parentIds.add(record.parentId ?? '');
      chunkIndices.add(record.chunkIndex);
      flatVectors.setAll(offset, record.vector);
      offset += dim;
    }

    await ffi.waffleInsertBatch(
      handle: _handle,
      ids: ids,
      vectorsFlat: flatVectors,
      texts: texts,
      payloadJsons: payloadJsons,
      parentIds: parentIds,
      chunkIndices: chunkIndices,
    );
  }

  /// Unified dense / sparse / hybrid search with pre-filtering.
  List<WaffleHit> search({
    Float32List? vector,
    String? text,
    int topK = 10,
    WaffleFilter? filter,
    List<WaffleFilter>? filters,
    double? alpha,
    int? rrfK,
    int efSearch = 0,
  }) {
    _assertOpen();
    final all = <WaffleFilter>[
      if (filter != null) filter,
      if (filters != null) ...filters,
    ];
    return ffi.waffleSearch(
      handle: _handle,
      request: WaffleSearchRequest(
        vector: vector,
        text: text,
        topK: topK,
        filterJson: all.isEmpty
            ? null
            : all.length == 1
                ? all.first.encode()
                : WaffleAndFilter(all).encode(),
        alpha: alpha,
        rrfK: rrfK,
        efSearch: efSearch,
      ),
    );
  }

  /// Physically removes a record from every engine. Returns false if absent.
  Future<bool> delete(String id) async {
    _assertOpen();
    return ffi.waffleDelete(handle: _handle, id: id);
  }

  /// Returns the raw payload bytes for [id], or null when missing.
  Uint8List? getMetadata(String id) {
    _assertOpen();
    return ffi.waffleGetMetadata(handle: _handle, id: id);
  }

  /// Returns the payload decoded as a JSON map, or null when missing.
  Map<String, dynamic>? getPayload(String id) {
    final bytes = getMetadata(id);
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  /// Returns the stored vector for [id], or null when missing.
  Float32List? getVector(String id) {
    _assertOpen();
    return ffi.waffleGetVector(handle: _handle, id: id);
  }

  /// Returns chunks around [id] inside its parent document.
  List<WaffleHit> getNeighbors(String id, {int window = 1}) {
    _assertOpen();
    return ffi.waffleGetNeighbors(handle: _handle, id: id, window: window);
  }

  /// Returns the parent document of chunk [id], or null when none.
  WaffleHit? getParent(String id) {
    _assertOpen();
    return ffi.waffleGetParent(handle: _handle, id: id);
  }

  /// Counts stored records.
  int count() {
    _assertOpen();
    return ffi.waffleCount(handle: _handle).toInt();
  }

  /// Commits buffered text writes and persists the vector index.
  Future<void> flush() async {
    _assertOpen();
    await ffi.waffleFlush(handle: _handle);
  }

  /// Lists every stored external ID.
  List<String> getAllIds() {
    _assertOpen();
    return ffi.waffleGetAllIds(handle: _handle);
  }

  /// Whether this handle is still usable.
  bool get isOpen => !_closed;

  void _assertOpen() {
    if (_closed) {
      throw StateError('WaffleDatabase is already closed');
    }
  }
}
