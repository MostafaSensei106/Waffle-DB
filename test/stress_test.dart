import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

class LatencyTracker {
  final List<int> _latenciesUs = [];

  void record(int microseconds) {
    _latenciesUs.add(microseconds);
  }

  void printReport(String name) {
    if (_latenciesUs.isEmpty) {
      print('--- $name ---');
      print('No data collected.');
      return;
    }

    _latenciesUs.sort();
    final count = _latenciesUs.length;
    final p50 = _latenciesUs[(count * 0.50).floor()];
    final p90 = _latenciesUs[(count * 0.90).floor()];
    final p95 = _latenciesUs[(count * 0.95).floor()];
    final p99 = _latenciesUs[(count * 0.99).floor()];
    final max = _latenciesUs.last;
    final min = _latenciesUs.first;
    final avg = _latenciesUs.reduce((a, b) => a + b) / count;

    print('\n=============================================');
    print('   STRESS TEST: $name');
    print('=============================================');
    print('Operations : $count');
    print('Min        : ${(min / 1000.0).toStringAsFixed(3)} ms');
    print('p50 (Avg)  : ${(p50 / 1000.0).toStringAsFixed(3)} ms');
    print('p90        : ${(p90 / 1000.0).toStringAsFixed(3)} ms');
    print('p95        : ${(p95 / 1000.0).toStringAsFixed(3)} ms');
    print('p99        : ${(p99 / 1000.0).toStringAsFixed(3)} ms');
    print('Max        : ${(max / 1000.0).toStringAsFixed(3)} ms');
    print('Mean (Avg) : ${(avg / 1000.0).toStringAsFixed(3)} ms');
    print('=============================================\n');
  }
}

void main() {
  group('WaffleDB Stress Testing (Percentiles)', () {
    final path = '/tmp/waffle_db_stress_test';
    late WaffleDatabase db;
    final random = Random(42);
    final dimension = 128;

    setUpAll(() async {
      await WaffleDB.init();
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);

      final config = await WaffleConfig.highVolumeProfile(
        path: path,
        dimension: dimension,
      );
      db = await WaffleDatabase.open(config);
    });

    tearDownAll(() async {
      await db.close();
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('Stress Test Insertions (Batch vs Single)', () async {
      final trackerSingle = LatencyTracker();
      final trackerBatch = LatencyTracker();
      final stopwatch = Stopwatch();

      // 1. Single Insertions Stress Test
      for (int i = 0; i < 5000; i++) {
        final vec = Float32List.fromList(
          List.generate(dimension, (_) => random.nextDouble()),
        );

        stopwatch.start();
        await db.insert('single-$i', vec);
        stopwatch.stop();

        trackerSingle.record(stopwatch.elapsedMicroseconds);
        stopwatch.reset();
      }
      trackerSingle.printReport('5000 Single Insertions');

      // 2. Batch Insertions Stress Test
      for (int b = 0; b < 20; b++) {
        final records = List.generate(1000, (i) {
          return WaffleRecord(
            id: 'batch-$b-$i',
            vector: Float32List.fromList(
              List.generate(dimension, (_) => random.nextDouble()),
            ),
          );
        });

        stopwatch.start();
        await db.insertBatch(records);
        stopwatch.stop();

        trackerBatch.record(stopwatch.elapsedMicroseconds);
        stopwatch.reset();
      }
      trackerBatch.printReport('20 Batches (1000 vectors/batch)');
    });

    test('Stress Test Queries under Load (Percentiles)', () async {
      final tracker = LatencyTracker();
      final stopwatch = Stopwatch();

      // Perform 5,000 queries
      for (int i = 0; i < 5000; i++) {
        final vec = Float32List.fromList(
          List.generate(dimension, (_) => random.nextDouble()),
        );

        stopwatch.start();
        final results = db.query(vec, k: 10, efSearch: 32);
        stopwatch.stop();

        // Ensure we actually got results to prevent the compiler from optimizing out the call
        expect(results, isNotNull);

        tracker.record(stopwatch.elapsedMicroseconds);
        stopwatch.reset();
      }

      tracker.printReport('5000 KNN Queries (k=10, 128-dim)');
    });
  });
}
