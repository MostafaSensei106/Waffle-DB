import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';
import 'demo_embed.dart';

final _codeSchema = WaffleSchema(
  fields: [
    WaffleFields.string('language'),
    WaffleFields.string('kind'),
  ],
  textLanguage: WaffleLanguage.english,
);

class _Symbol {
  final String id;
  final String? parentId;
  final int chunkIndex;
  final String name;
  final String detail;
  final String language;
  final String kind;

  const _Symbol({
    required this.id,
    required this.name,
    required this.detail,
    required this.language,
    required this.kind,
    this.parentId,
    this.chunkIndex = 0,
  });
}

const _seedCode = [
  _Symbol(
    id: 'file-store',
    name: 'store.rs',
    detail: 'Redb-backed chunk, vector and bitmap storage tables.',
    language: 'rust',
    kind: 'file',
  ),
  _Symbol(
    id: 'store-write-record',
    parentId: 'file-store',
    chunkIndex: 0,
    name: 'Store::write_record',
    detail:
        'fn write_record stores the id mapping, the archived chunk bytes and the raw float bytes in one write transaction.',
    language: 'rust',
    kind: 'function',
  ),
  _Symbol(
    id: 'store-bitmap-add',
    parentId: 'file-store',
    chunkIndex: 1,
    name: 'Store::bitmap_add',
    detail:
        'fn bitmap_add loads the roaring bitmap for a field value, inserts the internal id and persists it back through the same transaction.',
    language: 'rust',
    kind: 'function',
  ),
  _Symbol(
    id: 'file-filter',
    name: 'filter.rs',
    detail: 'Filter AST parsing and bitmap evaluation.',
    language: 'rust',
    kind: 'file',
  ),
  _Symbol(
    id: 'filter-evaluate',
    parentId: 'file-filter',
    chunkIndex: 0,
    name: 'evaluate_filter',
    detail:
        'fn evaluate_filter folds eq, in, and and or nodes into a single allowed-ids roaring bitmap for the graph walk.',
    language: 'rust',
    kind: 'function',
  ),
  _Symbol(
    id: 'file-builder',
    name: 'waffle_query_builder.dart',
    detail: 'Fluent Dart builder for dense, sparse and hybrid queries.',
    language: 'dart',
    kind: 'file',
  ),
  _Symbol(
    id: 'builder-execute',
    parentId: 'file-builder',
    chunkIndex: 0,
    name: 'WaffleQueryBuilder.execute',
    detail:
        'execute validates that a vector or text was set, encodes the stacked filters into one JSON AST and runs a unified search request.',
    language: 'dart',
    kind: 'method',
  ),
  _Symbol(
    id: 'builder-eq',
    parentId: 'file-builder',
    chunkIndex: 1,
    name: 'WaffleQueryBuilder.eq',
    detail:
        'eq stacks an equality pre-filter that the engine evaluates as a bitmap predicate before any distance is computed.',
    language: 'dart',
    kind: 'method',
  ),
  _Symbol(
    id: 'file-collection',
    name: 'waffle_collection.dart',
    detail: 'Logical namespaces with automatic collection pre-filtering.',
    language: 'dart',
    kind: 'file',
  ),
  _Symbol(
    id: 'collection-search',
    parentId: 'file-collection',
    chunkIndex: 0,
    name: 'WaffleCollection.search',
    detail:
        'search injects an equality filter on the indexed _collection field so results never leak across collections.',
    language: 'dart',
    kind: 'method',
  ),
];

/// Code search: exact symbol match (where vectors fail) + language/kind
/// pre-filters + file context through parent lookup.
class CodeSearchPage extends StatefulWidget {
  const CodeSearchPage({super.key});

  @override
  State<CodeSearchPage> createState() => _CodeSearchPageState();
}

class _CodeSearchPageState extends State<CodeSearchPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _query = TextEditingController(text: 'bitmap_add');
  String _language = 'all';
  String _kind = 'all';

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
      dirName: 'waffle_demo_code',
      schema: _codeSchema,
      dimension: DemoEmbedder.dim,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Indexing symbols...');
      await db.insertBatch(_seedCode
          .map((s) => WaffleRecord(
                id: s.id,
                vector: DemoEmbedder.embed('${s.name} ${s.detail}'),
                text: '${s.name}: ${s.detail}',
                payload: {
                  'language': s.language,
                  'kind': s.kind,
                  'name': s.name,
                },
                parentId: s.parentId,
                chunkIndex: s.chunkIndex,
              ))
          .toList());
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} symbols ready';
    });
    _run();
  }

  void _run() {
    final db = _db;
    if (db == null) return;
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final filters = <WaffleFilter>[
      if (_language != 'all') WaffleEqFilter('language', _language),
      if (_kind != 'all') WaffleEqFilter('kind', _kind),
    ];
    final sw = Stopwatch()..start();
    final hits = db.search(
      vector: DemoEmbedder.embed(q),
      text: q,
      topK: 10,
      filters: filters.isEmpty ? null : filters,
      alpha: 0.3,
    );
    sw.stop();
    setState(() {
      _hits = hits;
      _searchMs = sw.elapsedMicroseconds / 1000.0;
      _status = '${hits.length} hits in ${_searchMs.toStringAsFixed(2)} ms';
    });
  }

  Future<void> _showFile(WaffleHit hit) async {
    final db = _db;
    if (db == null) return;
    final parent = db.getParent(hit.id);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parent?.id ?? hit.id),
        content: Text(parent?.text ?? hit.text ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Code Search')),
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
      appBar: AppBar(title: const Text('Code Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: 'Symbol or concept',
                    hintText: 'e.g. bitmap_add, pre-filter',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _run(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _language,
                        decoration:
                            const InputDecoration(labelText: 'Language'),
                        items: const ['all', 'rust', 'dart']
                            .map((l) => DropdownMenuItem(
                                value: l, child: Text(l)))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _language = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _kind,
                        decoration:
                            const InputDecoration(labelText: 'Kind'),
                        items: const ['all', 'file', 'function', 'method']
                            .map((k) => DropdownMenuItem(
                                value: k, child: Text(k)))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _kind = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _run,
                      child: const Text('Find'),
                    ),
                  ],
                ),
                Text(_status,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _hits.length,
              itemBuilder: (context, i) {
                final h = _hits[i];
                final payload = jsonDecode(h.payloadJson ?? '{}')
                    as Map<String, dynamic>;
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.code),
                    title: Text(
                      payload['name']?.toString() ?? h.id,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(h.text ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          children: [
                            Chip(
                              label: Text(
                                  payload['language']?.toString() ?? ''),
                              visualDensity: VisualDensity.compact,
                            ),
                            Chip(
                              label: Text(
                                  payload['kind']?.toString() ?? ''),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: 'Open file',
                      onPressed: () => _showFile(h),
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
