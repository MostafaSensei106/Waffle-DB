import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

import 'demo_db.dart';

final _recipeSchema = WaffleSchema(
  fields: [
    WaffleFields.string('diet'),
    WaffleFields.string('timeBand'),
    WaffleFields.string('cuisine'),
    WaffleFields.integer('calories'),
  ],
  textLanguage: WaffleLanguage.english,
);

const _diets = ['vegan', 'vegetarian', 'keto', 'none'];
const _cuisines = ['italian', 'mexican', 'asian', 'arabic'];
const _all = 'all';

String _bandFor(int minutes) =>
    minutes <= 20 ? 'quick' : (minutes <= 45 ? 'medium' : 'long');

class _Recipe {
  final String id;
  final String title;
  final String ingredients;
  final String diet;
  final String cuisine;
  final int minutes;
  final int calories;
  final double protein;

  const _Recipe({
    required this.id,
    required this.title,
    required this.ingredients,
    required this.diet,
    required this.cuisine,
    required this.minutes,
    required this.calories,
    required this.protein,
  });

  Float32List get profile => Float32List.fromList([
        (calories / 1200.0).clamp(0.0, 1.0),
        (protein / 60.0).clamp(0.0, 1.0),
        (minutes / 120.0).clamp(0.0, 1.0),
      ]);
}

List<_Recipe> _seedRecipes() {
  const bases = [
    ('pasta', 'pasta tomato garlic olive oil basil', 'italian'),
    ('tacos', 'tortilla beans corn avocado lime chili', 'mexican'),
    ('stir fry', 'rice soy sauce ginger garlic vegetables', 'asian'),
    ('koshary', 'rice lentils pasta chickpeas tomato onion', 'arabic'),
    ('salad', 'lettuce tomato cucumber olive oil lemon', 'italian'),
    ('curry', 'coconut chickpeas curry spices rice', 'asian'),
  ];
  const dietNames = {
    'vegan': 'Vegan',
    'vegetarian': 'Vegetarian',
    'keto': 'Keto',
    'none': 'Classic',
  };
  final random = Random(11);
  final out = <_Recipe>[];
  var n = 0;
  for (final diet in _diets) {
    for (var i = 0; i < 15; i++) {
      final base = bases[(i + n) % bases.length];
      final minutes = 10 + random.nextInt(80);
      out.add(_Recipe(
        id: 'r-$n',
        title: '${dietNames[diet]} ${base.$1} ${i + 1}',
        ingredients: base.$2,
        diet: diet,
        cuisine: base.$3,
        minutes: minutes,
        calories: 150 + random.nextInt(650),
        protein: 5 + random.nextDouble() * 40,
      ));
      n++;
    }
  }
  return out;
}

/// Weeknight cooking: ingredient keywords + diet/time pre-filters +
/// nutrition-profile similarity fused with RRF.
class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  WaffleDatabase? _db;
  bool _ready = false;
  String _status = 'Opening database...';
  List<WaffleHit> _hits = [];
  double _searchMs = 0;

  final _keyword = TextEditingController(text: 'garlic tomato');
  String _diet = _all;
  String _timeBand = _all;
  String _cuisine = _all;
  double _alpha = 0.5;
  final double _targetCalories = 400;
  final double _targetProtein = 25;
  final double _targetMinutes = 30;

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
      dirName: 'waffle_demo_recipes',
      schema: _recipeSchema,
      dimension: 3,
      metric: WaffleMetric.euclidean,
    );
    if (db.count() == 0) {
      setState(() => _status = 'Seeding 60 recipes...');
      await db.insertBatch(_seedRecipes()
          .map((r) => WaffleRecord(
                id: r.id,
                vector: r.profile,
                text: '${r.title} ${r.ingredients}',
                payload: {
                  'diet': r.diet,
                  'timeBand': _bandFor(r.minutes),
                  'cuisine': r.cuisine,
                  'calories': r.calories,
                  'title': r.title,
                  'minutes': r.minutes,
                },
              ))
          .toList());
      await db.flush();
    }
    if (!mounted) return;
    setState(() {
      _db = db;
      _ready = true;
      _status = '${db.count()} recipes ready';
    });
    _run();
  }

  void _run() {
    final db = _db;
    if (db == null) return;
    final keyword = _keyword.text.trim();
    final filters = <WaffleFilter>[
      if (_diet != _all) WaffleEqFilter('diet', _diet),
      if (_timeBand != _all) WaffleEqFilter('timeBand', _timeBand),
      if (_cuisine != _all) WaffleEqFilter('cuisine', _cuisine),
    ];
    final sw = Stopwatch()..start();
    final hits = db.search(
      vector: Float32List.fromList([
        (_targetCalories / 1200.0).clamp(0.0, 1.0),
        (_targetProtein / 60.0).clamp(0.0, 1.0),
        (_targetMinutes / 120.0).clamp(0.0, 1.0),
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
        appBar: AppBar(title: const Text('Recipes')),
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
      appBar: AppBar(title: const Text('Recipes')),
      body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _keyword,
                decoration: const InputDecoration(
                  labelText: 'Ingredients (BM25)',
                  hintText: 'e.g. garlic tomato',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _diet,
                      decoration: const InputDecoration(labelText: 'Diet'),
                      items: [_all, ..._diets]
                          .map((d) =>
                              DropdownMenuItem(value: d, child: Text(d)))
                          .toList(),
                      onChanged: (v) => setState(() => _diet = v ?? _all),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _cuisine,
                      decoration: const InputDecoration(labelText: 'Cuisine'),
                      items: [_all, ..._cuisines]
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) => setState(() => _cuisine = v ?? _all),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _timeBand,
                      decoration: const InputDecoration(labelText: 'Time'),
                      items: const [_all, 'quick', 'medium', 'long']
                          .map((t) =>
                              DropdownMenuItem(value: t, child: Text(t)))
                          .toList(),
                      onChanged: (v) => setState(() => _timeBand = v ?? _all),
                    ),
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
              return ListTile(
                dense: true,
                title: Text(h.id),
                subtitle: Text(h.payloadJson ?? '{}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text(
                  's=${h.score.toStringAsFixed(3)}\nd=${h.distance?.toStringAsFixed(3) ?? '-'}',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall,
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
