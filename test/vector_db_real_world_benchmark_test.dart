import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:waffle_db/waffle_db.dart';

void cleanPath(String path) {
  final dir = Directory(path);
  if (dir.existsSync()) {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

// 1. Open and Close Benchmark
class OpenCloseBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_open_close';

  OpenCloseBenchmark() : super("Database Open & Close");

  @override
  Future<void> run() async {
    final config = WaffleConfig(
      dimension: 128,
      path: path,
      graphConfig: const WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      ),
      maxElements: 1000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
      workerThreads: 2,
    );
    final db = await WaffleDatabase.open(config);
    await db.close();
  }

  @override
  Future<void> teardown() async {
    cleanPath(path);
  }
}

// 2. Single Insertion Benchmark
class SingleInsertBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_single_insert';
  late WaffleDatabase db;
  int _counter = 0;
  final _random = Random();
  late Float32List _vector;

  SingleInsertBenchmark() : super("Insert Single Vector (128-dim)");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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
    _vector =
        Float32List.fromList(List.generate(128, (_) => _random.nextDouble()));
  }

  @override
  Future<void> run() async {
    await db.insert(
      'item-$_counter',
      _vector,
      metadata: Uint8List.fromList([1, 2, 3, 4]),
    );
    _counter++;
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 3. Batch Insertion Benchmark
class BatchInsertBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_batch_insert';
  late WaffleDatabase db;
  int _counter = 0;
  final _random = Random();
  late List<WaffleRecord> _batch;

  BatchInsertBenchmark() : super("Insert Batch (1000 vectors, 128-dim)");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
      graphConfig: const WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      ),
      maxElements: 100000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
      workerThreads: 2,
    );
    db = await WaffleDatabase.open(config);
    _batch = List.generate(
      1000,
      (i) => WaffleRecord(
        id: 'temp-$i',
        vector: Float32List.fromList(
            List.generate(128, (_) => _random.nextDouble())),
        metadata: Uint8List.fromList([9, 8, 7, 6]),
      ),
    );
  }

  @override
  Future<void> run() async {
    final records = _batch.map((r) {
      return WaffleRecord(
        id: 'item-${_counter++}',
        vector: r.vector,
        metadata: r.metadata,
      );
    }).toList();
    await db.insertBatch(records);
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 4. Query Without Metadata Benchmark
class QueryWithoutMetadataBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_query_no_meta';
  late WaffleDatabase db;
  final _random = Random();
  late Float32List _queryVector;

  QueryWithoutMetadataBenchmark()
      : super("Query KNN (k=10, efSearch=32, no metadata)");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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

    // Prepopulate with 1000 vectors
    final records = List.generate(
      1000,
      (i) => WaffleRecord(
        id: 'item-$i',
        vector: Float32List.fromList(
            List.generate(128, (_) => _random.nextDouble())),
        metadata: Uint8List.fromList([1, 2, 3]),
      ),
    );
    await db.insertBatch(records);
    _queryVector =
        Float32List.fromList(List.generate(128, (_) => _random.nextDouble()));
  }

  @override
  Future<void> run() async {
    db.query(_queryVector, k: 10, efSearch: 32, includeMetadata: false);
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 5. Query With Metadata Benchmark
class QueryWithMetadataBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_query_with_meta';
  late WaffleDatabase db;
  final _random = Random();
  late Float32List _queryVector;

  QueryWithMetadataBenchmark()
      : super("Query KNN (k=10, efSearch=32, with metadata)");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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

    // Prepopulate with 1000 vectors
    final records = List.generate(
      1000,
      (i) => WaffleRecord(
        id: 'item-$i',
        vector: Float32List.fromList(
            List.generate(128, (_) => _random.nextDouble())),
        metadata: Uint8List.fromList([1, 2, 3]),
      ),
    );
    await db.insertBatch(records);
    _queryVector =
        Float32List.fromList(List.generate(128, (_) => _random.nextDouble()));
  }

  @override
  Future<void> run() async {
    db.query(_queryVector, k: 10, efSearch: 32, includeMetadata: true);
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 6. Get Vector Benchmark
class GetVectorBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_get_vector';
  late WaffleDatabase db;
  final _random = Random();

  GetVectorBenchmark() : super("Get Vector by ID");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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

    await db.insert(
      'target-item',
      Float32List.fromList(List.generate(128, (_) => _random.nextDouble())),
    );
  }

  @override
  Future<void> run() async {
    db.getVector('target-item');
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 7. Get Metadata Benchmark
class GetMetadataBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_get_metadata';
  late WaffleDatabase db;
  final _random = Random();

  GetMetadataBenchmark() : super("Get Metadata by ID");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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

    await db.insert(
      'target-item',
      Float32List.fromList(List.generate(128, (_) => _random.nextDouble())),
      metadata: Uint8List.fromList([100, 101, 102]),
    );
  }

  @override
  Future<void> run() async {
    db.getMetadata('target-item');
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 8. Delete Benchmark
class DeleteBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_delete';
  late WaffleDatabase db;
  int _counter = 0;
  final _random = Random();

  DeleteBenchmark() : super("Delete Record");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
      graphConfig: const WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      ),
      maxElements: 100000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
      workerThreads: 2,
    );
    db = await WaffleDatabase.open(config);

    // Prepopulate with 10,000 items to delete from
    final records = List.generate(
      10000,
      (i) => WaffleRecord(
        id: 'item-$i',
        vector: Float32List.fromList(
            List.generate(128, (_) => _random.nextDouble())),
      ),
    );
    await db.insertBatch(records);
  }

  @override
  Future<void> run() async {
    await db.delete('item-$_counter');
    _counter++;
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

// 9. Get All IDs Benchmark
class GetAllIdsBenchmark extends AsyncBenchmarkBase {
  final String path = '/tmp/waffle_bench_get_all_ids';
  late WaffleDatabase db;
  final _random = Random();

  GetAllIdsBenchmark() : super("Get All IDs (1000 elements)");

  @override
  Future<void> setup() async {
    cleanPath(path);
    final config = WaffleConfig(
      dimension: 128,
      path: path,
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

    final records = List.generate(
      1000,
      (i) => WaffleRecord(
        id: 'item-$i',
        vector: Float32List.fromList(
            List.generate(128, (_) => _random.nextDouble())),
      ),
    );
    await db.insertBatch(records);
  }

  @override
  Future<void> run() async {
    db.getAllIds();
  }

  @override
  Future<void> teardown() async {
    await db.close();
    cleanPath(path);
  }
}

void main() {
  group('WaffleDB Real-World Benchmark Suite', () {
    test('Run benchmark harness for all operations', () async {
      await WaffleDB.init();

      print('\n==================================================');
      print('          WAFFLE-DB PERFORMANCE BENCHMARK          ');
      print('==================================================');

      final openClose = OpenCloseBenchmark();
      await openClose.report();

      final singleInsert = SingleInsertBenchmark();
      await singleInsert.report();

      final batchInsert = BatchInsertBenchmark();
      await batchInsert.report();

      final queryNoMeta = QueryWithoutMetadataBenchmark();
      await queryNoMeta.report();

      final queryWithMeta = QueryWithMetadataBenchmark();
      await queryWithMeta.report();

      final getVector = GetVectorBenchmark();
      await getVector.report();

      final getMetadata = GetMetadataBenchmark();
      await getMetadata.report();

      final delete = DeleteBenchmark();
      await delete.report();

      final getAllIds = GetAllIdsBenchmark();
      await getAllIds.report();

      print('==================================================\n');
    });
  });
}
