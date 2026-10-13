import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';
import 'demo_embed.dart';

final _docsSchema = WaffleSchema(
  fields: [WaffleFields.string('section'), WaffleFields.string('version')],
  textLanguage: WaffleLanguage.english,
);

class _DocChunk {
  final String id;
  final String? parentId;
  final int chunkIndex;
  final String title;
  final String text;
  final String section;
  final String version;

  const _DocChunk({
    required this.id,
    required this.title,
    required this.text,
    required this.section,
    required this.version,
    this.parentId,
    this.chunkIndex = 0,
  });
}

const _seedDocs = [
  _DocChunk(
    id: 'filtering',
    title: 'Metadata pre-filtering',
    text: 'WaffleDB filters during vector search, not after it.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'filtering-c0',
    parentId: 'filtering',
    chunkIndex: 0,
    title: 'Why pre-filtering matters',
    text:
        'Post-filtering fetches the top-k vectors and discards the ones that miss the filter. When the filter is selective, the answer set can come back empty even though matching vectors exist deeper in the ranking.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'filtering-c1',
    parentId: 'filtering',
    chunkIndex: 1,
    title: 'How bitmaps filter the graph walk',
    text:
        'Each indexed metadata value maps to a compressed roaring bitmap of internal vector ids. A query compiles its filters into one allowed-ids bitmap with bitwise AND/OR, and the HNSW traversal skips every node outside that set before computing a distance.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'filtering-c2',
    parentId: 'filtering',
    chunkIndex: 2,
    title: 'Numeric fields',
    text:
        'Numeric fields live in an ordered index keyed by field hash, sortable value bits and internal id. Equality filters scan one value slice; range filters arrive in v1.1 on the same layout.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'hybrid',
    title: 'Hybrid search',
    text: 'Dense vectors understand meaning, BM25 understands exact words.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'hybrid-c0',
    parentId: 'hybrid',
    chunkIndex: 0,
    title: 'When vectors fail',
    text:
        'Vector search misses exact matches such as person names, model numbers and error codes. Keyword search with BM25 and stemming catches exactly those cases.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'hybrid-c1',
    parentId: 'hybrid',
    chunkIndex: 1,
    title: 'Fusing with RRF',
    text:
        'Both engines run in parallel and each returns a ranked list. Reciprocal rank fusion scores every document from its ranks alone, so no score normalization is needed. The alpha knob blends dense and sparse weight.',
    section: 'search',
    version: 'v2',
  ),
  _DocChunk(
    id: 'lifecycle',
    title: 'Write and delete lifecycle',
    text: 'Every write path is explicit: insert, upsert, batch, flush, delete.',
    section: 'api',
    version: 'v2',
  ),
  _DocChunk(
    id: 'lifecycle-c0',
    parentId: 'lifecycle',
    chunkIndex: 0,
    title: 'Upsert and re-indexing',
    text:
        'Upsert replaces a record if its id exists and inserts otherwise, reporting whether a replacement happened. Re-index pipelines combine deleteWhere with insertBatch: wipe one category, then bulk-load the fresh documents.',
    section: 'api',
    version: 'v2',
  ),
  _DocChunk(
    id: 'lifecycle-c1',
    parentId: 'lifecycle',
    chunkIndex: 1,
    title: 'True delete',
    text:
        'Delete removes the vector from the HNSW graph, tombstones the text segments, drops the stored chunk and prunes every filter bitmap. The freed internal id returns to a freelist for reuse.',
    section: 'api',
    version: 'v2',
  ),
  _DocChunk(
    id: 'schema-v1',
    title: 'Strict schemas (legacy)',
    text: 'Version one required schemaless metadata blobs.',
    section: 'api',
    version: 'v1',
  ),
];

/// Documentation RAG: chunked guides, hybrid retrieval, section/version
/// pre-filters and citable window context for answers.
class DocsRagPage extends StatefulWidget {
  const DocsRagPage({super.key});

  @override
  State<DocsRagPage> createState() => _DocsRagPageState();
}

class _DocsRagPageState extends State<DocsRagPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;
  String? _expandedId;
  List<WaffleHit> _window = [];

  final _query = TextEditingController(text: 'how does filtering work');
  String _section = 'all';
  double _alpha = 0.5;

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
      dirName: 'waffle_demo_docs',
      schema: _docsSchema,
      dimension: DemoEmbedder.dim,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Indexing docs...');
      await db.insertBatch(
        _seedDocs
            .map(
              (d) => WaffleRecord(
                id: d.id,
                vector: DemoEmbedder.embed('${d.title} ${d.text}'),
                text: '${d.title}. ${d.text}',
                payload: {
                  'section': d.section,
                  'version': d.version,
                  'title': d.title,
                },
                parentId: d.parentId,
                chunkIndex: d.chunkIndex,
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
      _status = '${db.count()} chunks ready';
    });
    _run();
  }

  void _run() {
    final db = _db;
    if (db == null) return;
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final sw = Stopwatch()..start();
    final hits = db.search(
      vector: DemoEmbedder.embed(q),
      text: q,
      topK: 8,
      filter: _section == 'all' ? null : WaffleEqFilter('section', _section),
      alpha: _alpha,
    );
    sw.stop();
    setState(() {
      _hits = hits;
      _searchMs = sw.elapsedMicroseconds / 1000.0;
      _expandedId = null;
      _window = [];
      _status = '${hits.length} chunks in ${_searchMs.toStringAsFixed(2)} ms';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Docs RAG')),
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
      appBar: AppBar(title: const Text('Docs RAG')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: 'Ask the docs',
                    hintText: 'e.g. how does filtering work',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _run(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _section,
                        decoration: const InputDecoration(labelText: 'Section'),
                        items: const ['all', 'search', 'api']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _section = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        children: [
                          const Text('Blend'),
                          Expanded(
                            child: Slider(
                              value: _alpha,
                              divisions: 10,
                              label: _alpha.toStringAsFixed(1),
                              onChanged: (v) => setState(() => _alpha = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(onPressed: _run, child: const Text('Ask')),
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
                final payload =
                    jsonDecode(h.payloadJson ?? '{}') as Map<String, dynamic>;
                final expanded = _expandedId == h.id;
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                payload['title']?.toString() ?? h.id,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            Chip(
                              label: Text(payload['section']?.toString() ?? ''),
                              visualDensity: VisualDensity.compact,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              's=${h.score.toStringAsFixed(3)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          h.text ?? '',
                          maxLines: expanded ? null : 3,
                          overflow: expanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                        ),
                        if (expanded)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(8),
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Cited context (${_window.length} chunks):',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                for (final w in _window)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '• ${w.text ?? ''}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () {
                                final window =
                                    _db?.getNeighbors(h.id, window: 1) ?? [];
                                setState(() {
                                  _expandedId = h.id;
                                  _window = window;
                                });
                              },
                              child: const Text('Cite context'),
                            ),
                          ],
                        ),
                      ],
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
