import 'dart:typed_data';

/// Represents a single vector record to be inserted into WaffleDB.
class WaffleRecord {
  /// A unique string identifier for this vector.
  final String id;

  /// The embedding vector. Length must match the configured dimension.
  final Float32List vector;

  /// Optional arbitrary metadata bytes associated with this vector.
  final Uint8List? metadata;

  const WaffleRecord({
    required this.id,
    required this.vector,
    this.metadata,
  });

  /// Convenience constructor from a regular `List<double>`.
  factory WaffleRecord.fromList({
    required String id,
    required List<double> vector,
    Uint8List? metadata,
  }) {
    return WaffleRecord(
      id: id,
      vector: Float32List.fromList(vector),
      metadata: metadata,
    );
  }

  @override
  String toString() =>
      'WaffleRecord(id: $id, dim: ${vector.length}, hasMeta: ${metadata != null})';
}
