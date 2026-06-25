import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const WaffleApp());
}

// ═══════════════════════════════════════════════════════════════════
//  App & Theme
// ═══════════════════════════════════════════════════════════════════

class WaffleApp extends StatelessWidget {
  const WaffleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaffleDB Benchmark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorSchemeSeed: const Color(0xFFE8A838),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const BenchmarkPage(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Data Model
// ═══════════════════════════════════════════════════════════════════

enum OpStatus { idle, running, done, error }

class OpResult {
  final String name;
  final String icon;
  final Duration elapsed;
  final String detail;
  final OpStatus status;
  final String? error;

  const OpResult({
    required this.name,
    required this.icon,
    this.elapsed = Duration.zero,
    this.detail = '',
    this.status = OpStatus.idle,
    this.error,
  });

  OpResult copyWith({
    Duration? elapsed,
    String? detail,
    OpStatus? status,
    String? error,
  }) {
    return OpResult(
      name: name,
      icon: icon,
      elapsed: elapsed ?? this.elapsed,
      detail: detail ?? this.detail,
      status: status ?? this.status,
      error: error,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Benchmark Page
// ═══════════════════════════════════════════════════════════════════

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage>
    with TickerProviderStateMixin {
  static const int dim = 128;
  static const int vectorCount = 500;

  WaffleDatabase? _db;
  bool _running = false;
  double _progress = 0.0;
  String _statusText = 'Tap ▶ Run All to start';
  Duration _totalTime = Duration.zero;

  // All operations
  late List<OpResult> _results;

  @override
  void initState() {
    super.initState();
    _results = [
      const OpResult(name: 'Open DB', icon: '🔓'),
      const OpResult(name: 'Single Insert ×10', icon: '➕'),
      const OpResult(name: 'Batch Insert ×$vectorCount', icon: '📦'),
      const OpResult(name: 'Count', icon: '🔢'),
      const OpResult(name: 'Query k=5', icon: '🔍'),
      const OpResult(name: 'Query k=20', icon: '🔎'),
      const OpResult(name: 'Query k=50 ef=128', icon: '🎯'),
      const OpResult(name: 'Get Vector', icon: '📐'),
      const OpResult(name: 'Get Metadata', icon: '🏷️'),
      const OpResult(name: 'Get All IDs', icon: '📋'),
      const OpResult(name: 'Delete ×5', icon: '🗑️'),
      const OpResult(name: 'Flush', icon: '💾'),
      const OpResult(name: 'Cosine Similarity', icon: '📊'),
      const OpResult(name: 'Close & Reopen', icon: '🔄'),
      const OpResult(name: 'Query after reopen', icon: '✅'),
      const OpResult(name: 'Close DB', icon: '🔒'),
    ];
  }

  Float32List _randomVector(int seed) {
    final rng = Random(seed);
    final v = Float32List(dim);
    for (int i = 0; i < dim; i++) {
      v[i] = rng.nextDouble().toDouble();
    }
    return v;
  }

  Future<Duration> _timed(Future<void> Function() fn) async {
    final sw = Stopwatch()..start();
    await fn();
    sw.stop();
    return sw.elapsed;
  }

  void _updateOp(int index, OpResult result) {
    setState(() {
      _results[index] = result;
    });
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _progress = 0.0;
      _statusText = 'Running...';
      _totalTime = Duration.zero;
      for (int i = 0; i < _results.length; i++) {
        _results[i] = _results[i].copyWith(
          elapsed: Duration.zero,
          detail: '',
          status: OpStatus.idle,
          error: null,
        );
      }
    });

    final totalSteps = _results.length;
    int step = 0;
    final totalSw = Stopwatch()..start();

    Future<void> run(int i, Future<void> Function() fn) async {
      _updateOp(i, _results[i].copyWith(status: OpStatus.running));
      try {
        final d = await _timed(fn);
        _updateOp(
          i,
          _results[i].copyWith(
            elapsed: d,
            status: OpStatus.done,
            detail: _formatDuration(d),
          ),
        );
      } catch (e) {
        _updateOp(
          i,
          _results[i].copyWith(status: OpStatus.error, error: e.toString()),
        );
      }
      step++;
      setState(() {
        _progress = step / totalSteps;
        _statusText = 'Step $step / $totalSteps';
      });
    }

    final dir = await getApplicationDocumentsDirectory();
    final dbPath =
        '${dir.path}/waffle_example_${DateTime.now().millisecondsSinceEpoch}';

    // 0 — Open DB
    await run(0, () async {
      final config = WaffleConfig(
        dimension: dim,
        path: dbPath,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 100000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(32 * 1024 * 1024),
        workerThreads: 4,
      );
      _db = await WaffleDatabase.open(config);
    });

    if (_db == null) {
      setState(() {
        _running = false;
        _statusText = 'Failed to open DB';
      });
      return;
    }
    final db = _db!;

    // 1 — Single Insert ×10
    await run(1, () async {
      for (int i = 0; i < 10; i++) {
        await db.insert(
          'single-$i',
          _randomVector(i),
          metadata: Uint8List.fromList([i, i + 1, i + 2]),
        );
      }
    });
    _updateOp(
      1,
      _results[1].copyWith(detail: '${_results[1].detail} (10 vectors)'),
    );

    // 2 — Batch Insert
    await run(2, () async {
      final records = List.generate(
        vectorCount,
        (i) => WaffleRecord(
          id: 'batch-$i',
          vector: _randomVector(i + 100),
          metadata: Uint8List.fromList(List.generate(32, (j) => (i + j) % 256)),
        ),
      );
      await db.insertBatch(records);
    });
    _updateOp(
      2,
      _results[2].copyWith(
        detail: '${_results[2].detail} ($vectorCount vectors)',
      ),
    );

    // 3 — Count
    await run(3, () async {
      final c = await db.count();
      _updateOp(3, _results[3].copyWith(detail: '$c vectors'));
    });

    // 4 — Query k=5
    await run(4, () async {
      final results = await db.query(_randomVector(0), k: 5);
      _updateOp(
        4,
        _results[4].copyWith(
          detail:
              '${results.length} results, best=${results.isNotEmpty ? results.first.distance.toStringAsFixed(4) : "N/A"}',
        ),
      );
    });

    // 5 — Query k=20
    await run(5, () async {
      final results = await db.query(_randomVector(1), k: 20);
      _updateOp(5, _results[5].copyWith(detail: '${results.length} results'));
    });

    // 6 — Query k=50 ef=128
    await run(6, () async {
      final results = await db.query(_randomVector(2), k: 50, efSearch: 128);
      _updateOp(6, _results[6].copyWith(detail: '${results.length} results'));
    });

    // 7 — Get Vector
    await run(7, () async {
      final v = await db.getVector('batch-0');
      _updateOp(
        7,
        _results[7].copyWith(
          detail: v != null ? 'dim=${v.length}' : 'not found',
        ),
      );
    });

    // 8 — Get Metadata
    await run(8, () async {
      final m = await db.getMetadata('batch-0');
      _updateOp(
        8,
        _results[8].copyWith(
          detail: m != null ? '${m.length} bytes' : 'not found',
        ),
      );
    });

    // 9 — Get All IDs
    await run(9, () async {
      final ids = await db.getAllIds();
      _updateOp(9, _results[9].copyWith(detail: '${ids.length} IDs'));
    });

    // 10 — Delete ×5
    await run(10, () async {
      int deleted = 0;
      for (int i = 0; i < 5; i++) {
        if (await db.delete('batch-$i')) deleted++;
      }
      _updateOp(10, _results[10].copyWith(detail: '$deleted removed'));
    });

    // 11 — Flush
    await run(11, () async {
      await db.flush();
    });

    // 12 — Cosine Similarity
    await run(12, () async {
      final a = List<double>.generate(dim, (i) => i * 0.01);
      final b = List<double>.generate(dim, (i) => (dim - i) * 0.01);
      final sim = await cosineSimilarity(a: a, b: b);
      _updateOp(
        12,
        _results[12].copyWith(detail: 'sim=${sim.toStringAsFixed(4)}'),
      );
    });

    // 13 — Close & Reopen
    await run(13, () async {
      await db.close();
      final config = WaffleConfig(
        dimension: dim,
        path: dbPath,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.cosine,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 100000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(32 * 1024 * 1024),
        workerThreads: 4,
      );
      _db = await WaffleDatabase.open(config);
      final c = await _db!.count();
      _updateOp(13, _results[13].copyWith(detail: 'Reopened, $c vectors'));
    });

    // 14 — Query after reopen
    await run(14, () async {
      final results = await _db!.query(_randomVector(0), k: 5);
      _updateOp(
        14,
        _results[14].copyWith(
          detail:
              '${results.length} results, best=${results.isNotEmpty ? results.first.distance.toStringAsFixed(4) : "N/A"}',
        ),
      );
    });

    // 15 — Close DB
    await run(15, () async {
      await _db!.close();
      _db = null;
    });

    totalSw.stop();
    setState(() {
      _running = false;
      _totalTime = totalSw.elapsed;
      _statusText = 'Done in ${_formatDuration(totalSw.elapsed)}';
    });
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds == 0) return '${d.inMicroseconds}µs';
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
  }

  // ─────────────────────────────────────────────────────────────
  //  UI
  // ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final amber = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Header ──
          SliverAppBar(
            expandedHeight: 140,
            pinned: true,
            backgroundColor: const Color(0xFF161B22),
            flexibleSpace: FlexibleSpaceBar(
              centerTitle: true,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('🧇', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 8),
                  Text(
                    'WaffleDB',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: amber,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Benchmark',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white54,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Progress + Run Button ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                children: [
                  // Stats bar
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: amber.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        _statChip('dim', '$dim', amber),
                        const SizedBox(width: 12),
                        _statChip('vectors', '$vectorCount', amber),
                        const Spacer(),
                        if (_totalTime > Duration.zero)
                          _statChip(
                            'total',
                            _formatDuration(_totalTime),
                            amber,
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Progress bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _running ? _progress : (_progress > 0 ? 1.0 : 0),
                      minHeight: 6,
                      backgroundColor: const Color(0xFF21262D),
                      color: amber,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _statusText,
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 12),

                  // Run button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _running ? null : _runAll,
                      icon: _running
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 24),
                      label: Text(
                        _running ? 'Running...' : '▶  Run All Benchmarks',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: amber,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),

          // ── Results List ──
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    _OpCard(result: _results[index], index: index),
                childCount: _results.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Operation Card Widget
// ═══════════════════════════════════════════════════════════════════

class _OpCard extends StatelessWidget {
  final OpResult result;
  final int index;

  const _OpCard({required this.result, required this.index});

  @override
  Widget build(BuildContext context) {
    final amber = Theme.of(context).colorScheme.primary;

    Color statusColor;
    IconData statusIcon;
    switch (result.status) {
      case OpStatus.idle:
        statusColor = Colors.white24;
        statusIcon = Icons.circle_outlined;
        break;
      case OpStatus.running:
        statusColor = Colors.blueAccent;
        statusIcon = Icons.sync_rounded;
        break;
      case OpStatus.done:
        statusColor = const Color(0xFF3FB950);
        statusIcon = Icons.check_circle_rounded;
        break;
      case OpStatus.error:
        statusColor = const Color(0xFFF85149);
        statusIcon = Icons.error_rounded;
        break;
    }

    // Time badge color based on speed
    Color timeBadgeColor = amber;
    final ms = result.elapsed.inMilliseconds;
    if (ms < 5) {
      timeBadgeColor = const Color(0xFF3FB950); // green = fast
    } else if (ms < 50) {
      timeBadgeColor = const Color(0xFF58A6FF); // blue = good
    } else if (ms < 200) {
      timeBadgeColor = amber; // amber = okay
    } else {
      timeBadgeColor = const Color(0xFFF85149); // red = slow
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: result.status == OpStatus.running
            ? const Color(0xFF1C2333)
            : const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: result.status == OpStatus.running
              ? Colors.blueAccent.withValues(alpha: 0.4)
              : result.status == OpStatus.error
              ? const Color(0xFFF85149).withValues(alpha: 0.3)
              : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          // Index badge
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Icon
          Text(result.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),

          // Name + detail
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.name,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (result.detail.isNotEmpty)
                  Text(
                    result.detail,
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                if (result.error != null)
                  Text(
                    result.error!,
                    style: TextStyle(
                      color: const Color(0xFFF85149),
                      fontSize: 11,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          // Time badge
          if (result.status == OpStatus.done) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: timeBadgeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _formatDuration(result.elapsed),
                style: TextStyle(
                  color: timeBadgeColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ] else if (result.status == OpStatus.running) ...[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.blueAccent,
              ),
            ),
          ] else ...[
            Icon(statusIcon, size: 18, color: statusColor),
          ],
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds == 0) return '${d.inMicroseconds}µs';
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
  }
}
