import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

// ═══════════════════════════════════════════════════════════════════
//  Benchmark Statistics Engine
// ═══════════════════════════════════════════════════════════════════

class BenchStats {
  final String name;
  final List<double> _sorted; // microseconds
  final int count;

  BenchStats(this.name, List<double> raw)
    : _sorted = List<double>.from(raw)..sort(),
      count = raw.length;

  double get min => _sorted.first;
  double get max => _sorted.last;
  double get avg => _sorted.reduce((a, b) => a + b) / count;
  double get p50 => _pct(50);
  double get p90 => _pct(90);
  double get p95 => _pct(95);
  double get p99 => _pct(99);
  double get p999 => _pct(99.9);

  double get stdDev {
    final m = avg;
    final v =
        _sorted.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / count;
    return sqrt(v);
  }

  double get opsPerSec => count / (_sorted.reduce((a, b) => a + b) / 1e6);
  double get totalMs => _sorted.reduce((a, b) => a + b) / 1000;

  double _pct(double p) {
    final idx = ((p / 100) * (count - 1)).round().clamp(0, count - 1);
    return _sorted[idx];
  }

  String _fmt(double us) {
    if (us >= 1e6) return '${(us / 1e6).toStringAsFixed(3)}s';
    if (us >= 1e3) return '${(us / 1e3).toStringAsFixed(2)}ms';
    return '${us.toStringAsFixed(1)}µs';
  }

  void report() {
    final buf = StringBuffer();
    buf.writeln('┌─────────────────────────────────────────────────────');
    buf.writeln('│ 📊 $name');
    buf.writeln('│ Iterations: $count | Total: ${_fmt(totalMs * 1000)}');
    buf.writeln('├─────────────────────────────────────────────────────');
    buf.writeln('│  Min     ${_fmt(min).padLeft(12)}');
    buf.writeln('│  P50     ${_fmt(p50).padLeft(12)}');
    buf.writeln('│  P90     ${_fmt(p90).padLeft(12)}');
    buf.writeln('│  P95     ${_fmt(p95).padLeft(12)}');
    buf.writeln('│  P99     ${_fmt(p99).padLeft(12)}');
    buf.writeln('│  P99.9   ${_fmt(p999).padLeft(12)}');
    buf.writeln('│  Max     ${_fmt(max).padLeft(12)}');
    buf.writeln('│  Avg     ${_fmt(avg).padLeft(12)}');
    buf.writeln('│  StdDev  ${_fmt(stdDev).padLeft(12)}');
    buf.writeln('│  Ops/sec ${opsPerSec.toStringAsFixed(0).padLeft(12)}');
    buf.writeln('└─────────────────────────────────────────────────────');
    // ignore: avoid_print
    print(buf);
  }
}

BenchStats runBench(
  String name,
  void Function() fn, {
  int warmup = 50,
  int iterations = 1000,
}) {
  // Warmup
  for (int i = 0; i < warmup; i++) {
    fn();
  }

  final latencies = <double>[];
  for (int i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    fn();
    sw.stop();
    latencies.add(sw.elapsedMicroseconds.toDouble());
  }

  final stats = BenchStats(name, latencies);
  stats.report();
  return stats;
}

// ═══════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════

void main() {
  group('🔥 WaffleRecord Creation Benchmark', () {
    test('Float32List constructor — 128d', () {
      final stats = runBench('WaffleRecord(Float32List) dim=128', () {
        WaffleRecord(
          id: 'bench-id',
          vector: Float32List(128),
          metadata: Uint8List(64),
        );
      });
      expect(stats.opsPerSec, greaterThan(100000)); // > 100K ops/sec
    });

    test('Float32List constructor — 384d (embedding size)', () {
      final stats = runBench('WaffleRecord(Float32List) dim=384', () {
        WaffleRecord(
          id: 'bench-id-384',
          vector: Float32List(384),
          metadata: Uint8List(128),
        );
      });
      expect(stats.opsPerSec, greaterThan(50000));
    });

    test('Float32List constructor — 1536d (OpenAI size)', () {
      final stats = runBench('WaffleRecord(Float32List) dim=1536', () {
        WaffleRecord(
          id: 'bench-id-1536',
          vector: Float32List(1536),
          metadata: Uint8List(256),
        );
      });
      expect(stats.opsPerSec, greaterThan(10000));
    });

    test('fromList factory — 128d', () {
      final vec = List<double>.generate(128, (i) => i * 0.01);
      final stats = runBench('WaffleRecord.fromList() dim=128', () {
        WaffleRecord.fromList(
          id: 'fl-bench',
          vector: vec,
          metadata: Uint8List(32),
        );
      });
      expect(stats.opsPerSec, greaterThan(50000));
    });

    test('fromList factory — 1536d', () {
      final vec = List<double>.generate(1536, (i) => i * 0.001);
      final stats = runBench('WaffleRecord.fromList() dim=1536', () {
        WaffleRecord.fromList(id: 'fl-1536', vector: vec);
      });
      expect(stats.opsPerSec, greaterThan(5000));
    });
  });

  group('🔥 Vector Operations Benchmark', () {
    test('Float32List allocation — 128d', () {
      final stats = runBench('Float32List(128) allocation', () {
        Float32List(128);
      }, iterations: 10000);
      expect(stats.opsPerSec, greaterThan(500000));
    });

    test('Float32List allocation — 1536d', () {
      final stats = runBench('Float32List(1536) allocation', () {
        Float32List(1536);
      }, iterations: 10000);
      expect(stats.opsPerSec, greaterThan(100000));
    });

    test('Float32List.fromList conversion — 128d', () {
      final src = List<double>.generate(128, (i) => i * 0.01);
      final stats = runBench('Float32List.fromList() dim=128', () {
        Float32List.fromList(src);
      }, iterations: 10000);
      expect(stats.opsPerSec, greaterThan(100000));
    });

    test('Float32List.fromList conversion — 1536d', () {
      final src = List<double>.generate(1536, (i) => i * 0.001);
      final stats = runBench('Float32List.fromList() dim=1536', () {
        Float32List.fromList(src);
      }, iterations: 5000);
      expect(stats.opsPerSec, greaterThan(10000));
    });

    test('Dart-side cosine similarity — 128d', () {
      final a = Float32List.fromList(
        List<double>.generate(128, (i) => Random(i).nextDouble()),
      );
      final b = Float32List.fromList(
        List<double>.generate(128, (i) => Random(i + 1).nextDouble()),
      );

      final stats = runBench('Dart cosine similarity dim=128', () {
        _dartCosineSim(a, b);
      }, iterations: 10000);
      expect(stats.opsPerSec, greaterThan(500000));
    });

    test('Dart-side cosine similarity — 1536d', () {
      final a = Float32List.fromList(
        List<double>.generate(1536, (i) => Random(i).nextDouble()),
      );
      final b = Float32List.fromList(
        List<double>.generate(1536, (i) => Random(i + 1).nextDouble()),
      );

      final stats = runBench('Dart cosine similarity dim=1536', () {
        _dartCosineSim(a, b);
      }, iterations: 5000);
      expect(stats.opsPerSec, greaterThan(50000));
    });

    test('Vector flat-packing for batch insert — 100×128d', () {
      final vecs = List.generate(
        100,
        (i) => Float32List.fromList(
          List<double>.generate(128, (j) => (i + j) * 0.01),
        ),
      );

      final stats = runBench('Flatten 100×128d vectors', () {
        final flat = <double>[];
        for (final v in vecs) {
          flat.addAll(v);
        }
      }, iterations: 1000);
      expect(stats.opsPerSec, greaterThan(1000));
    });

    test('Vector flat-packing for batch insert — 1000×128d', () {
      final vecs = List.generate(
        1000,
        (i) => Float32List.fromList(
          List<double>.generate(128, (j) => (i + j) * 0.01),
        ),
      );

      final stats = runBench('Flatten 1000×128d vectors', () {
        final flat = <double>[];
        for (final v in vecs) {
          flat.addAll(v);
        }
      }, iterations: 100);
      expect(stats.opsPerSec, greaterThan(10));
    });
  });

  group('🔥 Batch Record Preparation Benchmark', () {
    test('prepare 100 WaffleRecords for batch insert', () {
      final stats = runBench('Build 100 WaffleRecords (dim=128)', () {
        List.generate(
          100,
          (i) => WaffleRecord(
            id: 'batch-$i',
            vector: Float32List(128),
            metadata: Uint8List.fromList(
              List.generate(64, (j) => (i + j) % 256),
            ),
          ),
        );
      }, iterations: 500);
      expect(stats.opsPerSec, greaterThan(100));
    });

    test('prepare 1000 WaffleRecords for batch insert', () {
      final stats = runBench('Build 1000 WaffleRecords (dim=128)', () {
        List.generate(
          1000,
          (i) => WaffleRecord(
            id: 'batch-$i',
            vector: Float32List(128),
            metadata: Uint8List(32),
          ),
        );
      }, iterations: 100);
      expect(stats.opsPerSec, greaterThan(10));
    });

    test('prepare 10000 WaffleRecords for batch insert', () {
      final stats = runBench('Build 10000 WaffleRecords (dim=128)', () {
        List.generate(
          10000,
          (i) => WaffleRecord(id: 'batch-$i', vector: Float32List(128)),
        );
      }, iterations: 20);
      expect(stats.opsPerSec, greaterThan(1));
    });
  });

  group('🔥 WaffleQueryResult Processing Benchmark', () {
    test('sort 100 results by distance', () {
      final rng = Random(42);
      final results = List.generate(
        100,
        (i) => WaffleQueryResult(
          id: 'r-$i',
          distance: rng.nextDouble(),
          metadata: null,
        ),
      );

      final stats = runBench('Sort 100 WaffleQueryResults', () {
        final copy = List<WaffleQueryResult>.from(results);
        copy.sort((a, b) => a.distance.compareTo(b.distance));
      }, iterations: 5000);
      expect(stats.opsPerSec, greaterThan(50000));
    });

    test('filter 1000 results by threshold', () {
      final rng = Random(42);
      final results = List.generate(
        1000,
        (i) => WaffleQueryResult(
          id: 'r-$i',
          distance: rng.nextDouble(),
          metadata: null,
        ),
      );

      final stats = runBench('Filter 1000 results (threshold=0.5)', () {
        results.where((r) => r.distance <= 0.5).toList();
      }, iterations: 5000);
      expect(stats.opsPerSec, greaterThan(50000));
    });

    test('strip metadata from 100 results', () {
      final results = List.generate(
        100,
        (i) => WaffleQueryResult(
          id: 'r-$i',
          distance: i * 0.01,
          metadata: Uint8List(64),
        ),
      );

      final stats = runBench('Strip metadata from 100 results', () {
        results
            .map(
              (r) => WaffleQueryResult(
                id: r.id,
                distance: r.distance,
                metadata: null,
              ),
            )
            .toList();
      }, iterations: 5000);
      expect(stats.opsPerSec, greaterThan(50000));
    });
  });

  group('🔥 WaffleConfig Creation Benchmark', () {
    test('WaffleConfig constructor', () {
      final stats = runBench('WaffleConfig constructor', () {
        WaffleConfig(
          dimension: 128,
          path: '/tmp/bench_db',
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
      });
      expect(stats.opsPerSec, greaterThan(100000));
    });
  });

  group('🔥 Collection ID Namespace Benchmark', () {
    test('prefix 10,000 IDs', () {
      final ids = List.generate(10000, (i) => 'item-$i');
      const prefix = 'my_collection';

      final stats = runBench('Prefix 10K IDs with namespace', () {
        for (final id in ids) {
          '$prefix::$id'; // string interpolation
        }
      }, iterations: 500);
      expect(stats.opsPerSec, greaterThan(100));
    });

    test('strip prefix from 10,000 IDs', () {
      final ids = List.generate(10000, (i) => 'my_collection::item-$i');
      const prefix = 'my_collection::';

      final stats = runBench('Strip prefix from 10K IDs', () {
        for (final id in ids) {
          if (id.startsWith(prefix)) {
            id.substring(prefix.length);
          }
        }
      }, iterations: 500);
      expect(stats.opsPerSec, greaterThan(100));
    });
  });
}

/// Pure Dart cosine similarity for benchmarking comparison against FFI.
double _dartCosineSim(Float32List a, Float32List b) {
  double dot = 0, normA = 0, normB = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (sqrt(normA) * sqrt(normB));
}
