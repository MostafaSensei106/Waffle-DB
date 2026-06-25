import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late WaffleDatabase db;
  late String dbPath;
  const int dim = 64;

  Float32List randomVector(int seed) {
    final v = Float32List(dim);
    for (int i = 0; i < dim; i++) {
      v[i] = ((seed * 17 + i * 31) % 1000) / 1000.0;
    }
    return v;
  }

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    dbPath =
        '${Directory.systemTemp.path}/waffle_test_${DateTime.now().millisecondsSinceEpoch}';
    final config = WaffleConfig(
      dimension: dim,
      path: dbPath,
      graphConfig: const WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      ),
      maxElements: 10000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
      workerThreads: 2,
    );
    db = await WaffleDatabase.open(config);
  });

  tearDown(() async {
    if (db.isOpen) {
      await db.close();
    }
    try {
      final dir = Directory(dbPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  });

  // ---------------------------------------------------------------
  // Open / Close
  // ---------------------------------------------------------------

  group('Open / Close', () {
    testWidgets('open returns an open database', (tester) async {
      expect(db.isOpen, isTrue);
    });

    testWidgets('close sets isOpen to false', (tester) async {
      await db.close();
      expect(db.isOpen, isFalse);
    });

    testWidgets('operations after close throw StateError', (tester) async {
      await db.close();
      expect(() => db.count(), throwsStateError);
      expect(() => db.insert('x', Float32List(dim)), throwsStateError);
      expect(() => db.query(Float32List(dim)), throwsStateError);
    });
  });

  // ---------------------------------------------------------------
  // Insert
  // ---------------------------------------------------------------

  group('Insert', () {
    testWidgets('single insert increases count', (tester) async {
      expect(await db.count(), 0);
      await db.insert('v1', randomVector(1));
      expect(await db.count(), 1);
    });

    testWidgets('insert multiple vectors', (tester) async {
      for (int i = 0; i < 10; i++) {
        await db.insert('v$i', randomVector(i));
      }
      expect(await db.count(), 10);
    });

    testWidgets('insert with metadata', (tester) async {
      final meta = Uint8List.fromList([10, 20, 30, 40]);
      await db.insert('vm1', randomVector(42), metadata: meta);
      final retrieved = await db.getMetadata('vm1');
      expect(retrieved, isNotNull);
    });

    testWidgets('insert without metadata stores empty', (tester) async {
      await db.insert('vm2', randomVector(99));
      expect(await db.count(), 1);
    });
  });

  // ---------------------------------------------------------------
  // Batch Insert
  // ---------------------------------------------------------------

  group('Batch Insert', () {
    testWidgets('batch insert adds all records', (tester) async {
      final records = List.generate(
        50,
        (i) => WaffleRecord(id: 'batch-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);
      expect(await db.count(), 50);
    });

    testWidgets('batch insert with metadata', (tester) async {
      final records = List.generate(
        10,
        (i) => WaffleRecord(
          id: 'bm-$i',
          vector: randomVector(i),
          metadata: Uint8List.fromList([i, i + 1]),
        ),
      );
      await db.insertBatch(records);
      expect(await db.count(), 10);
    });

    testWidgets('empty batch is a no-op', (tester) async {
      await db.insertBatch([]);
      expect(await db.count(), 0);
    });
  });

  // ---------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------

  group('Query', () {
    testWidgets('query returns nearest neighbor (self)', (tester) async {
      final v = randomVector(7);
      await db.insert('target', v);
      for (int i = 0; i < 20; i++) {
        await db.insert('other-$i', randomVector(i + 100));
      }

      final results = await db.query(v, k: 1);
      expect(results, isNotEmpty);
      expect(results.first.id, 'target');
      expect(results.first.distance, closeTo(0.0, 0.01));
    });

    testWidgets('query k limits results', (tester) async {
      for (int i = 0; i < 20; i++) {
        await db.insert('qk-$i', randomVector(i));
      }

      final results5 = await db.query(randomVector(0), k: 5);
      final results10 = await db.query(randomVector(0), k: 10);

      expect(results5.length, 5);
      expect(results10.length, 10);
    });

    testWidgets('query results sorted by distance ascending', (tester) async {
      for (int i = 0; i < 30; i++) {
        await db.insert('sorted-$i', randomVector(i));
      }

      final results = await db.query(randomVector(0), k: 10);
      for (int i = 1; i < results.length; i++) {
        expect(
          results[i].distance,
          greaterThanOrEqualTo(results[i - 1].distance),
        );
      }
    });

    testWidgets('query with custom efSearch', (tester) async {
      for (int i = 0; i < 50; i++) {
        await db.insert('ef-$i', randomVector(i));
      }

      final resultsLow = await db.query(randomVector(0), k: 5, efSearch: 8);
      final resultsHigh =
          await db.query(randomVector(0), k: 5, efSearch: 128);

      expect(resultsLow.length, 5);
      expect(resultsHigh.length, 5);
    });

    testWidgets('query empty database returns empty', (tester) async {
      final results = await db.query(randomVector(0), k: 5);
      expect(results, isEmpty);
    });
  });

  // ---------------------------------------------------------------
  // Get Vector
  // ---------------------------------------------------------------

  group('Get Vector', () {
    testWidgets('getVector retrieves stored vector', (tester) async {
      final v = randomVector(42);
      await db.insert('gv-1', v);
      final retrieved = await db.getVector('gv-1');

      expect(retrieved, isNotNull);
      expect(retrieved!.length, dim);
      for (int i = 0; i < dim; i++) {
        expect(retrieved[i], closeTo(v[i], 0.001));
      }
    });

    testWidgets('getVector returns null for missing ID', (tester) async {
      final result = await db.getVector('nonexistent');
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------
  // Get Metadata
  // ---------------------------------------------------------------

  group('Get Metadata', () {
    testWidgets('getMetadata retrieves stored metadata', (tester) async {
      final meta = Uint8List.fromList([100, 200, 42]);
      await db.insert('gm-1', randomVector(1), metadata: meta);
      final retrieved = await db.getMetadata('gm-1');
      expect(retrieved, isNotNull);
    });

    testWidgets('getMetadata returns null for missing ID', (tester) async {
      final result = await db.getMetadata('nonexistent');
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------

  group('Delete', () {
    testWidgets('delete removes from storage', (tester) async {
      await db.insert('del-1', randomVector(1));
      expect(await db.count(), 1);

      final removed = await db.delete('del-1');
      expect(removed, isTrue);
      expect(await db.count(), 0);
    });

    testWidgets('delete nonexistent returns false', (tester) async {
      final removed = await db.delete('no-such-id');
      expect(removed, isFalse);
    });

    testWidgets('getVector returns null after delete', (tester) async {
      await db.insert('del-2', randomVector(2));
      await db.delete('del-2');
      final result = await db.getVector('del-2');
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------
  // Count
  // ---------------------------------------------------------------

  group('Count', () {
    testWidgets('count starts at 0', (tester) async {
      expect(await db.count(), 0);
    });

    testWidgets('count reflects inserts and deletes', (tester) async {
      await db.insert('c1', randomVector(1));
      await db.insert('c2', randomVector(2));
      expect(await db.count(), 2);

      await db.delete('c1');
      expect(await db.count(), 1);
    });
  });

  // ---------------------------------------------------------------
  // Get All IDs
  // ---------------------------------------------------------------

  group('Get All IDs', () {
    testWidgets('getAllIds returns all inserted IDs', (tester) async {
      await db.insert('id-a', randomVector(1));
      await db.insert('id-b', randomVector(2));
      await db.insert('id-c', randomVector(3));

      final ids = await db.getAllIds();
      expect(ids.length, 3);
      expect(ids, containsAll(['id-a', 'id-b', 'id-c']));
    });

    testWidgets('getAllIds on empty db returns empty', (tester) async {
      final ids = await db.getAllIds();
      expect(ids, isEmpty);
    });
  });

  // ---------------------------------------------------------------
  // Flush
  // ---------------------------------------------------------------

  group('Flush', () {
    testWidgets('flush does not throw', (tester) async {
      await db.insert('f1', randomVector(1));
      await db.flush();
    });
  });

  // ---------------------------------------------------------------
  // WaffleQueryBuilder
  // ---------------------------------------------------------------

  group('WaffleQueryBuilder', () {
    testWidgets('basic builder query works', (tester) async {
      for (int i = 0; i < 30; i++) {
        await db.insert('qb-$i', randomVector(i));
      }

      final results = await WaffleQueryBuilder(db)
          .withVector(randomVector(0))
          .limit(5)
          .execute();

      expect(results.length, 5);
    });

    testWidgets('threshold filters distant results', (tester) async {
      final target = randomVector(0);
      await db.insert('close', target);
      for (int i = 1; i < 20; i++) {
        await db.insert('far-$i', randomVector(i + 500));
      }

      final results = await WaffleQueryBuilder(db)
          .withVector(target)
          .limit(20)
          .threshold(0.01)
          .execute();

      for (final r in results) {
        expect(r.distance, lessThanOrEqualTo(0.01));
      }
    });

    testWidgets('efSearch override works', (tester) async {
      for (int i = 0; i < 50; i++) {
        await db.insert('ef-$i', randomVector(i));
      }

      final results = await WaffleQueryBuilder(db)
          .withVector(randomVector(0))
          .limit(5)
          .efSearch(128)
          .execute();

      expect(results.length, 5);
    });

    testWidgets('includeMetadata false strips metadata', (tester) async {
      await db.insert(
        'meta-strip',
        randomVector(1),
        metadata: Uint8List.fromList([1, 2, 3]),
      );

      final results = await WaffleQueryBuilder(db)
          .withVector(randomVector(1))
          .limit(1)
          .includeMetadata(false)
          .execute();

      expect(results, isNotEmpty);
      expect(results.first.metadata, isNull);
    });

    testWidgets('withVectorList works', (tester) async {
      await db.insert('vl-1', randomVector(1));

      final v = randomVector(1);
      final results = await WaffleQueryBuilder(db)
          .withVectorList(v.toList().cast<double>())
          .limit(1)
          .execute();

      expect(results, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------
  // WaffleCollection
  // ---------------------------------------------------------------

  group('WaffleCollection', () {
    testWidgets('add and search within collection', (tester) async {
      final col = WaffleCollection(db, 'docs');

      final v = randomVector(1);
      await col.add('doc-1', v);
      await col.add('doc-2', randomVector(2));

      final results = await col.search(v, topK: 1);
      expect(results, isNotEmpty);
      expect(results.first.id, 'doc-1');
    });

    testWidgets('collection IDs are namespaced', (tester) async {
      final col = WaffleCollection(db, 'ns');
      await col.add('item', randomVector(1));

      final allIds = await db.getAllIds();
      expect(allIds, contains('ns::item'));
    });

    testWidgets('delete from collection', (tester) async {
      final col = WaffleCollection(db, 'del');
      await col.add('x', randomVector(1));
      expect(await db.count(), 1);

      await col.delete('x');
      expect(await db.count(), 0);
    });

    testWidgets('batch add to collection', (tester) async {
      final col = WaffleCollection(db, 'batch');
      final records = List.generate(
        10,
        (i) => WaffleRecord(id: 'b-$i', vector: randomVector(i)),
      );
      await col.addBatch(records);
      expect(await db.count(), 10);
    });

    testWidgets('getMetadata in collection', (tester) async {
      final col = WaffleCollection(db, 'meta');
      await col.add('m1', randomVector(1),
          metadata: Uint8List.fromList([42]));
      final meta = await col.getMetadata('m1');
      expect(meta, isNotNull);
    });

    testWidgets('getVector in collection', (tester) async {
      final col = WaffleCollection(db, 'vec');
      final v = randomVector(7);
      await col.add('v1', v);
      final retrieved = await col.getVector('v1');
      expect(retrieved, isNotNull);
      expect(retrieved!.length, dim);
    });
  });

  // ---------------------------------------------------------------
  // Cosine Similarity
  // ---------------------------------------------------------------

  group('cosineSimilarity', () {
    testWidgets('identical vectors have similarity ~1.0', (tester) async {
      final v = List<double>.generate(dim, (i) => (i + 1) * 0.1);
      final sim = await cosineSimilarity(a: v, b: v);
      expect(sim, closeTo(1.0, 0.01));
    });

    testWidgets('orthogonal vectors have similarity ~0', (tester) async {
      final a = List<double>.filled(4, 0.0)..[0] = 1.0;
      final b = List<double>.filled(4, 0.0)..[1] = 1.0;
      final sim = await cosineSimilarity(a: a, b: b);
      expect(sim, closeTo(0.0, 0.01));
    });
  });

  // ---------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------

  group('Persistence', () {
    testWidgets('data survives close and reopen', (tester) async {
      final v = randomVector(42);
      await db.insert('persist-1', v,
          metadata: Uint8List.fromList([1, 2, 3]));
      await db.insert('persist-2', randomVector(43));
      await db.close();

      // Reopen same path
      final config = WaffleConfig(
        dimension: dim,
        path: dbPath,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 10000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
        workerThreads: 2,
      );
      db = await WaffleDatabase.open(config);

      expect(await db.count(), 2);

      final ids = await db.getAllIds();
      expect(ids, containsAll(['persist-1', 'persist-2']));

      final retrieved = await db.getVector('persist-1');
      expect(retrieved, isNotNull);
      for (int i = 0; i < dim; i++) {
        expect(retrieved![i], closeTo(v[i], 0.001));
      }

      // Query should still work (HNSW rebuilt from disk)
      final results = await db.query(v, k: 1);
      expect(results, isNotEmpty);
      expect(results.first.id, 'persist-1');
    });
  });
}
