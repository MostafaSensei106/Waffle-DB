import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

WaffleConfig _config(String path, int dim, WaffleMetric metric) =>
    WaffleConfig(
      dimension: dim,
      path: path,
      graphConfig: WaffleGraphConfig(
        m: 12,
        metric: metric,
        efConstruction: 48,
        efSearch: 32,
      ),
      maxElements: 1000,
      useQuantization: false,
      cacheSizeBytes: BigInt.from(16 * 1024 * 1024),
      workerThreads: 2,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WaffleDB.init();
  });

  group('Recipes demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/life_recipes_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, 3, WaffleMetric.euclidean),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('diet'),
            WaffleFields.string('timeBand'),
            WaffleFields.string('cuisine'),
            WaffleFields.integer('calories'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        'vegan-pasta',
        Float32List.fromList([0.3, 0.25, 0.25]),
        text: 'Vegan pasta tomato garlic olive oil basil',
        payload: const {
          'diet': 'vegan',
          'timeBand': 'quick',
          'cuisine': 'italian',
          'calories': 350,
        },
      );
      await db.insert(
        'keto-curry',
        Float32List.fromList([0.5, 0.7, 0.5]),
        text: 'Keto curry coconut chicken spices',
        payload: const {
          'diet': 'keto',
          'timeBand': 'medium',
          'cuisine': 'asian',
          'calories': 600,
        },
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('ingredient keyword finds the pasta', (tester) async {
      final hits = db.search(text: 'garlic basil', topK: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.id, 'vegan-pasta');
    });

    testWidgets('diet pre-filter excludes everything else', (tester) async {
      final hits = db.search(
        vector: Float32List.fromList([0.3, 0.25, 0.25]),
        topK: 10,
        filter: WaffleEqFilter('diet', 'keto'),
      );
      expect(hits.length, 1);
      expect(hits.first.id, 'keto-curry');
    });

    testWidgets('integer payload round-trips', (tester) async {
      expect(db.getPayload('vegan-pasta')?['calories'], 350);
    });
  });

  group('Contacts demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/life_contacts_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, 3, WaffleMetric.euclidean),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('group'),
            WaffleFields.boolean('starred'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        'omar',
        Float32List.fromList([0.6, 0.5, 0.9]),
        text: 'Omar Farouk +20 100 111 2222 football match on saturday',
        payload: const {'group': 'friends', 'starred': false},
      );
      await db.insert(
        'mohamed',
        Float32List.fromList([0.5, 0.4, 0.8]),
        text: 'Mohamed Ali project deadline and code review',
        payload: const {'group': 'work', 'starred': true},
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('exact name match wins', (tester) async {
      final hits = db.search(text: 'Omar Farouk', topK: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.id, 'omar');
    });

    testWidgets('phone fragment matches', (tester) async {
      final hits = db.search(text: '2222', topK: 5);
      expect(hits.map((h) => h.id), contains('omar'));
    });

    testWidgets('starred pre-filter narrows to work contact',
        (tester) async {
      final hits = db.search(
        vector: Float32List.fromList([0.6, 0.5, 0.9]),
        topK: 10,
        filters: [
          WaffleEqFilter('starred', true),
          WaffleEqFilter('group', 'work'),
        ],
      );
      expect(hits.length, 1);
      expect(hits.first.id, 'mohamed');
    });
  });
}
