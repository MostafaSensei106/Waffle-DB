import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';

final _notesSchema = WaffleSchema(
  fields: [
    WaffleFields.string('docType'),
    WaffleFields.string('lang'),
  ],
  textLanguage: WaffleLanguage.arabic,
);

class _NoteChunk {
  final String id;
  final String? parentId;
  final int chunkIndex;
  final String text;
  final String docType;

  const _NoteChunk({
    required this.id,
    required this.text,
    required this.docType,
    this.parentId,
    this.chunkIndex = 0,
  });
}

const _seedNotes = [
  _NoteChunk(
    id: 'guide-nova',
    text: 'دليل استخدام سماعات نوفا اللاسلكية',
    docType: 'guide',
  ),
  _NoteChunk(
    id: 'guide-nova-c0',
    parentId: 'guide-nova',
    chunkIndex: 0,
    text: 'سماعات نوفا اللاسلكية تعمل بالبلوتوث الإصدار الخامس وتدعم إلغاء الضوضاء النشط لمدة تصل إلى ثلاثين ساعة تشغيل.',
    docType: 'guide',
  ),
  _NoteChunk(
    id: 'guide-nova-c1',
    parentId: 'guide-nova',
    chunkIndex: 1,
    text: 'لشحن السماعات ضع العلبة على الشاحن اللاسلكي أو وصل كابل يو اس سي وانتظر حتى يتحول المؤشر إلى اللون الأخضر.',
    docType: 'guide',
  ),
  _NoteChunk(
    id: 'guide-nova-c2',
    parentId: 'guide-nova',
    chunkIndex: 2,
    text: 'إذا انقطع الاتصال أعد تشغيل البلوتوث في هاتفك ثم اضغط زر الاقتران في العلبة لمدة ثلاث ثوان.',
    docType: 'guide',
  ),
  _NoteChunk(
    id: 'faq-charge',
    text: 'الأسئلة الشائعة عن الشحن والبطارية',
    docType: 'faq',
  ),
  _NoteChunk(
    id: 'faq-charge-c0',
    parentId: 'faq-charge',
    chunkIndex: 0,
    text: 'الشاحن المرفق بقوة عشرين واط يشحن الهاتف بالكامل خلال ساعة واحدة فقط.',
    docType: 'faq',
  ),
  _NoteChunk(
    id: 'faq-charge-c1',
    parentId: 'faq-charge',
    chunkIndex: 1,
    text: 'لا تستخدم شواحن غير معتمدة لأنها قد تتلف البطارية وتلغي الضمان.',
    docType: 'faq',
  ),
  _NoteChunk(
    id: 'faq-charge-c2',
    parentId: 'faq-charge',
    chunkIndex: 2,
    text: 'يمكنك متابعة نسبة الشحن من التطبيق أو من الأيقونة الظاهرة أعلى الشاشة.',
    docType: 'faq',
  ),
  _NoteChunk(
    id: 'policy-return',
    text: 'سياسة الاسترجاع والضمان',
    docType: 'policy',
  ),
  _NoteChunk(
    id: 'policy-return-c0',
    parentId: 'policy-return',
    chunkIndex: 0,
    text: 'يمكنك استرجاع أي منتج خلال أربعة عشر يوما من تاريخ الشراء بحالته الأصلية.',
    docType: 'policy',
  ),
  _NoteChunk(
    id: 'policy-return-c1',
    parentId: 'policy-return',
    chunkIndex: 1,
    text: 'الضمان يغطي عيوب الصناعة لمدة سنتين ولا يشمل الكسر الناتج عن سوء الاستخدام.',
    docType: 'policy',
  ),
  _NoteChunk(
    id: 'policy-return-c2',
    parentId: 'policy-return',
    chunkIndex: 2,
    text: 'لطلب الاسترجاع تواصل مع خدمة العملاء مع رقم الفاتورة وسيصلك مندوب الشحن.',
    docType: 'policy',
  ),
];

/// Arabic RAG demo: BM25 keyword search with stemming, chunk windows,
/// parent lookup and true delete across both engines.
class NotesRagPage extends StatefulWidget {
  const NotesRagPage({super.key});

  @override
  State<NotesRagPage> createState() => _NotesRagPageState();
}

class _NotesRagPageState extends State<NotesRagPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;
  String? _expandedId;
  List<WaffleHit> _window = [];

  final _query = TextEditingController(text: 'استرجاع المنتج');
  String _docType = 'all';

  static const _dim = 8;

  Float32List _zeroVector() => Float32List(_dim);

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
      dirName: 'waffle_demo_notes',
      schema: _notesSchema,
      dimension: _dim,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Seeding Arabic notes...');
      await db.insertBatch(_seedNotes
          .map((n) => WaffleRecord(
                id: n.id,
                vector: _zeroVector(),
                text: n.text,
                payload: {'docType': n.docType, 'lang': 'ar'},
                parentId: n.parentId,
                chunkIndex: n.chunkIndex,
              ))
          .toList());
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} notes ready';
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
      text: q,
      topK: 10,
      filter: _docType == 'all' ? null : WaffleEqFilter('docType', _docType),
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

  Future<void> _expand(WaffleHit hit) async {
    final db = _db;
    if (db == null) return;
    final window = db.getNeighbors(hit.id, window: 1);
    setState(() {
      _expandedId = hit.id;
      _window = window;
    });
  }

  Future<void> _showParent(WaffleHit hit) async {
    final db = _db;
    if (db == null) return;
    final parent = db.getParent(hit.id);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parent?.id ?? 'No parent'),
        content: Text(parent?.text ?? 'This record is a parent document.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(WaffleHit hit) async {
    final db = _db;
    if (db == null) return;
    await db.delete(hit.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted ${hit.id} from both engines')),
    );
    _run();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  labelText: 'استعلام بالعربية (BM25)',
                  hintText: 'مثال: شحن السماعات',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _docType,
                      decoration:
                          const InputDecoration(labelText: 'نوع المستند'),
                      items: const ['all', 'guide', 'faq', 'policy']
                          .map((t) =>
                              DropdownMenuItem(value: t, child: Text(t)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _docType = v ?? 'all'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _run,
                    child: const Text('بحث'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
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
              final expanded = _expandedId == h.id;
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(h.id,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall),
                          ),
                          Text('s=${h.score.toStringAsFixed(3)}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(h.text ?? '',
                          textDirection: TextDirection.rtl),
                      if (expanded)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.all(8),
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Window context (${_window.length} chunks):',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall),
                              for (final w in _window)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('• ${w.text ?? ''}',
                                      textDirection: TextDirection.rtl,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ),
                            ],
                          ),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _expand(h),
                            child: const Text('Window'),
                          ),
                          TextButton(
                            onPressed: () => _showParent(h),
                            child: const Text('Parent'),
                          ),
                          TextButton(
                            onPressed: () => _delete(h),
                            child: const Text('Delete'),
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
    );
  }
}
