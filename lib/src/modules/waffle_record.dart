import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newWaffleId() => _uuid.v7();

class WaffleRecord {
  final String id;
  final Float32List vector;
  final String text;
  final Map<String, dynamic> payload;
  final String? parentId;
  final int chunkIndex;

  const WaffleRecord({
    required this.id,
    required this.vector,
    this.text = '',
    this.payload = const {},
    this.parentId,
    this.chunkIndex = 0,
  });

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

  String get payloadJson => jsonEncode(payload);

  @override
  String toString() =>
      'WaffleRecord(id: $id, dim: ${vector.length}, text: ${text.length} chars)';
}
