import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';

final _contactsSchema = WaffleSchema(
  fields: [
    WaffleFields.string('group'),
    WaffleFields.boolean('starred'),
  ],
  textLanguage: WaffleLanguage.english,
);

const _groups = ['family', 'work', 'friends'];
const _all = 'all';

class _Contact {
  final String id;
  final String name;
  final String phone;
  final String group;
  final String note;
  final bool starred;
  final int calls;
  final int messages;
  final int daysSinceContact;

  const _Contact({
    required this.id,
    required this.name,
    required this.phone,
    required this.group,
    required this.note,
    required this.starred,
    required this.calls,
    required this.messages,
    required this.daysSinceContact,
  });

  Float32List get profile => Float32List.fromList([
        (calls / 500.0).clamp(0.0, 1.0),
        (messages / 2000.0).clamp(0.0, 1.0),
        ((30 - daysSinceContact) / 30.0).clamp(0.0, 1.0),
      ]);
}

List<_Contact> _seedContacts() {
  const names = [
    ('Ahmed Hassan', 'family', 'call mom about friday lunch'),
    ('Sara Mahmoud', 'family', 'school pickup schedule'),
    ('Mohamed Ali', 'work', 'project deadline and code review'),
    ('Layla Ibrahim', 'work', 'quarterly report figures'),
    ('Omar Farouk', 'friends', 'football match on saturday'),
    ('Nour El-Din', 'friends', 'camping trip gear list'),
    ('Karim Adel', 'work', 'client demo preparation'),
    ('Hana Youssef', 'family', 'doctor appointment reminder'),
    ('Yassin Khaled', 'friends', 'birthday party planning'),
    ('Mariam Samy', 'work', 'design feedback round two'),
    ('Mostafa Fathy', 'friends', 'gaming night and new releases'),
    ('Dina Sherif', 'family', 'grocery list for the week'),
    ('Tarek Nour', 'work', 'server migration checklist'),
    ('Rania Atef', 'friends', 'book club next novel'),
    ('Hassan Omar', 'family', 'car maintenance booking'),
    ('Salma Tariq', 'work', 'hiring interviews schedule'),
    ('Fares Galal', 'friends', 'concert tickets booking'),
    ('Nadine Hany', 'family', 'school fees payment'),
    ('Adham Ramy', 'work', 'budget forecast draft'),
    ('Jana Karim', 'friends', 'photography walk downtown'),
  ];
  final random = Random(19);
  final out = <_Contact>[];
  for (var i = 0; i < names.length; i++) {
    final entry = names[i];
    out.add(_Contact(
      id: 'c-$i',
      name: entry.$1,
      phone: '+20 1${random.nextInt(10)} ${100 + random.nextInt(900)} ${1000 + random.nextInt(9000)}',
      group: entry.$2,
      note: entry.$3,
      starred: random.nextDouble() < 0.25,
      calls: random.nextInt(400),
      messages: random.nextInt(1500),
      daysSinceContact: random.nextInt(30),
    ));
  }
  out.addAll([
    _Contact(
      id: 'c-20',
      name: 'محمد عبدالله',
      phone: '+20 100 555 1234',
      group: 'family',
      note: 'متابعة أوراق السفر والحجوزات',
      starred: true,
      calls: 320,
      messages: 900,
      daysSinceContact: 1,
    ),
    _Contact(
      id: 'c-21',
      name: 'أحمد الشريف',
      phone: '+20 122 555 9876',
      group: 'work',
      note: 'اجتماع المشروع الجديد يوم الأحد',
      starred: false,
      calls: 150,
      messages: 600,
      daysSinceContact: 3,
    ),
  ]);
  return out;
}

/// Smart contacts: exact name/number match (BM25) + group/starred
/// pre-filters + interaction-profile similarity fused with RRF.
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _query = TextEditingController(text: 'football');
  String _group = _all;
  bool _starredOnly = false;
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
      dirName: 'waffle_demo_contacts',
      schema: _contactsSchema,
      dimension: 3,
      metric: WaffleMetric.euclidean,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Seeding contacts...');
      await db.insertBatch(_seedContacts()
          .map((c) => WaffleRecord(
                id: c.id,
                vector: c.profile,
                text: '${c.name} ${c.phone} ${c.note}',
                payload: {
                  'group': c.group,
                  'starred': c.starred,
                  'name': c.name,
                  'phone': c.phone,
                },
              ))
          .toList());
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} contacts ready';
    });
    _run();
  }

  void _run() {
    final db = _db;
    if (db == null) return;
    final keyword = _query.text.trim();
    final filters = <WaffleFilter>[
      if (_group != _all) WaffleEqFilter('group', _group),
      if (_starredOnly) WaffleEqFilter('starred', true),
    ];
    final sw = Stopwatch()..start();
    final hits = db.search(
      vector: Float32List.fromList([0.8, 0.7, 0.9]),
      text: keyword.isEmpty ? null : keyword,
      topK: 20,
      filters: filters.isEmpty ? null : filters,
      alpha: keyword.isEmpty ? 1.0 : _alpha,
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
        appBar: AppBar(title: const Text('Contacts')),
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
      appBar: AppBar(title: const Text('Contacts')),
      body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  labelText: 'Name, number or note (exact match)',
                  hintText: 'e.g. football, 555, mohamed',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _group,
                      decoration: const InputDecoration(labelText: 'Group'),
                      items: [_all, ..._groups]
                          .map((g) =>
                              DropdownMenuItem(value: g, child: Text(g)))
                          .toList(),
                      onChanged: (v) => setState(() => _group = v ?? _all),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Starred'),
                    selected: _starredOnly,
                    onSelected: (v) => setState(() => _starredOnly = v),
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
                  FilledButton(
                    onPressed: _run,
                    child: const Text('Search'),
                  ),
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
              final payload = jsonDecode(h.payloadJson ?? '{}')
                  as Map<String, dynamic>;
              final starred = payload['starred'] == true;
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      (payload['name']?.toString() ?? '?').substring(0, 1),
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          payload['name']?.toString() ?? h.id,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (starred)
                        const Icon(Icons.star,
                            size: 16, color: Colors.amber),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(payload['phone']?.toString() ?? ''),
                      const SizedBox(height: 4),
                      Chip(
                        label: Text(payload['group']?.toString() ?? '-'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  isThreeLine: true,
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
