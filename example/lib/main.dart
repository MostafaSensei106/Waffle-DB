import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaffleDB Simple Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  WaffleDatabase? _db;
  WaffleCollection? _collection;
  String _log = 'App started...\n';

  void _addLog(String msg) {
    setState(() {
      _log += '$msg\n';
    });
  }

  Future<void> _initDb() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = '${dir.path}/waffle_simple_db';
      
      final config = WaffleConfig(
        dimension: 3,
        path: dbPath,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 1000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(8 * 1024 * 1024),
        workerThreads: 2,
      );

      _db = await WaffleDatabase.open(config);
      _collection = WaffleCollection(_db!, 'my_collection');
      _addLog('Database initialized at $dbPath');
    } catch (e) {
      _addLog('Error initializing DB: $e');
    }
  }

  Future<void> _testInsertAndCount() async {
    if (_db == null) return _addLog('DB not initialized');
    try {
      await _db!.insert(
        'item1',
        Float32List.fromList([0.1, 0.2, 0.3]),
        metadata: utf8.encode('Metadata for item1'),
      );
      _addLog('Inserted item1');
      
      final records = [
        WaffleRecord.fromList(id: 'batch1', vector: [0.2, 0.3, 0.4]),
        WaffleRecord.fromList(id: 'batch2', vector: [0.5, 0.1, 0.9]),
      ];
      await _db!.insertBatch(records);
      _addLog('Batch inserted 2 items');

      final count = _db!.count();
      _addLog('Total DB count: $count');
    } catch (e) {
      _addLog('Error inserting: $e');
    }
  }

  Future<void> _testQueries() async {
    if (_db == null) return _addLog('DB not initialized');
    try {
      // Basic query
      final results = _db!.query(Float32List.fromList([0.1, 0.2, 0.3]), k: 2);
      _addLog('Basic Query returned ${results.length} results:');
      for (var r in results) {
        _addLog(' - ID: ${r.id}, Distance: ${r.distance}');
      }

      // Query Builder
      final builderResults = await WaffleQueryBuilder(_db!)
          .withVectorList([0.5, 0.1, 0.9])
          .limit(3)
          .efSearch(64)
          .includeMetadata(true)
          .execute();
          
      _addLog('Query Builder returned ${builderResults.length} results:');
      for (var r in builderResults) {
        _addLog(' - ID: ${r.id}, Distance: ${r.distance}');
      }
    } catch (e) {
      _addLog('Error querying: $e');
    }
  }

  Future<void> _testDataRetrieval() async {
    if (_db == null) return _addLog('DB not initialized');
    try {
      final ids = _db!.getAllIds();
      _addLog('All IDs: $ids');

      if (ids.isNotEmpty) {
        final firstId = ids.first;
        final vector = _db!.getVector(firstId);
        final metaBytes = _db!.getMetadata(firstId);
        String metaStr = metaBytes != null && metaBytes.isNotEmpty ? utf8.decode(metaBytes) : 'null';
        _addLog('Data for $firstId: Vector=$vector, Meta=$metaStr');
      }
    } catch (e) {
      _addLog('Error retrieving data: $e');
    }
  }

  Future<void> _testCollection() async {
    if (_collection == null) return _addLog('Collection not initialized');
    try {
      await _collection!.add('col_item1', Float32List.fromList([0.9, 0.8, 0.7]));
      _addLog('Added col_item1 to collection');
      
      final results = await _collection!.search(Float32List.fromList([0.9, 0.8, 0.7]), topK: 1);
      _addLog('Collection search returned ${results.length} results:');
      for (var r in results) {
        _addLog(' - ID: ${r.id}, Distance: ${r.distance}');
      }
    } catch (e) {
      _addLog('Error in collection: $e');
    }
  }

  Future<void> _testDeleteAndFlush() async {
    if (_db == null) return _addLog('DB not initialized');
    try {
      final ids = _db!.getAllIds();
      if (ids.isNotEmpty) {
        final idToRemove = ids.first;
        final deleted = await _db!.delete(idToRemove);
        _addLog('Deleted $idToRemove: $deleted');
      }
      
      await _db!.flush();
      _addLog('Flushed DB to disk');
    } catch (e) {
      _addLog('Error deleting/flushing: $e');
    }
  }

  Future<void> _closeDb() async {
    if (_db == null) return _addLog('DB not initialized');
    try {
      await _db!.close();
      _addLog('DB Closed');
      _db = null;
      _collection = null;
    } catch (e) {
      _addLog('Error closing DB: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('WaffleDB Simple Example'),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(onPressed: _initDb, child: const Text('1. Init DB')),
                  ElevatedButton(onPressed: _testInsertAndCount, child: const Text('2. Test Insert & Count')),
                  ElevatedButton(onPressed: _testQueries, child: const Text('3. Test Queries (Basic & Builder)')),
                  ElevatedButton(onPressed: _testDataRetrieval, child: const Text('4. Test Data Retrieval')),
                  ElevatedButton(onPressed: _testCollection, child: const Text('5. Test Collection')),
                  ElevatedButton(onPressed: _testDeleteAndFlush, child: const Text('6. Test Delete & Flush')),
                  ElevatedButton(onPressed: _closeDb, child: const Text('7. Close DB')),
                  ElevatedButton(
                    onPressed: () => setState(() => _log = 'Log cleared...\n'), 
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                    child: const Text('Clear Log', style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8.0),
              color: Colors.black87,
              child: SingleChildScrollView(
                child: Text(
                  _log,
                  style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
