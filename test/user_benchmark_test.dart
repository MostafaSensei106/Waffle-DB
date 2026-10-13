// ignore_for_file: avoid_print

@Timeout(Duration(minutes: 15))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:waffle_db/waffle_db.dart';

final _benchSchema = WaffleSchema(
  fields: [WaffleFields.string('tag', indexed: false)],
  textLanguage: WaffleLanguage.english,
);

void main() {
  test('User Benchmark - Run 10 times', () async {
    await WaffleDB.init();
    final latencies = <double>[];

    // We run the benchmark 10 times
    for (int iter = 0; iter < 10; iter++) {
      final sw = Stopwatch()..start();

      final dbDir = Directory('/tmp/waffle_user_bench_$iter.waffle');
      if (dbDir.existsSync()) {
        dbDir.deleteSync(recursive: true);
      }

      final config = WaffleConfig(
        dimension: 128,
        path: '/tmp/waffle_user_bench_$iter.waffle',
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 10000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(32 * 1024 * 1024),
        workerThreads: 4,
      );

      final db = await WaffleDatabase.open(config, schema: _benchSchema);

      // Batch insert 1000 items
      final records = List.generate(
        1000,
        (i) => WaffleRecord(
          id: 'item-$i',
          vector: Float32List.fromList(
            List.generate(128, (j) => Random().nextDouble()),
          ),
        ),
      );
      await db.insertBatch(records);

      // Query 10 times
      for (int i = 0; i < 10; i++) {
        await db.search(
          vector: Float32List.fromList(
            List.generate(128, (j) => Random().nextDouble()),
          ),
          topK: 10,
        );
      }

      await db.close();
      sw.stop();
      latencies.add(sw.elapsedMilliseconds.toDouble());
    }

    final sorted = List<double>.from(latencies)..sort();
    final min = sorted.first;
    final max = sorted.last;
    final avg = sorted.reduce((a, b) => a + b) / sorted.length;

    print('--- User Benchmark (10 iterations) ---');
    print('Min Latency: ${min.toStringAsFixed(2)} ms');
    print('Max Latency: ${max.toStringAsFixed(2)} ms');
    print('Avg Latency: ${avg.toStringAsFixed(2)} ms');
    print('--------------------------------------');
  });
}
