import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

void main() {
  group('WaffleDatabase Edge Cases & Refactored Coverage', () {
    final path = '/tmp/waffle_db_core_test';
    late WaffleDatabase db;

    setUpAll(() async {
      await WaffleDB.init();
    });

    setUp(() async {
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      final config = WaffleConfig(
        dimension: 4,
        path: path,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 1000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(1024 * 1024), // 1MB
        workerThreads: 1,
      );
      db = await WaffleDatabase.open(config);
    });

    tearDown(() async {
      await db.close();
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('Insert and Query - Normal behavior', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        metadata: Uint8List.fromList([1]),
      );
      await db.insert(
        '2',
        Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
      );

      final count = db.count();
      expect(count, 2);

      final results = db.query(
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        k: 1,
      );
      expect(results.length, 1);
      expect(results.first.id, '1');
    });

    test('Insert with wrong dimension throws exception', () async {
      expect(
        () => db.insert(
          '1',
          Float32List.fromList([1.0, 0.0, 0.0]), // 3 dims instead of 4
        ),
        throwsA(anything),
      );
    });

    test('Query with wrong dimension throws exception', () async {
      expect(
        () => db.query(
          Float32List.fromList([1.0, 0.0]), // 2 dims instead of 4
          k: 2,
        ),
        throwsA(anything),
      );
    });

    test('Delete non-existent ID gracefully returns false or ignores', () async {
      final removed = await db.delete('non-existent');
      expect(removed, isFalse);
    });

    test('Delete existing ID removes it from queries', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
      );
      final countBefore = db.count();
      expect(countBefore, 1);

      final removed = await db.delete('1');
      expect(removed, isTrue);

      // Verify deletion via getVector
      final vector = db.getVector('1');
      expect(vector, isNull);

      final countAfter = db.count();
      expect(countAfter, 0);
    });

    test('Insert Batch with mismatching sizes throws exception', () async {
      // Trying to insert a record where vector length does not match DB dimension
      final records = [
        WaffleRecord(
          id: '1',
          vector: Float32List.fromList([1.0, 1.0]), // Wrong
        ),
      ];
      
      expect(
        () => db.insertBatch(records),
        throwsA(anything),
      );
    });

    test('Get All IDs retrieves exactly what was inserted', () async {
      await db.insert('A', Float32List.fromList([1,0,0,0]));
      await db.insert('B', Float32List.fromList([0,1,0,0]));
      
      final ids = db.getAllIds();
      expect(ids.length, 2);
      expect(ids, containsAll(['A', 'B']));
    });
  });
}
