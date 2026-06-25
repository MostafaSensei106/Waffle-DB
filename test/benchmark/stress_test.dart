import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

// ═══════════════════════════════════════════════════════════════════
//  Stress Test Utilities
// ═══════════════════════════════════════════════════════════════════

class StressResult {
  final String name;
  final int totalOps;
  final Duration elapsed;
  final int errorCount;
  final double peakMemoryMB;
  final Map<String, dynamic> extras;

  StressResult({
    required this.name,
    required this.totalOps,
    required this.elapsed,
    this.errorCount = 0,
    this.peakMemoryMB = 0,
    this.extras = const {},
  });

  double get opsPerSec => totalOps / (elapsed.inMicroseconds / 1e6);
  double get avgLatencyUs => elapsed.inMicroseconds / totalOps;

  void report() {
    final buf = StringBuffer();
    buf.writeln('╔═══════════════════════════════════════════════════════');
    buf.writeln('║ 🏋️ STRESS: $name');
    buf.writeln('╠═══════════════════════════════════════════════════════');
    buf.writeln('║  Total Ops    : $totalOps');
    buf.writeln('║  Elapsed      : ${elapsed.inMilliseconds}ms');
    buf.writeln('║  Throughput   : ${opsPerSec.toStringAsFixed(0)} ops/sec');
    buf.writeln('║  Avg Latency  : ${avgLatencyUs.toStringAsFixed(1)}µs/op');
    buf.writeln('║  Errors       : $errorCount');
    if (peakMemoryMB > 0) {
      buf.writeln('║  Peak Memory  : ${peakMemoryMB.toStringAsFixed(1)} MB');
    }
    for (final e in extras.entries) {
      buf.writeln('║  ${e.key.padRight(13)}: ${e.value}');
    }
    buf.writeln('╚═══════════════════════════════════════════════════════');
    // ignore: avoid_print
    print(buf);
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════

void main() {
  // ─────────────────────────────────────────────────────────────
  //  Memory Stress — Large allocations
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Memory Stress', () {
    test('allocate 10,000 WaffleRecords (128d) simultaneously', () {
      final sw = Stopwatch()..start();
      final records = <WaffleRecord>[];

      for (int i = 0; i < 10000; i++) {
        records.add(
          WaffleRecord(
            id: 'stress-$i',
            vector: Float32List(128),
            metadata: Uint8List.fromList(List.generate(64, (j) => j % 256)),
          ),
        );
      }
      sw.stop();

      final result = StressResult(
        name: 'Allocate 10K WaffleRecords (128d)',
        totalOps: 10000,
        elapsed: sw.elapsed,
        extras: {
          'Record size': '128d + 64B meta',
          'Total vectors': records.length,
        },
      );
      result.report();

      expect(records.length, 10000);
      expect(sw.elapsed.inSeconds, lessThan(5));
    });

    test('allocate 1,000 WaffleRecords (1536d — OpenAI embed size)', () {
      final sw = Stopwatch()..start();
      final records = <WaffleRecord>[];

      for (int i = 0; i < 1000; i++) {
        records.add(
          WaffleRecord(
            id: 'openai-$i',
            vector: Float32List(1536),
            metadata: Uint8List(256),
          ),
        );
      }
      sw.stop();

      final result = StressResult(
        name: 'Allocate 1K WaffleRecords (1536d)',
        totalOps: 1000,
        elapsed: sw.elapsed,
        extras: {
          'Vector bytes': '${1536 * 4} bytes/vec',
          'Total MB': (1000 * 1536 * 4 / 1024 / 1024).toStringAsFixed(1),
        },
      );
      result.report();

      expect(records.length, 1000);
      expect(sw.elapsed.inSeconds, lessThan(5));
    });

    test('allocate 100 WaffleRecords (4096d — large model embed)', () {
      final sw = Stopwatch()..start();
      final records = <WaffleRecord>[];

      for (int i = 0; i < 100; i++) {
        records.add(
          WaffleRecord(
            id: 'large-$i',
            vector: Float32List(4096),
            metadata: Uint8List(512),
          ),
        );
      }
      sw.stop();

      final result = StressResult(
        name: 'Allocate 100 WaffleRecords (4096d)',
        totalOps: 100,
        elapsed: sw.elapsed,
        extras: {
          'Vector bytes': '${4096 * 4} bytes/vec',
          'Total MB': (100 * 4096 * 4 / 1024 / 1024).toStringAsFixed(1),
        },
      );
      result.report();

      expect(records.length, 100);
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Batch Preparation Stress
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Batch Preparation Stress', () {
    test('flatten 10,000 × 128d vectors into single list', () {
      final vecs = List.generate(
        10000,
        (i) => Float32List.fromList(
          List<double>.generate(128, (j) => Random(i + j).nextDouble()),
        ),
      );

      final sw = Stopwatch()..start();
      final flat = <double>[];
      for (final v in vecs) {
        flat.addAll(v);
      }
      sw.stop();

      final result = StressResult(
        name: 'Flatten 10K×128d vectors',
        totalOps: 10000,
        elapsed: sw.elapsed,
        extras: {
          'Flat length': flat.length,
          'Expected': 10000 * 128,
          'Total MB': (flat.length * 8 / 1024 / 1024).toStringAsFixed(1),
        },
      );
      result.report();

      expect(flat.length, 10000 * 128);
      expect(sw.elapsed.inSeconds, lessThan(10));
    });

    test('build 5,000 metadata Uint8Lists (256 bytes each)', () {
      final sw = Stopwatch()..start();
      final metas = <Uint8List>[];
      for (int i = 0; i < 5000; i++) {
        metas.add(
          Uint8List.fromList(
            List.generate(256, (j) => (i * 17 + j * 31) % 256),
          ),
        );
      }
      sw.stop();

      final result = StressResult(
        name: 'Build 5K metadata buffers (256B)',
        totalOps: 5000,
        elapsed: sw.elapsed,
        extras: {'Total MB': (5000 * 256 / 1024 / 1024).toStringAsFixed(1)},
      );
      result.report();

      expect(metas.length, 5000);
    });

    test('generate 50,000 unique string IDs', () {
      final sw = Stopwatch()..start();
      final ids = <String>[];
      for (int i = 0; i < 50000; i++) {
        ids.add('doc_${i}_${i.hashCode.toRadixString(16)}');
      }
      sw.stop();

      final result = StressResult(
        name: 'Generate 50K unique IDs',
        totalOps: 50000,
        elapsed: sw.elapsed,
      );
      result.report();

      expect(ids.toSet().length, 50000); // all unique
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Cosine Similarity Stress (Pure Dart)
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Cosine Similarity Stress (Pure Dart)', () {
    test('100,000 cosine similarity computations — 128d', () {
      final a = Float32List.fromList(
        List<double>.generate(128, (i) => Random(42).nextDouble()),
      );
      final b = Float32List.fromList(
        List<double>.generate(128, (i) => Random(43).nextDouble()),
      );

      final sw = Stopwatch()..start();
      double lastSim = 0;
      for (int i = 0; i < 100000; i++) {
        lastSim = _dartCosineSim(a, b);
      }
      sw.stop();

      final result = StressResult(
        name: '100K cosine sim (128d)',
        totalOps: 100000,
        elapsed: sw.elapsed,
        extras: {'Last sim': lastSim.toStringAsFixed(6)},
      );
      result.report();

      expect(lastSim, greaterThan(-1.0));
      expect(lastSim, lessThanOrEqualTo(1.0));
      expect(sw.elapsed.inSeconds, lessThan(5));
    });

    test('10,000 cosine similarity computations — 1536d', () {
      final a = Float32List.fromList(
        List<double>.generate(1536, (i) => Random(42).nextDouble()),
      );
      final b = Float32List.fromList(
        List<double>.generate(1536, (i) => Random(43).nextDouble()),
      );

      final sw = Stopwatch()..start();
      double lastSim = 0;
      for (int i = 0; i < 10000; i++) {
        lastSim = _dartCosineSim(a, b);
      }
      sw.stop();

      final result = StressResult(
        name: '10K cosine sim (1536d)',
        totalOps: 10000,
        elapsed: sw.elapsed,
        extras: {'Last sim': lastSim.toStringAsFixed(6)},
      );
      result.report();

      expect(sw.elapsed.inSeconds, lessThan(10));
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Query Result Processing Stress
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Query Result Processing Stress', () {
    test('sort 10,000 query results', () {
      final rng = Random(42);
      final results = List.generate(
        10000,
        (i) => WaffleQueryResult(
          id: 'r-$i',
          distance: rng.nextDouble(),
          metadata: Uint8List(32),
        ),
      );

      final sw = Stopwatch()..start();
      for (int iter = 0; iter < 100; iter++) {
        final copy = List<WaffleQueryResult>.from(results);
        copy.sort((a, b) => a.distance.compareTo(b.distance));
      }
      sw.stop();

      final result = StressResult(
        name: 'Sort 10K results × 100 iterations',
        totalOps: 100,
        elapsed: sw.elapsed,
        extras: {
          'Results/sort': 10000,
          'Avg/sort':
              '${(sw.elapsed.inMicroseconds / 100).toStringAsFixed(0)}µs',
        },
      );
      result.report();

      expect(sw.elapsed.inSeconds, lessThan(10));
    });

    test('filter + threshold 10,000 results × 1000 times', () {
      final rng = Random(42);
      final results = List.generate(
        10000,
        (i) => WaffleQueryResult(
          id: 'r-$i',
          distance: rng.nextDouble(),
          metadata: null,
        ),
      );

      final sw = Stopwatch()..start();
      int totalPassed = 0;
      for (int iter = 0; iter < 1000; iter++) {
        totalPassed += results.where((r) => r.distance <= 0.3).toList().length;
      }
      sw.stop();

      final result = StressResult(
        name: 'Filter 10K results (threshold=0.3) × 1000',
        totalOps: 1000,
        elapsed: sw.elapsed,
        extras: {'Avg passed': (totalPassed / 1000).toStringAsFixed(0)},
      );
      result.report();

      expect(sw.elapsed.inSeconds, lessThan(10));
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Collection Namespace Stress
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Collection Namespace Stress', () {
    test('namespace 100,000 IDs with prefix + filter', () {
      const prefix = 'my_very_long_collection_name_for_stress_testing';
      final ids = List.generate(100000, (i) => '$prefix::item-$i');

      final sw = Stopwatch()..start();
      int matchCount = 0;
      for (final id in ids) {
        if (id.startsWith('$prefix::')) {
          final stripped = id.substring('$prefix::'.length);
          if (stripped.isNotEmpty) matchCount++;
        }
      }
      sw.stop();

      final result = StressResult(
        name: 'Namespace filter 100K IDs',
        totalOps: 100000,
        elapsed: sw.elapsed,
        extras: {'Matched': matchCount},
      );
      result.report();

      expect(matchCount, 100000);
      expect(sw.elapsed.inSeconds, lessThan(5));
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Sustained Load Simulation (Pure Dart)
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Sustained Load Simulation', () {
    test('mixed workload: create + process + filter 10K cycles', () {
      final rng = Random(42);

      final sw = Stopwatch()..start();
      int totalCreated = 0;
      int totalFiltered = 0;

      for (int cycle = 0; cycle < 10000; cycle++) {
        // Create a record
        final record = WaffleRecord(
          id: 'sustained-$cycle',
          vector: Float32List.fromList(
            List<double>.generate(128, (i) => rng.nextDouble()),
          ),
          metadata: Uint8List(32),
        );
        totalCreated++;

        // Simulate processing result
        final fakeResult = WaffleQueryResult(
          id: record.id,
          distance: rng.nextDouble(),
          metadata: record.metadata,
        );

        // Filter by threshold
        if (fakeResult.distance <= 0.5) {
          totalFiltered++;
        }
      }
      sw.stop();

      final result = StressResult(
        name: 'Mixed workload (create+process+filter) × 10K',
        totalOps: 10000,
        elapsed: sw.elapsed,
        extras: {
          'Created': totalCreated,
          'Passed filter': totalFiltered,
          'Filter rate':
              '${(totalFiltered / totalCreated * 100).toStringAsFixed(1)}%',
        },
      );
      result.report();

      expect(totalCreated, 10000);
      expect(sw.elapsed.inSeconds, lessThan(10));
    });

    test('rapid ID generation + dedup check — 100K', () {
      final sw = Stopwatch()..start();
      final seen = <String>{};
      int dupes = 0;

      for (int i = 0; i < 100000; i++) {
        final id = 'gen_${i}_${DateTime.now().microsecondsSinceEpoch}';
        if (!seen.add(id)) dupes++;
      }
      sw.stop();

      final result = StressResult(
        name: 'ID generation + dedup 100K',
        totalOps: 100000,
        elapsed: sw.elapsed,
        extras: {'Unique': seen.length, 'Duplicates': dupes},
      );
      result.report();

      expect(dupes, 0);
      expect(sw.elapsed.inSeconds, lessThan(10));
    });
  });

  // ─────────────────────────────────────────────────────────────
  //  Edge Case Stress
  // ─────────────────────────────────────────────────────────────

  group('🏋️ Edge Case Stress', () {
    test('zero-length vectors — 100K allocations', () {
      final sw = Stopwatch()..start();
      for (int i = 0; i < 100000; i++) {
        WaffleRecord(id: 'zero-$i', vector: Float32List(0));
      }
      sw.stop();

      final result = StressResult(
        name: 'Zero-dim WaffleRecord × 100K',
        totalOps: 100000,
        elapsed: sw.elapsed,
      );
      result.report();

      expect(sw.elapsed.inSeconds, lessThan(5));
    });

    test('very long IDs — 10K records with 500-char IDs', () {
      final sw = Stopwatch()..start();
      final records = <WaffleRecord>[];
      for (int i = 0; i < 10000; i++) {
        final longId = 'prefix_${i}_${'x' * 480}_suffix';
        records.add(WaffleRecord(id: longId, vector: Float32List(64)));
      }
      sw.stop();

      final result = StressResult(
        name: '10K records with 500-char IDs',
        totalOps: 10000,
        elapsed: sw.elapsed,
        extras: {'Avg ID len': records.first.id.length},
      );
      result.report();

      expect(records.length, 10000);
    });

    test('large metadata — 1K records with 10KB metadata each', () {
      final sw = Stopwatch()..start();
      final records = <WaffleRecord>[];
      for (int i = 0; i < 1000; i++) {
        records.add(
          WaffleRecord(
            id: 'bigmeta-$i',
            vector: Float32List(128),
            metadata: Uint8List(10240), // 10KB
          ),
        );
      }
      sw.stop();

      final result = StressResult(
        name: '1K records with 10KB metadata',
        totalOps: 1000,
        elapsed: sw.elapsed,
        extras: {
          'Total meta MB': (1000 * 10240 / 1024 / 1024).toStringAsFixed(1),
        },
      );
      result.report();

      expect(records.length, 1000);
    });
  });
}

/// Pure Dart cosine similarity.
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
