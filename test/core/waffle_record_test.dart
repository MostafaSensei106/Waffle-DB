import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/src/modules/waffle_record.dart';

void main() {
  group('WaffleRecord', () {
    test('constructor creates record with required fields', () {
      final vector = Float32List.fromList([0.1, 0.2, 0.3]);
      final metadata = Uint8List.fromList([1, 2, 3]);
      final record =
          WaffleRecord(id: 'test-1', vector: vector, metadata: metadata);

      expect(record.id, 'test-1');
      expect(record.vector, vector);
      expect(record.metadata, metadata);
    });

    test('constructor with null metadata', () {
      final vector = Float32List.fromList([0.1, 0.2, 0.3]);
      final record = WaffleRecord(id: 'test-2', vector: vector);

      expect(record.id, 'test-2');
      expect(record.vector, vector);
      expect(record.metadata, isNull);
    });

    test('fromList factory creates record from List<double>', () {
      final record = WaffleRecord.fromList(
        id: 'test-3',
        vector: [0.1, 0.2, 0.3],
        metadata: Uint8List.fromList([10, 20]),
      );

      expect(record.id, 'test-3');
      expect(record.vector, isA<Float32List>());
      expect(record.vector.length, 3);
      expect(record.metadata, isNotNull);
      expect(record.metadata!.length, 2);
    });

    test('fromList factory with null metadata', () {
      final record = WaffleRecord.fromList(
        id: 'test-4',
        vector: [1.0, 2.0],
      );

      expect(record.metadata, isNull);
    });

    test('fromList converts doubles correctly', () {
      final record = WaffleRecord.fromList(
        id: 'test-5',
        vector: [0.5, 1.5, 2.5],
      );

      // Float32 has limited precision
      expect(record.vector[0], closeTo(0.5, 0.001));
      expect(record.vector[1], closeTo(1.5, 0.001));
      expect(record.vector[2], closeTo(2.5, 0.001));
    });

    test('toString contains id, dimension, and hasMeta=true', () {
      final record = WaffleRecord.fromList(
        id: 'doc-1',
        vector: [0.1, 0.2, 0.3, 0.4],
        metadata: Uint8List.fromList([1]),
      );

      final str = record.toString();
      expect(str, contains('doc-1'));
      expect(str, contains('4'));
      expect(str, contains('true'));
    });

    test('toString shows hasMeta as false when no metadata', () {
      final record = WaffleRecord.fromList(
        id: 'doc-2',
        vector: [0.1],
      );

      expect(record.toString(), contains('false'));
    });

    test('empty vector is valid', () {
      final record = WaffleRecord(
        id: 'empty',
        vector: Float32List(0),
      );

      expect(record.vector.length, 0);
    });

    test('large vector preserves length', () {
      final vector = Float32List(1536);
      for (int i = 0; i < 1536; i++) {
        vector[i] = i * 0.001;
      }
      final record = WaffleRecord(id: 'large', vector: vector);

      expect(record.vector.length, 1536);
    });

    test('fromList large vector preserves all values', () {
      final doubles = List<double>.generate(384, (i) => i * 0.01);
      final record = WaffleRecord.fromList(id: 'large-fl', vector: doubles);

      expect(record.vector.length, 384);
      for (int i = 0; i < 384; i++) {
        expect(record.vector[i], closeTo(i * 0.01, 0.001));
      }
    });
  });
}
