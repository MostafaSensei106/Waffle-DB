import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

Float32List _profile(double price, double rating, double weight) =>
    Float32List.fromList([price / 2500.0, rating / 5.0, weight / 2200.0]);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WaffleDB.init();
  });

  group('Product hybrid demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/rag_demo_products_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        WaffleConfig(
          dimension: 3,
          path: path,
          graphConfig: const WaffleGraphConfig(
            m: 12,
            metric: WaffleMetric.euclidean,
            efConstruction: 48,
            efSearch: 32,
          ),
          maxElements: 1000,
          useQuantization: false,
          cacheSizeBytes: BigInt.from(16 * 1024 * 1024),
          workerThreads: 2,
        ),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('category'),
            WaffleFields.string('band'),
            WaffleFields.boolean('inStock'),
            WaffleFields.integer('price'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        'phone-a',
        _profile(900, 4.5, 180),
        text: 'Nova Phone with 5G and dual camera',
        payload: const {
          'category': 'phones',
          'band': 'mid',
          'inStock': true,
          'price': 900,
          'name': 'Nova Phone',
        },
      );
      await db.insert(
        'phone-b',
        _profile(250, 4.0, 170),
        text: 'Pulse Phone with long battery life',
        payload: const {
          'category': 'phones',
          'band': 'budget',
          'inStock': true,
          'price': 250,
          'name': 'Pulse Phone',
        },
      );
      await db.insert(
        'laptop-a',
        _profile(1800, 4.8, 1500),
        text: 'Aero laptop with 16GB memory for work',
        payload: const {
          'category': 'laptops',
          'band': 'premium',
          'inStock': false,
          'price': 1800,
          'name': 'Aero Book',
        },
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('keyword search finds the 5G phone', (tester) async {
      final hits = db.search(text: '5G camera', topK: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.id, 'phone-a');
    });

    testWidgets('pre-filtering beats post-filtering', (tester) async {
      final hits = db.search(
        vector: _profile(900, 4.5, 180),
        topK: 10,
        filter: WaffleEqFilter('category', 'laptops'),
      );
      expect(hits.length, 1);
      expect(hits.first.id, 'laptop-a');
    });

    testWidgets('hybrid fuses keyword and profile', (tester) async {
      final hits = await WaffleQueryBuilder(db)
          .withHybrid(vector: _profile(900, 4.5, 180), text: 'battery')
          .eq('inStock', true)
          .limit(5)
          .execute();
      expect(hits.map((h) => h.id), containsAll(['phone-a', 'phone-b']));
      expect(hits.map((h) => h.id), isNot(contains('laptop-a')));
    });
  });

  group('Arabic notes RAG demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/rag_demo_notes_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        WaffleConfig(
          dimension: 8,
          path: path,
          graphConfig: const WaffleGraphConfig(
            m: 12,
            metric: WaffleMetric.cosine,
            efConstruction: 48,
            efSearch: 32,
          ),
          maxElements: 1000,
          useQuantization: false,
          cacheSizeBytes: BigInt.from(16 * 1024 * 1024),
          workerThreads: 2,
        ),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('docType'),
            WaffleFields.string('lang'),
          ],
          textLanguage: WaffleLanguage.arabic,
        ),
      );
      await db.insert(
        'policy',
        Float32List(8),
        text: 'سياسة الاسترجاع والضمان',
        payload: const {'docType': 'policy', 'lang': 'ar'},
      );
      await db.insert(
        'policy-c0',
        Float32List(8),
        text: 'يمكنك استرجاع أي منتج خلال أربعة عشر يوما من تاريخ الشراء.',
        payload: const {'docType': 'policy', 'lang': 'ar'},
        parentId: 'policy',
        chunkIndex: 0,
      );
      await db.insert(
        'policy-c1',
        Float32List(8),
        text: 'لطلب الاسترجاع تواصل مع خدمة العملاء مع رقم الفاتورة.',
        payload: const {'docType': 'policy', 'lang': 'ar'},
        parentId: 'policy',
        chunkIndex: 1,
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('arabic keyword search hits both chunks', (tester) async {
      final hits = db.search(text: 'استرجاع المنتج', topK: 5);
      expect(hits.map((h) => h.id),
          containsAll(['policy-c0', 'policy-c1']));
    });

    testWidgets('window context and parent resolve', (tester) async {
      final window = db.getNeighbors('policy-c0', window: 1);
      expect(window.map((h) => h.id),
          containsAll(['policy-c0', 'policy-c1']));
      expect(db.getParent('policy-c1')?.id, 'policy');
    });

    testWidgets('delete removes the chunk from every engine',
        (tester) async {
      expect(await db.delete('policy-c0'), isTrue);
      final hits = db.search(text: 'أربعة عشر يوما', topK: 5);
      expect(hits.map((h) => h.id), isNot(contains('policy-c0')));
      expect(db.getNeighbors('policy-c1', window: 1).map((h) => h.id),
          isNot(contains('policy-c0')));
    });
  });
}
