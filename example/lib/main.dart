import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WaffleDB.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Waffle-DB Color Search',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
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
  bool _isInitializing = true;
  int _totalColors = 0;
  String? _dbPath;

  // Generation state
  bool _isGenerating = false;
  double _generationProgress = 0.0;
  String _generationMessage = '';
  int _selectedCount = 1000000; // Default to 1 Million colors

  final List<int> _colorCountOptions = [10000, 100000, 1000000, 12000000];

  // Target search color
  double _targetRed = 0.0;
  double _targetGreen = 150.0;
  double _targetBlue = 255.0;
  int _k = 150;

  // Results state
  List<WaffleQueryResult> _searchResults = [];
  double? _searchTimeMs;

  @override
  void initState() {
    super.initState();
    _initDatabase();
  }

  Future<void> _initDatabase() async {
    setState(() {
      _isInitializing = true;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      _dbPath = '${dir.path}/waffle_color_db';

      final config = WaffleConfig(
        dimension: 3,
        path: _dbPath!,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.euclidean, // Euclidean is perfect for RGB space
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 13000000, // Support up to 12M+ colors
        useQuantization: false,
        cacheSizeBytes: BigInt.from(64 * 1024 * 1024), // 64 MB cache
        workerThreads: 4,
      );

      _db = await WaffleDatabase.open(config);
      _totalColors = _db!.count();
    } catch (e) {
      _showErrorSnackBar('Error opening database: $e');
    } finally {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  Future<void> _rebuildDatabase() async {
    if (_isGenerating || _db == null || _dbPath == null) return;

    setState(() {
      _isGenerating = true;
      _generationProgress = 0.0;
      _generationMessage = 'Preparing directory...';
    });

    try {
      // 1. Close current DB
      await _db!.close();
      _db = null;

      // 2. Clean directory
      final dir = Directory(_dbPath!);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }

      // 3. Open new clean DB
      final config = WaffleConfig(
        dimension: 3,
        path: _dbPath!,
        graphConfig: const WaffleGraphConfig(
          m: 16,
          metric: WaffleMetric.euclidean,
          efConstruction: 64,
          efSearch: 32,
        ),
        maxElements: 13000000,
        useQuantization: false,
        cacheSizeBytes: BigInt.from(64 * 1024 * 1024),
        workerThreads: 4,
      );
      _db = await WaffleDatabase.open(config);

      // 4. Generate colors in chunks of 25,000 to keep UI responsive
      final random = Random();
      final total = _selectedCount;
      const chunkSize = 25000;
      int inserted = 0;

      while (inserted < total) {
        final currentChunk = min(chunkSize, total - inserted);
        final records = <WaffleRecord>[];

        for (int i = 0; i < currentChunk; i++) {
          final r = random.nextDouble();
          final g = random.nextDouble();
          final b = random.nextDouble();

          final rInt = (r * 255).toInt();
          final gInt = (g * 255).toInt();
          final bInt = (b * 255).toInt();

          // Encode RGB in ID to retrieve values instantly on query
          records.add(
            WaffleRecord(
              id: 'color_${rInt}_${gInt}_${bInt}_${inserted + i}',
              vector: Float32List.fromList([r, g, b]),
            ),
          );
        }

        await _db!.insertBatch(records);
        inserted += currentChunk;

        setState(() {
          _generationProgress = inserted / total;
          _generationMessage =
              'Generated ${inserted.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')} / ${total.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')} colors...';
        });

        // Yield execution to allow UI rendering
        await Future.delayed(Duration.zero);
      }

      setState(() {
        _generationMessage = 'Flushing database to disk...';
      });
      await _db!.flush();
      _totalColors = _db!.count();
      _searchResults = [];
      _searchTimeMs = null;
    } catch (e) {
      _showErrorSnackBar('Rebuild failed: $e');
    } finally {
      setState(() {
        _isGenerating = false;
      });
    }
  }

  void _searchNearestColors() {
    if (_db == null || _totalColors == 0) {
      _showErrorSnackBar('Database is empty! Please generate colors first.');
      return;
    }

    final queryVector = Float32List.fromList([
      _targetRed / 255.0,
      _targetGreen / 255.0,
      _targetBlue / 255.0,
    ]);

    final sw = Stopwatch()..start();
    final results = _db!.query(
      queryVector,
      k: _k,
      efSearch: 48, // slightly higher search resolution
      includeMetadata: false,
    );
    sw.stop();

    setState(() {
      _searchResults = results;
      _searchTimeMs = sw.elapsedMicroseconds / 1000.0;
    });
  }

  void _randomizeTargetColor() {
    final random = Random();
    setState(() {
      _targetRed = random.nextInt(256).toDouble();
      _targetGreen = random.nextInt(256).toDouble();
      _targetBlue = random.nextInt(256).toDouble();
    });
    if (_searchResults.isNotEmpty) {
      _searchNearestColors();
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  Color _parseColorFromId(String id) {
    try {
      final parts = id.split('_');
      if (parts.length >= 4 && parts[0] == 'color') {
        final r = int.parse(parts[1]);
        final g = int.parse(parts[2]);
        final b = int.parse(parts[3]);
        return Color.fromARGB(255, r, g, b);
      }
    } catch (_) {}
    return Colors.grey;
  }

  String _parseRgbTextFromId(String id) {
    try {
      final parts = id.split('_');
      if (parts.length >= 4 && parts[0] == 'color') {
        return 'RGB(${parts[1]}, ${parts[2]}, ${parts[3]})';
      }
    } catch (_) {}
    return 'RGB(?, ?, ?)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targetColor = Color.fromARGB(
      255,
      _targetRed.toInt(),
      _targetGreen.toInt(),
      _targetBlue.toInt(),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('🧇 Waffle-DB: Color Semantic Search'),
        centerTitle: true,
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
      ),
      body: _isInitializing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading native database components...'),
                ],
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final isMobile = constraints.maxWidth < 720;
                if (isMobile) {
                  return _buildMobileLayout(theme, targetColor);
                } else {
                  return _buildDesktopLayout(theme, targetColor);
                }
              },
            ),
    );
  }

  Widget _buildMobileLayout(ThemeData theme, Color targetColor) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: const [
              Tab(icon: Icon(Icons.settings), text: 'Setup & Selection'),
              Tab(icon: Icon(Icons.palette), text: 'Search Results'),
            ],
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Tab 1: Configuration & Color Selection
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDatabaseStatusCard(theme),
                      const SizedBox(height: 16),
                      _buildGeneratorSection(theme),
                      const Divider(height: 32),
                      _buildTargetColorSection(theme, targetColor),
                    ],
                  ),
                ),
                // Tab 2: Results Grid
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildResultsHeader(theme),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _buildResultsGrid(theme, crossAxisCount: 3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(ThemeData theme, Color targetColor) {
    return Row(
      children: [
        // Left Panel: Configuration & Generation Controls
        Expanded(
          flex: 3,
          child: Container(
            color: theme.colorScheme.surfaceContainerLow,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDatabaseStatusCard(theme),
                  const SizedBox(height: 16),
                  _buildGeneratorSection(theme),
                  const Divider(height: 32),
                  _buildTargetColorSection(theme, targetColor),
                ],
              ),
            ),
          ),
        ),

        // Right Panel: Results Grid
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildResultsHeader(theme),
                const SizedBox(height: 16),
                Expanded(
                  child: _buildResultsGrid(theme, crossAxisCount: 5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDatabaseStatusCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Database Status',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Stored Elements:'),
                Text(
                  _totalColors.toString().replaceAllMapped(
                        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
                        (Match m) => '${m[1]},',
                      ),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratorSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1. Populate Color Database',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: _selectedCount,
          decoration: const InputDecoration(
            labelText: 'Target Database Size',
            border: OutlineInputBorder(),
          ),
          items: _colorCountOptions.map((count) {
            String label = count.toString();
            if (count == 10000) {
              label = '10,000 (Quick)';
            }
            if (count == 100000) {
              label = '100,000 (Medium)';
            }
            if (count == 1000000) {
              label = '1,000,000 (1 Million)';
            }
            if (count == 12000000) {
              label = '12,000,000 (12 Million)';
            }
            return DropdownMenuItem(
              value: count,
              child: Text(label),
            );
          }).toList(),
          onChanged: _isGenerating
              ? null
              : (val) {
                  if (val != null) {
                    setState(() {
                      _selectedCount = val;
                    });
                  }
                },
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _isGenerating ? null : _rebuildDatabase,
            icon: const Icon(Icons.palette),
            label: const Text('Generate Random Colors'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_isGenerating) ...[
          Text(
            _generationMessage,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: _generationProgress,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _buildTargetColorSection(ThemeData theme, Color targetColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '2. Target Color Selection',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          height: 100,
          decoration: BoxDecoration(
            color: targetColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outline,
              width: 2,
            ),
          ),
          child: Center(
            child: Text(
              'Target Color\nRGB(${_targetRed.toInt()}, ${_targetGreen.toInt()}, ${_targetBlue.toInt()})',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ThemeData.estimateBrightnessForColor(targetColor) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildColorSlider(
          label: 'Red',
          value: _targetRed,
          color: Colors.red,
          onChanged: (val) {
            setState(() {
              _targetRed = val;
            });
          },
        ),
        _buildColorSlider(
          label: 'Green',
          value: _targetGreen,
          color: Colors.green,
          onChanged: (val) {
            setState(() {
              _targetGreen = val;
            });
          },
        ),
        _buildColorSlider(
          label: 'Blue',
          value: _targetBlue,
          color: Colors.blue,
          onChanged: (val) {
            setState(() {
              _targetBlue = val;
            });
          },
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [Text('Nearest Neighbors (k):')],
        ),
        Slider(
          value: _k.toDouble(),
          min: 1,
          max: 200,
          divisions: 199,
          label: '$_k',
          onChanged: (val) {
            setState(() {
              _k = val.toInt();
            });
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _randomizeTargetColor,
                child: const Text('Random'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: _searchResults.isEmpty || _totalColors > 0
                    ? _searchNearestColors
                    : null,
                child: const Text('Search'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResultsHeader(ThemeData theme) {
    if (_searchTimeMs == null) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Query Results',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Card(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 6.0,
            ),
            child: Text(
              'Search completed in ${_searchTimeMs!.toStringAsFixed(3)} ms',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultsGrid(ThemeData theme, {required int crossAxisCount}) {
    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text(
              'Select a target color and click Search\nto find nearest matches in milliseconds!',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.9,
      ),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        final color = _parseColorFromId(result.id);
        final rgbText = _parseRgbTextFromId(result.id);
        final isDark =
            ThemeData.estimateBrightnessForColor(color) == Brightness.dark;

        return Tooltip(
          message:
              '${result.id}\nDistance: ${result.distance.toStringAsFixed(6)}',
          child: Card(
            clipBehavior: Clip.antiAlias,
            color: color,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      CircleAvatar(
                        radius: 10,
                        backgroundColor:
                            isDark ? Colors.white24 : Colors.black26,
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rgbText,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Dist: ${result.distance.toStringAsFixed(4)}',
                        style: TextStyle(
                          fontSize: 9,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildColorSlider({
    required String label,
    required double value,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              value.toInt().toString(),
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: value,
          min: 0,
          max: 255,
          activeColor: color,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
