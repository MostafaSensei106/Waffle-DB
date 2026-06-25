// ignore_for_file: prefer_interpolation_to_compose_strings, avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const int dim = 1536; // OpenAI dim
  const int warmup = 3;
  const int iterations = 10; // keep it low for faster full suite run

  Float32List randomVector(int seed) {
    final rng = Random(seed);
    final v = Float32List(dim);
    for (int i = 0; i < dim; i++) {
      v[i] = rng.nextDouble();
    }
    return v;
  }

  Future<double> benchmarkAverageUs(
    Future<void> Function() fn, {
    int runs = iterations,
  }) async {
    for (int i = 0; i < warmup; i++) {
      await fn();
    }
    double total = 0;
    for (int i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await fn();
      sw.stop();
      total += sw.elapsedMicroseconds;
    }
    return total / runs;
  }

  setUpAll(() async {
    await RustLib.init();
  });

  Future<void> runProfile(
    String name,
    Future<WaffleConfig> Function(String) configBuilder,
  ) async {
    final dbPath = '${Directory.systemTemp.path}/waffle_bench_dart_$name';
    final dir = Directory(dbPath);
    if (await dir.exists()) await dir.delete(recursive: true);

    final config = await configBuilder(dbPath);
    final db = await WaffleDatabase.open(config);

    // Bench Insert
    int counter = 0;
    final insertVectors = List.generate(
      iterations + warmup,
      (i) => randomVector(i),
    );
    final insertAvgUs = await benchmarkAverageUs(() async {
      final idx = counter++;
      await db.insert('bench-insert-$idx', insertVectors[idx]);
    });

    // Populate for Query
    final records = List.generate(
      1000,
      (i) => WaffleRecord(id: 'q-$i', vector: randomVector(i)),
    );
    await db.insertBatch(records);

    // Bench Query
    int qc = 0;
    final queryVectors = List.generate(
      iterations + warmup,
      (i) => randomVector(i + 2000),
    );
    final queryAvgUs = await benchmarkAverageUs(() async {
      final idx = qc++;
      db.query(queryVectors[idx], k: 10);
    });

    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);

    print(
      'BENCHMARK_RESULT_JSON:' +
          jsonEncode({
            'profile': name,
            'insert_us': insertAvgUs,
            'query_us': queryAvgUs,
          }),
    );
  }

  testWidgets('Run All Profiles Benchmark', (tester) async {
    await runProfile(
      'Mobile',
      (p) => WaffleConfig.mobileProfile(path: p, dimension: dim),
    );
    await runProfile(
      'Server',
      (p) => WaffleConfig.serverProfile(path: p, dimension: dim),
    );
    await runProfile(
      'ReadHeavy',
      (p) => WaffleConfig.readHeavyProfile(path: p, dimension: dim),
    );
    await runProfile(
      'WriteHeavy',
      (p) => WaffleConfig.writeHeavyProfile(path: p, dimension: dim),
    );
  });
}
