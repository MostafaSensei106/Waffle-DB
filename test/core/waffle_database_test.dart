import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

final _schema = WaffleSchema(
  fields: [
    WaffleFields.string('category'),
    WaffleFields.integer('price'),
  ],
  textLanguage: WaffleLanguage.english,
);

WaffleConfig _config(String path) => WaffleConfig(
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
      cacheSizeBytes: BigInt.from(1024 * 1024),
      workerThreads: 1,
    );

void main() {
  group('WaffleDatabase enterprise core', () {
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
      db = await WaffleDatabase.open(_config(path), schema: _schema);
    });

    tearDown(() async {
      await db.close();
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('Insert and filtered search', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        text: 'fast red car',
        payload: const {'category': 'auto', 'price': 100},
      );
      await db.insert(
        '2',
        Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
        text: 'slow blue boat',
        payload: const {'category': 'marine', 'price': 200},
      );

      expect(db.count(), 2);

      final results = db.search(
        vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        topK: 1,
        filter: WaffleEqFilter('category', 'auto'),
      );
      expect(results.length, 1);
      expect(results.first.id, '1');
      expect(results.first.text, 'fast red car');
      expect(results.first.payloadJson, contains('auto'));
    });

    test('Pre-filtering excludes non-matching vectors', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        payload: const {'category': 'auto', 'price': 100},
      );

      final results = db.search(
        vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        topK: 5,
        filter: WaffleEqFilter('category', 'marine'),
      );
      expect(results, isEmpty);
    });

    test('Keyword search finds indexed text', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        text: 'the quick brown fox jumps',
        payload: const {'category': 'auto', 'price': 100},
      );

      final results = db.search(text: 'quick fox', topK: 5);
      expect(results.length, 1);
      expect(results.first.id, '1');
    });

    test('Hybrid search fuses dense and sparse results', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        text: 'red sports car engine',
        payload: const {'category': 'auto', 'price': 100},
      );
      await db.insert(
        '2',
        Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
        text: 'blue ocean waves',
        payload: const {'category': 'marine', 'price': 200},
      );

      final results = await WaffleQueryBuilder(db)
          .withHybrid(
            vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
            text: 'car engine',
          )
          .limit(2)
          .execute();
      expect(results.length, 2);
      expect(results.first.id, '1');
    });

    test('Insert with wrong dimension throws', () async {
      expect(
        () => db.insert(
          '1',
          Float32List.fromList([1.0, 0.0, 0.0]),
          payload: const {'category': 'auto', 'price': 1},
        ),
        throwsA(anything),
      );
    });

    test('Search with wrong dimension throws', () async {
      expect(
        () => db.search(
          vector: Float32List.fromList([1.0, 0.0]),
          topK: 2,
        ),
        throwsA(anything),
      );
    });

    test('Insert missing an indexed field throws', () async {
      expect(
        () => db.insert(
          '1',
          Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          payload: const {'category': 'auto'},
        ),
        throwsA(anything),
      );
    });

    test('Duplicate insert throws', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        payload: const {'category': 'auto', 'price': 1},
      );
      expect(
        () => db.insert(
          '1',
          Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          payload: const {'category': 'auto', 'price': 1},
        ),
        throwsA(anything),
      );
    });

    test('Delete existing ID removes it from every engine', () async {
      await db.insert(
        '1',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        text: 'unique delete me text xyzzy',
        payload: const {'category': 'auto', 'price': 1},
      );
      expect(await db.delete('1'), isTrue);
      expect(db.getVector('1'), isNull);
      expect(db.count(), 0);

      final dense = db.search(
        vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        topK: 5,
      );
      expect(dense.where((h) => h.id == '1'), isEmpty);

      final sparse = db.search(text: 'xyzzy', topK: 5);
      expect(sparse.where((h) => h.id == '1'), isEmpty);
    });

    test('Delete non-existent ID returns false', () async {
      expect(await db.delete('non-existent'), isFalse);
    });

    test('Neighboring chunks resolve through the parent', () async {
      await db.insert(
        'parent',
        Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        text: 'parent document',
        payload: const {'category': 'auto', 'price': 1},
      );
      for (var i = 0; i < 3; i++) {
        await db.insert(
          'chunk-$i',
          Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
          text: 'chunk body $i',
          payload: const {'category': 'auto', 'price': 1},
          parentId: 'parent',
          chunkIndex: i,
        );
      }

      final neighbors = db.getNeighbors('chunk-1', window: 1);
      expect(neighbors.map((h) => h.id),
          containsAll(['chunk-0', 'chunk-1', 'chunk-2']));

      final parent = db.getParent('chunk-0');
      expect(parent?.id, 'parent');
    });

    test('Batch insert with wrong dimension throws', () async {
      final records = [
        WaffleRecord(
          id: '1',
          vector: Float32List.fromList([1.0, 1.0]),
          payload: const {'category': 'auto', 'price': 1},
        ),
      ];

      expect(
        () => db.insertBatch(records),
        throwsA(anything),
      );
    });

    test('Get all IDs retrieves exactly what was inserted', () async {
      await db.insert('A', Float32List.fromList([1, 0, 0, 0]),
          payload: const {'category': 'auto', 'price': 1});
      await db.insert('B', Float32List.fromList([0, 1, 0, 0]),
          payload: const {'category': 'auto', 'price': 2});

      final ids = db.getAllIds();
      expect(ids.length, 2);
      expect(ids, containsAll(['A', 'B']));
    });

    test('Upsert replaces and reports', () async {
      final v1 = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      expect(
        await db.upsert('u1', v1,
            payload: const {'category': 'auto', 'price': 1}),
        isFalse,
      );
      expect(
        await db.upsert(
          'u1',
          Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
          payload: const {'category': 'marine', 'price': 2},
        ),
        isTrue,
      );
      expect(db.count(), 1);
      expect(db.getPayload('u1')?['category'], 'marine');

      final filtered = db.search(
        vector: v1,
        topK: 5,
        filter: WaffleEqFilter('category', 'auto'),
      );
      expect(filtered, isEmpty);
    });

    test('DeleteBatch removes many at once', () async {
      for (var i = 0; i < 5; i++) {
        await db.insert('d$i', Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
            payload: const {'category': 'auto', 'price': 1});
      }
      expect(await db.deleteBatch(['d0', 'd1', 'd9']), 2);
      expect(db.count(), 3);
    });

    test('DeleteWhere re-indexes by filter', () async {
      await db.insert('w1', Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          payload: const {'category': 'auto', 'price': 1});
      await db.insert('w2', Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
          payload: const {'category': 'marine', 'price': 2});
      expect(await db.deleteWhere(WaffleEqFilter('category', 'auto')), 1);
      expect(db.count(), 1);
      expect(db.getAllIds(), ['w2']);
    });

    test('Offset paginates fused results', () async {
      for (var i = 0; i < 5; i++) {
        await db.insert('p$i', Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
            payload: {'category': 'auto', 'price': i});
      }
      final first = db.search(
        vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        topK: 2,
      );
      final second = db.search(
        vector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        topK: 2,
        offset: 2,
      );
      expect(first.length, 2);
      expect(second.length, 2);
      expect(
        second.map((h) => h.id).toSet().intersection(
              first.map((h) => h.id).toSet(),
            ),
        isEmpty,
      );
    });
  });
}
