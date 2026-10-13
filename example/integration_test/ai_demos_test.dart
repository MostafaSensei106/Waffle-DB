import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:waffle_db/waffle_db.dart';

import 'package:waffle_db_example/demos/demo_embed.dart';

WaffleConfig _config(String path, int dim, WaffleMetric metric) => WaffleConfig(
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

Float32List _v(String text) => DemoEmbedder.embed(text);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WaffleDB.init();
  });

  group('Docs RAG demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/ai_docs_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, DemoEmbedder.dim, WaffleMetric.cosine),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('section'),
            WaffleFields.string('version'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        'filtering',
        _v('Metadata pre-filtering'),
        text: 'WaffleDB filters during vector search, not after it.',
        payload: const {'section': 'search', 'version': 'v2'},
      );
      await db.insert(
        'filtering-c0',
        _v('Post-filtering fetches top-k and discards misses'),
        text:
            'Post-filtering fetches the top-k vectors and discards the ones that miss the filter.',
        payload: const {'section': 'search', 'version': 'v2'},
        parentId: 'filtering',
        chunkIndex: 0,
      );
      await db.insert(
        'schema-v1',
        _v('legacy schemaless metadata'),
        text: 'Version one required schemaless metadata blobs.',
        payload: const {'section': 'api', 'version': 'v1'},
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('hybrid finds the filtering guide', (tester) async {
      final hits = db.search(
        vector: _v('how does filtering work'),
        text: 'how does filtering work',
        topK: 5,
        alpha: 0.5,
      );
      expect(hits, isNotEmpty);
      expect(hits.map((h) => h.id), containsAll(['filtering', 'filtering-c0']));
    });

    testWidgets('section pre-filter hides other sections', (tester) async {
      final hits = db.search(
        vector: _v('metadata'),
        text: 'metadata',
        topK: 10,
        filter: WaffleEqFilter('section', 'api'),
      );
      expect(hits.length, 1);
      expect(hits.first.id, 'schema-v1');
    });

    testWidgets('chunk window cites siblings', (tester) async {
      final window = db.getNeighbors('filtering-c0', window: 1);
      expect(window.map((h) => h.id), contains('filtering-c0'));
      expect(db.getParent('filtering-c0')?.id, 'filtering');
    });
  });

  group('Code search demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/ai_code_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, DemoEmbedder.dim, WaffleMetric.cosine),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('language'),
            WaffleFields.string('kind'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        'bitmap-add',
        _v('Store bitmap_add inserts internal id'),
        text:
            'Store::bitmap_add loads the roaring bitmap for a field value and inserts the internal id.',
        payload: const {'language': 'rust', 'kind': 'function'},
      );
      await db.insert(
        'builder-eq',
        _v('WaffleQueryBuilder eq stacks equality filter'),
        text:
            'WaffleQueryBuilder.eq stacks an equality pre-filter evaluated as a bitmap predicate.',
        payload: const {'language': 'dart', 'kind': 'method'},
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('exact symbol name wins over fuzzy meaning', (tester) async {
      final hits = db.search(text: 'bitmap_add', topK: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.id, 'bitmap-add');
    });

    testWidgets('language pre-filter scopes results', (tester) async {
      final hits = db.search(
        vector: _v('filter'),
        text: 'filter',
        topK: 10,
        filter: WaffleEqFilter('language', 'dart'),
      );
      expect(hits.length, 1);
      expect(hits.first.id, 'builder-eq');
    });
  });

  group('Support demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/ai_support_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, DemoEmbedder.dim, WaffleMetric.cosine),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('kind'),
            WaffleFields.string('priority'),
            WaffleFields.string('status'),
          ],
          textLanguage: WaffleLanguage.english,
        ),
      );
      await db.insert(
        't-1',
        _v('customer wants to return headphones'),
        text: 'Customer wants to return headphones bought twelve days ago.',
        payload: const {'kind': 'ticket', 'priority': 'high', 'status': 'open'},
      );
      await db.insert(
        't-2',
        _v('late delivery compensation'),
        text: 'Order delayed by a week, customer asks for compensation.',
        payload: const {'kind': 'ticket', 'priority': 'high', 'status': 'open'},
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('upsert resolves a ticket', (tester) async {
      expect(
        await db.upsert(
          't-1',
          _v('customer wants to return headphones'),
          text: 'Customer wants to return headphones bought twelve days ago.',
          payload: const {
            'kind': 'ticket',
            'priority': 'high',
            'status': 'resolved',
          },
        ),
        isTrue,
      );
      final open = db.search(
        vector: _v('return'),
        text: 'return',
        topK: 10,
        filter: WaffleEqFilter('status', 'open'),
      );
      expect(open.map((h) => h.id), isNot(contains('t-1')));
      final openSparseOnly = db.search(
        text: 'return',
        topK: 10,
        filter: WaffleEqFilter('status', 'open'),
      );
      expect(openSparseOnly.map((h) => h.id), isNot(contains('t-1')));
    });

    testWidgets('deleteWhere sweeps resolved tickets', (tester) async {
      await db.upsert(
        't-1',
        _v('customer wants to return headphones'),
        text: 'Customer wants to return headphones.',
        payload: const {
          'kind': 'ticket',
          'priority': 'high',
          'status': 'resolved',
        },
      );
      expect(await db.deleteWhere(WaffleEqFilter('status', 'resolved')), 1);
      expect(db.count(), 1);
    });
  });

  group('Glossary demo', () {
    late WaffleDatabase db;
    late String path;

    setUp(() async {
      path =
          '${Directory.systemTemp.path}/ai_gloss_${DateTime.now().microsecondsSinceEpoch}';
      db = await WaffleDatabase.open(
        _config(path, DemoEmbedder.dim, WaffleMetric.cosine),
        schema: WaffleSchema(
          fields: [
            WaffleFields.string('domain'),
            WaffleFields.string('direction'),
          ],
          textLanguage: WaffleLanguage.arabic,
        ),
      );
      await db.insert(
        't-rrf',
        _v('reciprocal rank fusion merges ranked lists'),
        text: 'reciprocal rank fusion = دمج الرتب المتبادلة',
        payload: const {'domain': 'search', 'direction': 'en-ar'},
      );
      await db.insert(
        't-chunk',
        _v('a chunk is a slice of a parent document'),
        text: 'chunk = مقطع',
        payload: const {'domain': 'rag', 'direction': 'term'},
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('arabic query finds the term', (tester) async {
      final hits = db.search(text: 'دمج الرتب', topK: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.id, 't-rrf');
    });

    testWidgets('domain pre-filter scopes lookup', (tester) async {
      final hits = db.search(
        vector: _v('chunk'),
        text: 'chunk',
        topK: 10,
        filter: WaffleEqFilter('domain', 'rag'),
      );
      expect(hits.length, 1);
      expect(hits.first.id, 't-chunk');
    });
  });

  group('DemoEmbedder', () {
    test('embeddings are deterministic and normalized', () {
      final a = DemoEmbedder.embed('hello world');
      final b = DemoEmbedder.embed('hello world');
      expect(a.length, DemoEmbedder.dim);
      var norm = 0.0;
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i]);
        norm += a[i] * a[i];
      }
      expect(norm, closeTo(1.0, 0.001));
    });
  });
}
