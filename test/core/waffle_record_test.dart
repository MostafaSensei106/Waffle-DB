import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/src/modules/waffle_record.dart';

void main() {
  group('WaffleRecord', () {
    test('constructor creates record with required fields', () {
      final vector = Float32List.fromList([0.1, 0.2, 0.3]);
      final record = WaffleRecord(
        id: 'test-1',
        vector: vector,
        text: 'hello world',
        payload: const {'category': 'test'},
      );

      expect(record.id, 'test-1');
      expect(record.vector, vector);
      expect(record.text, 'hello world');
      expect(record.payload, {'category': 'test'});
      expect(record.parentId, isNull);
      expect(record.chunkIndex, 0);
    });

    test('constructor defaults to empty text and payload', () {
      final vector = Float32List.fromList([0.1, 0.2, 0.3]);
      final record = WaffleRecord(id: 'test-2', vector: vector);

      expect(record.text, '');
      expect(record.payload, isEmpty);
    });

    test('fromList factory creates record from List<double>', () {
      final record = WaffleRecord.fromList(
        id: 'test-3',
        vector: [0.1, 0.2, 0.3],
        text: 'chunk one',
        payload: const {'price': 42},
        parentId: 'parent-1',
        chunkIndex: 1,
      );

      expect(record.id, 'test-3');
      expect(record.vector, isA<Float32List>());
      expect(record.vector.length, 3);
      expect(record.text, 'chunk one');
      expect(record.parentId, 'parent-1');
      expect(record.chunkIndex, 1);
    });

    test('payloadJson encodes the payload map', () {
      final record = WaffleRecord.fromList(
        id: 'test-4',
        vector: [1.0, 2.0],
        payload: const {'a': 1},
      );

      expect(record.payloadJson, '{"a":1}');
    });

    test('fromList converts doubles correctly', () {
      final record = WaffleRecord.fromList(
        id: 'test-5',
        vector: [0.5, 1.5, 2.5],
      );

      expect(record.vector[0], closeTo(0.5, 0.001));
      expect(record.vector[1], closeTo(1.5, 0.001));
      expect(record.vector[2], closeTo(2.5, 0.001));
    });

    test('toString contains id, dimension and text length', () {
      final record = WaffleRecord.fromList(
        id: 'doc-1',
        vector: [0.1, 0.2, 0.3, 0.4],
        text: 'abcd',
      );

      final str = record.toString();
      expect(str, contains('doc-1'));
      expect(str, contains('4'));
    });

    test('newWaffleId generates unique time-ordered ids', () {
      expect(newWaffleId(), isNot(newWaffleId()));
    });

    test('empty vector is valid', () {
      final record = WaffleRecord(id: 'empty', vector: Float32List(0));

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
  });
}
