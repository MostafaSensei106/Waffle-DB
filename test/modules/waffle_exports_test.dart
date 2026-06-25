import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

/// Tests that all public types and functions are properly exported
/// from the waffle_db barrel file.
void main() {
  group('Public API exports', () {
    test('WaffleRecord is accessible', () {
      final record = WaffleRecord(
        id: 'export-test',
        vector: Float32List.fromList([0.1, 0.2, 0.3]),
      );
      expect(record.id, 'export-test');
    });

    test('WaffleRecord.fromList is accessible', () {
      final record = WaffleRecord.fromList(
        id: 'export-test-2',
        vector: [1.0, 2.0, 3.0],
      );
      expect(record.vector, isA<Float32List>());
    });

    test('WaffleConfig is accessible', () {
      final config = WaffleConfig(
        dimension: 128,
        path: '/tmp/test',
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 1000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(1024),
        workerThreads: 1,
      );
      expect(config.dimension, 128);
    });

    test('WaffleMetric enum values are accessible', () {
      expect(WaffleMetric.cosine, isNotNull);
      expect(WaffleMetric.euclidean, isNotNull);
      expect(WaffleMetric.dotProduct, isNotNull);
    });

    test('WaffleGraphConfig is accessible', () {
      const gc = WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      );
      expect(gc.m, 16);
      expect(gc.efConstruction, 64);
      expect(gc.efSearch, 32);
    });

    test('WaffleQueryResult is accessible', () {
      const result = WaffleQueryResult(
        id: 'test',
        distance: 0.5,
        metadata: null,
      );
      expect(result.id, 'test');
      expect(result.distance, 0.5);
    });

    test('VectorMetadata is accessible', () {
      final meta = VectorMetadata(
        title: 'Test',
        description: 'A test vector',
        category: 'unit-test',
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(meta.title, 'Test');
      expect(meta.category, 'unit-test');
    });
  });
}
