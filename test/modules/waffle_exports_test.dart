import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

void main() {
  group('Public API exports', () {
    test('WaffleRecord is accessible', () {
      final record = WaffleRecord(
        id: 'export-test',
        vector: Float32List.fromList([0.1, 0.2, 0.3]),
      );
      expect(record.id, 'export-test');
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

    test('WaffleHit is accessible', () {
      const hit = WaffleHit(id: 'test', score: 0.9);
      expect(hit.id, 'test');
      expect(hit.score, 0.9);
    });

    test('WaffleSchema DSL is accessible', () {
      final schema = WaffleSchema(
        fields: [
          WaffleFields.string('category'),
          WaffleFields.integer('price'),
        ],
        textLanguage: WaffleLanguage.english,
      );
      expect(schema.fields.length, 2);
      expect(schema.textLanguage, WaffleLanguage.english);
    });

    test('WaffleFilter builders are accessible', () {
      final filter = WaffleEqFilter('category', 'auto');
      expect(filter.encode(), contains('"op":"eq"'));
      final combined =
          WaffleAndFilter([filter, WaffleInFilter('price', [1, 2])]);
      expect(combined.encode(), contains('"op":"and"'));
    });
  });
}
