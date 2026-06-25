// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

// ═══════════════════════════════════════════════════════════════════
//  Benchmark Statistics
// ═══════════════════════════════════════════════════════════════════

class BenchmarkStats {
  final String name;
  final List<double> latenciesUs; // microseconds, sorted
  final int count;

  BenchmarkStats(this.name, List<double> raw)
    : latenciesUs = List<double>.from(raw)..sort(),
      count = raw.length;

  double get min => latenciesUs.first;
  double get max => latenciesUs.last;
  double get avg => latenciesUs.reduce((a, b) => a + b) / count;
  double get median => _percentile(50);
  double get p50 => _percentile(50);
  double get p90 => _percentile(90);
  double get p95 => _percentile(95);
  double get p99 => _percentile(99);

  double get stdDev {
    final m = avg;
    final variance =
        latenciesUs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) /
        count;
    return sqrt(variance);
  }

  /// Throughput in operations per second.
  double get opsPerSec => count / (latenciesUs.reduce((a, b) => a + b) / 1e6);

  double _percentile(int p) {
    final index = ((p / 100) * (count - 1)).round();
    return latenciesUs[index.clamp(0, count - 1)];
  }

  String _fmtUs(double us) {
    if (us >= 1e6) return '${(us / 1e6).toStringAsFixed(2)}s';
    if (us >= 1e3) return '${(us / 1e3).toStringAsFixed(2)}ms';
    return '${us.toStringAsFixed(1)}µs';
  }

  @override
  String toString() {
    return '''
╔══════════════════════════════════════════════════════════════
║ BENCHMARK: $name
║ Iterations: $count
╠══════════════════════════════════════════════════════════════
║  Min       : ${_fmtUs(min)}
║  P50       : ${_fmtUs(p50)}
║  P90       : ${_fmtUs(p90)}
║  P95       : ${_fmtUs(p95)}
║  P99       : ${_fmtUs(p99)}
║  Max       : ${_fmtUs(max)}
║  Avg       : ${_fmtUs(avg)}
║  StdDev    : ${_fmtUs(stdDev)}
║  Throughput: ${opsPerSec.toStringAsFixed(0)} ops/sec
╚══════════════════════════════════════════════════════════════''';
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late WaffleDatabase db;
  late String dbPath;
  const int dim = 128;
  const int warmup = 5;
  const int iterations = 100;

  Float32List randomVector(int seed) {
    final rng = Random(seed);
    final v = Float32List(dim);
    for (int i = 0; i < dim; i++) {
      v[i] = rng.nextDouble().toDouble();
    }
    return v;
  }

  Future<BenchmarkStats> benchmark(
    String name,
    Future<void> Function() fn, {
    int warmupRuns = warmup,
    int runs = iterations,
  }) async {
    // Warmup
    for (int i = 0; i < warmupRuns; i++) {
      await fn();
    }

    // Measured runs
    final latencies = <double>[];
    for (int i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await fn();
      sw.stop();
      latencies.add(sw.elapsedMicroseconds.toDouble());
    }

    final stats = BenchmarkStats(name, latencies);
    print(stats);
    return stats;
  }

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    dbPath =
        '${Directory.systemTemp.path}/waffle_bench_${DateTime.now().millisecondsSinceEpoch}';
    final config = WaffleConfig(
      dimension: dim,
      path: dbPath,
      graphConfig: const WaffleGraphConfig(
        m: 16,
        metric: WaffleMetric.cosine,
        efConstruction: 64,
        efSearch: 32,
      ),
      maxElements: 100000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(64 * 1024 * 1024),
      workerThreads: 4,
    );
    db = await WaffleDatabase.open(config);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    try {
      final dir = Directory(dbPath);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  // ───────────────────────────────────────────────────────────────
  //  Benchmarks
  // ───────────────────────────────────────────────────────────────

  group('🚀 Performance Benchmarks', () {
    testWidgets('Single Insert Latency', (tester) async {
      int counter = 0;
      final vectors = List.generate(
        iterations + warmup,
        (i) => randomVector(i),
      );

      final stats = await benchmark('Single Insert (dim=$dim)', () async {
        final idx = counter++;
        await db.insert('bench-insert-$idx', vectors[idx]);
      });
      // Sanity: p99 should be under 50ms
      expect(stats.p99, lessThan(50000));
    });

    testWidgets('Batch Insert 100 vectors', (tester) async {
      int batch = 0;
      final stats = await benchmark(
        'Batch Insert ×100 (dim=$dim)',
        () async {
          final records = List.generate(
            100,
            (i) => WaffleRecord(
              id: 'batch-${batch * 100 + i}',
              vector: randomVector(batch * 100 + i),
            ),
          );
          await db.insertBatch(records);
          batch++;
        },
        warmupRuns: 2,
        runs: 20,
      );
      expect(stats.p99, lessThan(5000000)); // < 5s
    });

    testWidgets('Query k=10 over 1,000 vectors', (tester) async {
      // Pre-populate
      final records = List.generate(
        1000,
        (i) => WaffleRecord(id: 'q-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);

      final queries = List.generate(
        iterations + warmup,
        (i) => randomVector(i + 1000),
      );

      int qc = 0;
      final stats = await benchmark('Query k=10 (N=1000, dim=$dim)', () async {
        final idx = qc++;
        db.query(queries[idx], k: 10);
      });
      expect(stats.p99, lessThan(100000)); // < 100ms
    });

    testWidgets('Query k=50 over 1,000 vectors', (tester) async {
      final records = List.generate(
        1000,
        (i) => WaffleRecord(id: 'q50-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);

      final queries = List.generate(
        iterations + warmup,
        (i) => randomVector(i + 2000),
      );

      int qc = 0;
      final stats = await benchmark('Query k=50 (N=1000, dim=$dim)', () async {
        final idx = qc++;
        db.query(queries[idx], k: 50);
      });
      expect(stats.p99, lessThan(200000)); // < 200ms
    });

    testWidgets('Query with high efSearch (k=10, ef=256)', (tester) async {
      final records = List.generate(
        1000,
        (i) => WaffleRecord(id: 'ef-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);

      int qc = 0;
      final stats = await benchmark(
        'Query k=10 ef=256 (N=1000, dim=$dim)',
        () async {
          db.query(randomVector(qc++), k: 10, efSearch: 256);
        },
      );
      expect(stats.p99, lessThan(500000)); // < 500ms
    });

    testWidgets('Count Latency', (tester) async {
      for (int i = 0; i < 100; i++) {
        await db.insert('cnt-$i', randomVector(i));
      }

      final stats = await benchmark('Count (N=100)', () async {
        db.count();
      });
      expect(stats.p99, lessThan(10000)); // < 10ms
    });

    testWidgets('GetVector Latency', (tester) async {
      for (int i = 0; i < 100; i++) {
        await db.insert('gv-$i', randomVector(i));
      }

      int gc = 0;
      final stats = await benchmark('GetVector (N=100, dim=$dim)', () async {
        final idx = gc % 100;
        db.getVector('gv-$idx');
        gc++;
      });
      expect(stats.p99, lessThan(10000)); // < 10ms
    });

    testWidgets('GetMetadata Latency', (tester) async {
      for (int i = 0; i < 100; i++) {
        await db.insert(
          'gm-$i',
          randomVector(i),
          metadata: Uint8List.fromList(List.generate(64, (j) => j)),
        );
      }

      int mc = 0;
      final stats = await benchmark('GetMetadata (N=100)', () async {
        db.getMetadata('gm-${mc % 100}');
        mc++;
      });
      expect(stats.p99, lessThan(10000)); // < 10ms
    });

    testWidgets('Delete Latency', (tester) async {
      for (int i = 0; i < iterations + warmup; i++) {
        await db.insert('del-$i', randomVector(i));
      }

      int dc = 0;
      final stats = await benchmark('Delete', () async {
        await db.delete('del-${dc++}');
      });
      expect(stats.p99, lessThan(10000)); // < 10ms
    });

    testWidgets('Flush Latency', (tester) async {
      for (int i = 0; i < 50; i++) {
        await db.insert('fl-$i', randomVector(i));
      }

      final stats = await benchmark('Flush (N=50)', () async {
        await db.flush();
      }, runs: 50);
      expect(stats.p99, lessThan(100000)); // < 100ms
    });

    testWidgets('Cosine Similarity Latency', (tester) async {
      final a = List<double>.generate(dim, (i) => i * 0.01);
      final b = List<double>.generate(dim, (i) => (dim - i) * 0.01);

      final stats = await benchmark('Cosine Similarity (dim=$dim)', () async {
        await cosineSimilarity(a: a, b: b);
      }, runs: 500);
      expect(stats.p99, lessThan(5000)); // < 5ms
    });

    testWidgets('GetAllIds Latency', (tester) async {
      final records = List.generate(
        500,
        (i) => WaffleRecord(id: 'ids-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);

      final stats = await benchmark('GetAllIds (N=500)', () async {
        db.getAllIds();
      }, runs: 50);
      expect(stats.p99, lessThan(100000)); // < 100ms
    });

    testWidgets('Insert Throughput (10K Vectors)', (tester) async {
      // Pre-generate records to exclude generation time
      final records = List.generate(
        10000,
        (i) => WaffleRecord(id: 'thr-$i', vector: randomVector(i)),
      );

      final sw = Stopwatch()..start();
      await db.insertBatch(records);
      sw.stop();

      final opsPerSec = 10000 / (sw.elapsedMicroseconds / 1e6);
      print('Insert Throughput: ${opsPerSec.toStringAsFixed(0)} vectors/sec');
      expect(opsPerSec, greaterThan(100)); // Sanity check
    });

    testWidgets('Open with rebuild (1000 persisted vectors)', (tester) async {
      // Populate and close
      final records = List.generate(
        1000,
        (i) => WaffleRecord(id: 'rebuild-$i', vector: randomVector(i)),
      );
      await db.insertBatch(records);
      await db.close();

      // Benchmark reopening (includes HNSW rebuild)
      final stats = await benchmark(
        'Open+Rebuild (N=1000, dim=$dim)',
        () async {
          final config = WaffleConfig(
            dimension: dim,
            path: dbPath,
            graphConfig: const WaffleGraphConfig(
              m: 16,
              metric: WaffleMetric.cosine,
              efConstruction: 64,
              efSearch: 32,
            ),
            maxElements: 100000,
            useQuantization: false,
            cacheSizeBytes: BigInt.from(64 * 1024 * 1024),
            workerThreads: 4,
          );
          final reopened = await WaffleDatabase.open(config);
          await reopened.close();
        },
        warmupRuns: 1,
        runs: 5,
      );
      expect(stats.p99, lessThan(10000000)); // < 10s

      // Re-open for tearDown
      final config = WaffleConfig(
        dimension: dim,
        path: dbPath,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 100000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(64 * 1024 * 1024),
        workerThreads: 4,
      );
      db = await WaffleDatabase.open(config);
    });
  });
}
