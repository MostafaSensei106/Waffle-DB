import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';

final _productSchema = WaffleSchema(
  fields: [
    WaffleFields.string('category'),
    WaffleFields.string('band'),
    WaffleFields.boolean('inStock'),
    WaffleFields.integer('price'),
  ],
  textLanguage: WaffleLanguage.english,
);

const _categories = ['phones', 'laptops', 'audio'];
const _all = 'all';

class _Product {
  final String id;
  final String name;
  final String desc;
  final String category;
  final int price;
  final double rating;
  final double weight;

  const _Product({
    required this.id,
    required this.name,
    required this.desc,
    required this.category,
    required this.price,
    required this.rating,
    required this.weight,
  });

  String get band => price < 300 ? 'budget' : (price < 1000 ? 'mid' : 'premium');

  Float32List get profile => Float32List.fromList([
        (price / 2500.0).clamp(0.0, 1.0),
        (rating / 5.0).clamp(0.0, 1.0),
        (weight / 2200.0).clamp(0.0, 1.0),
      ]);
}

List<_Product> _seedProducts() {
  final random = Random(7);
  final out = <_Product>[];
  const names = {
    'phones': ['Nova', 'Pulse', 'Orbit', 'Vega', 'Atlas'],
    'laptops': ['Aero', 'Forge', 'Summit', 'Drift', 'Cinder'],
    'audio': ['Echo', 'Tempo', 'Bassline', 'Aria', 'Riff'],
  };
  const descs = {
    'phones': ['6.5 inch display with 5G and dual camera', 'long battery life with fast charging', 'compact body with bright screen'],
    'laptops': ['14 inch laptop with 16GB memory for work', 'lightweight ultrabook with all-day battery', 'gaming laptop with dedicated graphics'],
    'audio': ['wireless earbuds with noise cancelling', 'over-ear headphones with deep bass', 'portable speaker with waterproof body'],
  };
  var n = 0;
  for (final cat in _categories) {
    final priceBase = cat == 'phones'
        ? [200, 1000]
        : (cat == 'laptops' ? [600, 1900] : [30, 370]);
    final weightBase = cat == 'phones'
        ? [150, 70]
        : (cat == 'laptops' ? [1200, 1000] : [50, 350]);
    for (var i = 0; i < 80; i++) {
      final line = names[cat]![i % 5];
      out.add(_Product(
        id: 'p-$n',
        name: '$line ${cat == 'audio' ? 'Sound' : cat == 'phones' ? 'Phone' : 'Book'} ${i + 1}',
        desc: descs[cat]![i % 3],
        category: cat,
        price: priceBase[0] + random.nextInt(priceBase[1]),
        rating: 3.0 + random.nextDouble() * 2.0,
        weight: weightBase[0] + random.nextDouble() * weightBase[1],
      ));
      n++;
    }
  }
  return out;
}

/// Faceted hybrid search: BM25 keywords + profile similarity + pre-filters.
class ProductSearchPage extends StatefulWidget {
  const ProductSearchPage({super.key});

  @override
  State<ProductSearchPage> createState() => _ProductSearchPageState();
}

class _ProductSearchPageState extends State<ProductSearchPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _keyword = TextEditingController();
  String _category = _all;
  String _band = _all;
  bool _inStockOnly = false;
  double _alpha = 0.5;
  final double _targetPrice = 800;
  final double _targetRating = 4.0;
  final double _targetWeight = 500;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _keyword.dispose();
    _db?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final db = await openDemoDb(
      dirName: 'waffle_demo_products',
      schema: _productSchema,
      dimension: 3,
      metric: WaffleMetric.euclidean,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Seeding 240 products...');
      final stock = Random(21);
      await db.insertBatch(_seedProducts()
          .map((p) => WaffleRecord(
                id: p.id,
                vector: p.profile,
                text: '${p.name} ${p.desc}',
                payload: {
                  'category': p.category,
                  'band': p.band,
                  'inStock': stock.nextDouble() < 0.85,
                  'price': p.price,
                  'name': p.name,
                  'rating': double.parse(p.rating.toStringAsFixed(1)),
                },
              ))
          .toList());
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} products ready';
    });
    _run();
  }

  void _run() {
    final db = _db;
    if (db == null) return;
    final keyword = _keyword.text.trim();
    final filters = <WaffleFilter>[
      if (_category != _all) WaffleEqFilter('category', _category),
      if (_band != _all) WaffleEqFilter('band', _band),
      if (_inStockOnly) WaffleEqFilter('inStock', true),
    ];
    final sw = Stopwatch()..start();
    final hits = db.search(
      vector: Float32List.fromList([
        (_targetPrice / 2500.0).clamp(0.0, 1.0),
        (_targetRating / 5.0).clamp(0.0, 1.0),
        (_targetWeight / 2200.0).clamp(0.0, 1.0),
      ]),
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
        appBar: AppBar(title: const Text('Products')),
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
      appBar: AppBar(title: const Text('Products')),
      body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _keyword,
                decoration: const InputDecoration(
                  labelText: 'Keywords (BM25)',
                  hintText: 'e.g. wireless noise cancelling',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: [_all, ..._categories]
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _category = v ?? _all),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _band,
                      decoration: const InputDecoration(labelText: 'Band'),
                      items: const [_all, 'budget', 'mid', 'premium']
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) => setState(() => _band = v ?? _all),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Stock'),
                    selected: _inStockOnly,
                    onSelected: (v) =>
                        setState(() => _inStockOnly = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                        'Target \$${_targetPrice.toInt()} · ${_targetRating.toStringAsFixed(1)}★ · ${_targetWeight.toInt()}g'),
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
              final inStock = payload['inStock'] == true;
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  title: Text(payload['name']?.toString() ?? h.id,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        children: [
                          Chip(
                            label: Text(
                                payload['category']?.toString() ?? '-'),
                            visualDensity: VisualDensity.compact,
                          ),
                          Chip(
                            label: Text(payload['band']?.toString() ?? '-'),
                            visualDensity: VisualDensity.compact,
                          ),
                          Chip(
                            label: Text(
                                '\$${payload['price']?.toString() ?? '-'}'),
                            visualDensity: VisualDensity.compact,
                          ),
                          Chip(
                            label: Text(inStock ? 'In stock' : 'Out'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: inStock
                                ? Colors.green.shade100
                                : Colors.red.shade100,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.star,
                              size: 14, color: Colors.amber),
                          Text(
                              ' ${payload['rating']?.toString() ?? '-'}   score ${h.score.toStringAsFixed(3)}'),
                        ],
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
