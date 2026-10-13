import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';
import 'demo_embed.dart';

final _supportSchema = WaffleSchema(
  fields: [
    WaffleFields.string('kind'),
    WaffleFields.string('priority'),
    WaffleFields.string('status'),
  ],
  textLanguage: WaffleLanguage.english,
);

class _Ticket {
  final String id;
  final String title;
  final String text;
  final String kind;
  final String priority;
  final String status;

  const _Ticket({
    required this.id,
    required this.title,
    required this.text,
    required this.kind,
    required this.priority,
    required this.status,
  });
}

const _seedTickets = [
  _Ticket(
    id: 'faq-returns',
    title: 'FAQ: returns policy',
    text:
        'Customers can return any product within fourteen days in its original condition with the receipt.',
    kind: 'faq',
    priority: 'low',
    status: 'open',
  ),
  _Ticket(
    id: 't-101',
    title: 'Return request #101',
    text:
        'Customer wants to return headphones bought twelve days ago, has the receipt and the box.',
    kind: 'ticket',
    priority: 'high',
    status: 'open',
  ),
  _Ticket(
    id: 't-102',
    title: 'Late delivery #102',
    text:
        'Order delayed by a week, customer asks for compensation and a new delivery date.',
    kind: 'ticket',
    priority: 'high',
    status: 'open',
  ),
  _Ticket(
    id: 't-103',
    title: 'Damaged box #103',
    text:
        'Package arrived with a dented corner but the device works, customer wants a partial refund.',
    kind: 'ticket',
    priority: 'medium',
    status: 'open',
  ),
  _Ticket(
    id: 't-104',
    title: 'Wrong color #104',
    text:
        'Customer ordered black earbuds and received white ones, asks for an exchange.',
    kind: 'ticket',
    priority: 'medium',
    status: 'resolved',
  ),
  _Ticket(
    id: 't-105',
    title: 'Refund status #105',
    text:
        'Customer asks where the refund for the returned charger is after ten days.',
    kind: 'ticket',
    priority: 'low',
    status: 'open',
  ),
];

/// Support copilot: match incoming tickets against resolved history and
/// FAQs, triage by priority/status pre-filters, resolve with upsert and
/// sweep resolved tickets with deleteWhere.
class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _query = TextEditingController(text: 'customer wants to return');
  String _priority = 'all';
  String _statusFilter = 'all';

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
      dirName: 'waffle_demo_support',
      schema: _supportSchema,
      dimension: DemoEmbedder.dim,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Indexing tickets...');
      await db.insertBatch(
        _seedTickets
            .map(
              (t) => WaffleRecord(
                id: t.id,
                vector: DemoEmbedder.embed('${t.title} ${t.text}'),
                text: '${t.title}. ${t.text}',
                payload: {
                  'kind': t.kind,
                  'priority': t.priority,
                  'status': t.status,
                  'title': t.title,
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
      _status = '${db.count()} tickets ready';
    });
    _run();
  }

  Future<void> _run() async {
    final db = _db;
    if (db == null) return;
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final filters = <WaffleFilter>[
      if (_priority != 'all') WaffleEqFilter('priority', _priority),
      if (_statusFilter != 'all') WaffleEqFilter('status', _statusFilter),
    ];
    final sw = Stopwatch()..start();
    final hits = await db.search(
      vector: DemoEmbedder.embed(q),
      text: q,
      topK: 10,
      filters: filters.isEmpty ? null : filters,
      alpha: 0.4,
    );
    sw.stop();
    setState(() {
      _hits = hits;
      _searchMs = sw.elapsedMicroseconds / 1000.0;
      _status = '${hits.length} hits in ${_searchMs.toStringAsFixed(2)} ms';
    });
  }

  Future<void> _resolve(WaffleHit hit) async {
    final db = _db;
    if (db == null) return;
    final payload = jsonDecode(hit.payloadJson ?? '{}') as Map<String, dynamic>;
    await db.upsert(
      hit.id,
      DemoEmbedder.embed(hit.text ?? hit.id),
      text: hit.text ?? '',
      payload: {
        'kind': payload['kind'] ?? 'ticket',
        'priority': payload['priority'] ?? 'low',
        'status': 'resolved',
        'title': payload['title'] ?? hit.id,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Resolved ${hit.id} via upsert')));
    _run();
  }

  Future<void> _sweepResolved() async {
    final db = _db;
    if (db == null) return;
    final n = await db.deleteWhere(WaffleEqFilter('status', 'resolved'));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Swept $n resolved tickets')));
    _run();
  }

  Color _priorityColor(String? p) => switch (p) {
    'high' => Colors.red.shade100,
    'medium' => Colors.orange.shade100,
    _ => Colors.green.shade100,
  };

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Support')),
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
      appBar: AppBar(
        title: const Text('Support'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'Sweep resolved (deleteWhere)',
            onPressed: _sweepResolved,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: 'Incoming ticket',
                    hintText: 'e.g. customer wants to return',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _run(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _priority,
                        decoration: const InputDecoration(
                          labelText: 'Priority',
                        ),
                        items: const ['all', 'high', 'medium', 'low']
                            .map(
                              (p) => DropdownMenuItem(value: p, child: Text(p)),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _priority = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _statusFilter,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: const ['all', 'open', 'resolved']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _statusFilter = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _run, child: const Text('Match')),
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
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    title: Text(
                      payload['title']?.toString() ?? h.id,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          h.text ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          children: [
                            Chip(
                              label: Text(payload['kind']?.toString() ?? ''),
                              visualDensity: VisualDensity.compact,
                            ),
                            Chip(
                              label: Text(
                                payload['priority']?.toString() ?? '',
                              ),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: _priorityColor(
                                payload['priority']?.toString(),
                              ),
                            ),
                            Chip(
                              label: Text(payload['status']?.toString() ?? ''),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: payload['status'] == 'open'
                        ? IconButton(
                            icon: const Icon(Icons.check_circle_outline),
                            tooltip: 'Resolve via upsert',
                            onPressed: () => _resolve(h),
                          )
                        : const Icon(Icons.check_circle, color: Colors.green),
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
