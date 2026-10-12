import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates a time-ordered unique external ID (UUIDv7).
String newWaffleId() => _uuid.v7();

/// A single document chunk to be inserted into WaffleDB.
class WaffleRecord {
  /// External string ID. Mapped internally to a dense integer key.
  final String id;

  /// Dense embedding vector. Length must match the configured dimension.
  final Float32List vector;

  /// Raw chunk text. Indexed for BM25 keyword search when non-empty.
  final String text;

  /// Structured metadata. Indexed fields must match the collection schema.
  final Map<String, dynamic> payload;

  /// External ID of the parent document, if this record is a chunk.
  final String? parentId;

  /// Zero-based position of this chunk inside its parent document.
  final int chunkIndex;

  /// Creates a [WaffleRecord] from a typed vector.
  const WaffleRecord({
    required this.id,
    required this.vector,
    this.text = '',
    this.payload = const {},
    this.parentId,
    this.chunkIndex = 0,
  });

  /// Creates a [WaffleRecord] from a plain list of doubles.
  factory WaffleRecord.fromList({
    required String id,
    required List<double> vector,
    String text = '',
    Map<String, dynamic> payload = const {},
    String? parentId,
    int chunkIndex = 0,
  }) {
    return WaffleRecord(
      id: id,
      vector: Float32List.fromList(vector),
      text: text,
      payload: payload,
      parentId: parentId,
      chunkIndex: chunkIndex,
    );
  }

  /// The payload encoded as a JSON string for the storage engine.
  String get payloadJson => jsonEncode(payload);

  @override
  String toString() =>
      'WaffleRecord(id: $id, dim: ${vector.length}, text: ${text.length} chars)';
}
