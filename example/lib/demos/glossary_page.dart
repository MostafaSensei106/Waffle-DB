import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';
import 'demo_embed.dart';

final _glossarySchema = WaffleSchema(
  fields: [WaffleFields.string('domain'), WaffleFields.string('direction')],
  textLanguage: WaffleLanguage.arabic,
);

class _Term {
  final String id;
  final String source;
  final String target;
  final String domain;

  const _Term({
    required this.id,
    required this.source,
    required this.target,
    required this.domain,
  });
}

const _seedTerms = [
  _Term(
    id: 't-filter',
    source: 'pre-filtering',
    target: 'الفلترة المسبقة',
    domain: 'search',
  ),
  _Term(
    id: 't-filter-defined',
    source: 'pre-filtering narrows candidates before ranking',
    target: 'الفلترة المسبقة تضيق المرشحين قبل الترتيب',
    domain: 'search',
  ),
  _Term(
    id: 't-rrf',
    source: 'reciprocal rank fusion',
    target: 'دمج الرتب المتبادلة',
    domain: 'search',
  ),
  _Term(
    id: 't-rrf-defined',
    source:
        'reciprocal rank fusion merges ranked lists without score normalization',
    target: 'دمج الرتب المتبادلة يدمج القوائم المرتبة دون توحيد الدرجات',
    domain: 'search',
  ),
  _Term(
    id: 't-embed',
    source: 'embedding',
    target: 'التضمين المتجهي',
    domain: 'ml',
  ),
  _Term(
    id: 't-embed-defined',
    source: 'an embedding maps text to a dense vector',
    target: 'التضمين المتجهي يحول النص إلى متجه كثيف',
    domain: 'ml',
  ),
  _Term(id: 't-chunk', source: 'chunk', target: 'مقطع', domain: 'rag'),
  _Term(
    id: 't-chunk-defined',
    source: 'a chunk is a slice of a parent document with an index',
    target: 'المقطع جزء من المستند الأب وله ترتيب',
    domain: 'rag',
  ),
  _Term(
    id: 't-tombstone',
    source: 'tombstone',
    target: 'علامة حذف',
    domain: 'storage',
  ),
  _Term(
    id: 't-tombstone-defined',
    source: 'a tombstone marks deleted data until compaction reclaims it',
    target: 'علامة الحذف تعلم البيانات المحذوفة حتى يستعيدها الدمج',
    domain: 'storage',
  ),
];

/// Translation memory: bilingual term lookup with domain pre-filters.
/// The arabic tokenizer stems both sides, so inflected Arabic queries
/// still match glossary entries.
class GlossaryPage extends StatefulWidget {
  const GlossaryPage({super.key});

  @override
  State<GlossaryPage> createState() => _GlossaryPageState();
}

class _GlossaryPageState extends State<GlossaryPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _query = TextEditingController(text: 'دمج الرتب');
  String _domain = 'all';

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _query.dispose();
    _db?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final db = await openDemoDb(
      dirName: 'waffle_demo_glossary',
      schema: _glossarySchema,
      dimension: DemoEmbedder.dim,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Indexing glossary...');
      await db.insertBatch(
        _seedTerms
            .map(
              (t) => WaffleRecord(
                id: t.id,
                vector: DemoEmbedder.embed('${t.source} ${t.target}'),
                text: '${t.source} = ${t.target}',
                payload: {
                  'domain': t.domain,
                  'direction': t.id.contains('defined') ? 'en-ar' : 'term',
                  'source': t.source,
                  'target': t.target,
                },
              ),
            )
            .toList(),
      );
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} terms ready';
    });
    _run();
  }

  Future<void> _run() async {
    final db = _db;
    if (db == null) return;
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final sw = Stopwatch()..start();
    final hits = await db.search(
      vector: DemoEmbedder.embed(q),
      text: q,
      topK: 10,
      filter: _domain == 'all' ? null : WaffleEqFilter('domain', _domain),
      alpha: 0.4,
    );
    sw.stop();
    setState(() {
      _hits = hits;
      _searchMs = sw.elapsedMicroseconds / 1000.0;
      _status = '${hits.length} hits in ${_searchMs.toStringAsFixed(2)} ms';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Glossary')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_status),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Glossary')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: 'Term (English or Arabic)',
                    hintText: 'e.g. دمج الرتب, chunk',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _run(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _domain,
                        decoration: const InputDecoration(labelText: 'Domain'),
                        items: const ['all', 'search', 'ml', 'rag', 'storage']
                            .map(
                              (d) => DropdownMenuItem(value: d, child: Text(d)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _domain = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _run, child: const Text('Lookup')),
                  ],
                ),
                Text(_status, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _hits.length,
              itemBuilder: (context, i) {
                final h = _hits[i];
                final parts = (h.text ?? '').split(' = ');
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.translate),
                    title: Text(
                      parts.isNotEmpty ? parts[0] : h.id,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: parts.length > 1
                        ? Text(parts[1], textDirection: TextDirection.rtl)
                        : null,
                    trailing: Text(
                      's=${h.score.toStringAsFixed(3)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
