<h1 align="center">Waffle-DB</h1>
<p align="center">
  <img src="https://socialify.git.ci/MostafaSensei106/Waffle-DB/image?custom_language=Rust&font=KoHo&language=1&logo=https%3A%2F%2Favatars.githubusercontent.com%2Fu%2F138288138%3Fv%3D4&name=1&owner=1&pattern=Floating+Cogs&theme=Light" alt="Banner">
</p>

<p align="center">
  <strong>An advanced, high performance local vector database for Flutter, powered by Rust and HNSW graph indexing.</strong><br>
  Deliver <i>workstation grade</i> vector search, <i>1536-bit embedding support</i>, and <i>real-time similarity matching</i> in your local apps.
</p>

<p align="center">
  <a href="#-why-choose-waffle-db">Why?</a> •
  <a href="#-key-features">Key Features</a> •
  <a href="#-installation">Installation</a> •
  <a href="#-basic-usage">Basic Usage</a> •
  <a href="#-advanced-usage">Advanced Usage</a> •
  <a href="#-contributing">Contributing</a>
</p>

---

## 🤔 Why Choose Waffle-DB?
 
> In AI apps. Your app needs fast similarity search, not just linear scans.

Most local databases in Flutter are designed for standard JSON or SQL data. They lack the mathematical context needed for vector similarity and AI embeddings. A developer needs to index vectors, run k-NN queries in real-time, and scale to 100,000+ embeddings without UI stutter. Pure Dart vector parsers struggle with the sheer size of 1536-d volumetric data, leading to memory crashes and frozen screens.

### 📊 How we compare

| Feature | Standard Local DB | Pure Dart Vector DB | **Waffle-DB** |
| :--- | :---: | :---: | :--- |
| **Parsing Engine** | SQLite / Hive | Dart | **🚀 High-Perf Rust Native Core** |
| **Indexing Precision** | Linear Scan | Linear / LSH | **✅ HNSW Graph (Native)** |
| **Memory Efficiency** | 🔴 High | 🔴 High | **🔋 Zero-Copy FFI Buffers** |
| **UI Responsiveness** | ✅ | ⚠️ | **⚡ Zero UI-Thread Blocking** |
| **Detailed Metadata** | ❌ | ✅ | **🩺 Full Metadata Access** |
| **OpenAI Ready**| ❌ | ❌ | **📈 Native 1536d / 4096d Support** |

---

## 📦 Installation

> [!TIP]
> **Don't worry about the "Rust Core"!**
> Adding **Waffle-DB** to your project is designed to be as simple as adding any other Flutter package. While it uses a high-performance Rust engine, you don't need to be a Rust expert or manage complex builds manually. You just install the language once, and the library handles all the heavy lifting, compiling itself automatically for whatever platform (Android, iOS, macOS, Windows, Linux) or architecture you are targeting.

### 1. Prerequisites (The Rust Toolchain)

Since this library uses a high-speed bridge to connect Flutter and Rust, you need the Rust compiler installed on your development machine.

- **Windows**: Download and run [rustup-init.exe](https://rustup.rs).
- **macOS / Linux**: Run the following command in your terminal:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

> [!IMPORTANT]
> Once Rust is installed, the build system will automatically detect your Flutter target and compile the Rust core into a high-performance native shared library. You only need to set this up once!

### 2. Add the Dependency

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  waffle_db: ^0.0.1
```

---

## 🚀 Basic Usage

### 1. Initialization

Initialize the library in your `main()` function before starting the app.

```dart
import 'package:flutter/material.dart';
import 'package:waffle_db/waffle_db.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the native Rust binary into memory
  await RustLib.init();
  
  runApp(const MyApp());
}
```

### 2. Configuration & Opening the Database

Configure and open your high-speed vector store:

```dart
import 'dart:typed_data';
import 'package:waffle_db/waffle_db.dart';
import 'package:path_provider/path_provider.dart';

Future<void> runVectorStore() async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = '${dir.path}/my_vectors';

  final config = WaffleConfig(
    dimension: 128,
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
  
  final db = await WaffleDatabase.open(config);
}
```

### 3. Inserting Data (Single & Batch)

You can insert vectors individually or in batches. Batch insertion is highly recommended for inserting multiple vectors as it uses Rayon-powered parallel processing.

**Single Insert:**
```dart
await db.insert(
  'unique_id_1',
  Float32List.fromList([0.1, 0.2, ...]),
  metadata: utf8.encode('{"name": "Item 1"}'), // Optional arbitrary bytes
);
```

**Batch Insert:**
```dart
final records = [
  WaffleRecord.fromList(id: 'id_1', vector: [0.1, 0.2, ...]),
  WaffleRecord.fromList(id: 'id_2', vector: [0.3, 0.4, ...]),
];
await db.insertBatch(records);
```

### 4. Querying & Query Builder

WaffleDB offers two ways to query data: the basic `query` method and the fluent `WaffleQueryBuilder`.

**Basic Query:**
Returns the `k` nearest neighbors.
```dart
final results = db.query(queryVector, k: 5);
for (var result in results) {
  print('Found ${result.id} with distance ${result.distance}');
}
```

**Query Builder (Advanced filtering):**
The query builder allows more flexible filtering and tuning per-query.
```dart
final results = await WaffleQueryBuilder(db)
    .withVector(queryVector)
    .limit(10)          // k nearest neighbors
    .efSearch(64)       // override efSearch for higher recall
    .threshold(0.5)     // only return results with distance <= 0.5
    .includeMetadata(true) // Set to false to avoid disk I/O and speed up queries
    .execute();
```

#### Fluent API Methods Reference

| Method | Description |
| :--- | :--- |
| `withVector(Float32List vector)` | Sets the query vector as a `Float32List`. Required before calling `execute()`. |
| `withVectorList(List<double> vector)` | Convenience method to set the query vector from a standard Dart `List<double>`. |
| `limit(int n)` | Sets the maximum number of nearest neighbors to return (default is `10`). |
| `threshold(double t)` | Sets a maximum distance threshold. Results with a distance greater than `t` are excluded. Default is `0.0` (no threshold). |
| `efSearch(int ef)` | Overrides the `efSearch` config for this query. Higher values increase accuracy (recall) but reduce speed. Pass `0` to use the default config. |
| `includeMetadata(bool include)` | Defines whether to fetch metadata (default: `true`). Disabling this speeds up queries by avoiding disk I/O when only IDs and distances are needed. |
| `execute()` | Executes the configured query asynchronously and returns a `Future<List<WaffleQueryResult>>`. |

---

## 🔬 Advanced Usage

### Namespacing with `WaffleCollection`

If you want to logically separate data (e.g., "users" vs "documents") inside the same database, you can use Collections. They handle ID namespacing (`collectionName::id`) automatically.

```dart
final documents = WaffleCollection(db, 'documents');

// Adding to a collection
await documents.add('doc1', queryVector);
await documents.addBatch([...]);

// Searching exclusively within a collection
final searchResults = await documents.search(queryVector, topK: 5);
```

### Managing Data (CRUD Operations)

WaffleDB provides full support for managing records beyond basic insert and query.

```dart
// Check total elements
final count = db.count();

// Retrieve all IDs
final allIds = db.getAllIds();

// Get the original vector or metadata
final vector = db.getVector('unique_id_1');
final metadata = db.getMetadata('unique_id_1');

// Delete a vector
await db.delete('unique_id_1');

// Force flush all pending writes to disk
await db.flush();

// Close the database safely
await db.close();
```

### Dependency Injection (DI) Architecture

For enterprise apps, inject a custom `VectorStoreService` to handle different embedding backends (Local, OpenAI, etc.).

```dart
// 1. Define the service with a specific database instance
final service = VectorStoreService(db: myWaffleDbInstance);

// 2. Inject into the controller or BLOC
final controller = SearchController(vectorStore: service);
```

### High-Dimensional Filtering & Metadata

If you want to filter search results beyond simple distance metrics, you can store structured data alongside your vectors.

```dart
// Insert with metadata
await db.insert(
  'product-42',
  vector,
  metadata: utf8.encode(jsonEncode({'category': 'electronics', 'price': 299})),
);

// Query and decode
final results = await db.query(vector, k: 5);
for (var res in results) {
  final meta = jsonDecode(utf8.decode(res.metadata));
  if (meta['category'] == 'electronics') {
    print('Found electronic item: ${res.id}');
  }
}
```

---

## ⚡ Performance Benchmarks

The **Waffle-DB** library is meticulously optimized for both blistering speed and strict memory efficiency.

### 📊 Pure Rust Scaling Benchmarks (OpenAI 1536-d Vectors on Desktop/Server)

Stress tested the core engine scaling up to **100,000** OpenAI-sized embeddings (1536 dimensions). At this scale, the index holds roughly ~600MB of pure vector data.

| Elements (N) | Query Latency | Open/Restore Time | Insert Latency |
| :--- | :--- | :--- | :--- |
| **1,000** | ~0.76 ms | ~11.64 ms | ~0.97 ms |
| **10,000** | ~1.71 ms | ~98.38 ms | ~2.60 ms |
| **50,000** | ~2.17 ms | ~497.96 ms | ~3.63 ms |
| **100,000** | **~2.17 ms** | **~1.66 s** | **~4.27 ms** |

> **Key Takeaway**: Query performance stays virtually constant around **~2ms** even as the database balloons to 100,000 high-dimensional points. This is workstation-grade performance running natively on your local device.

### 📱 On-Device Edge Benchmarks (Mobile Snapdragon/Apple Silicon 128-d Vectors)

For smaller vector dimensions typical in local mobile models (e.g., MobileNet, lightweight text embeddings), Waffle-DB flies on mobile devices:

| Operation | Total End-to-End Latency (Dart) |
| :--- | :--- |
| **Query (k=20, N=500)** | **~396 µs** |
| **Query (k=50, ef=128)** | **~587 µs** |
| **Single Insert** | **~200 µs** |

### 📊 End-to-End Dart Performance (1536-d Vectors)

Testing the full pipeline from Dart -> Rust -> Dart using heavy **1536-dimensional** vectors. With new `Sync` architecture.

| Operation | Total End-to-End Latency (Dart) |
| :--- | :--- |
| **Query (k=10, N=1,000)** | **~2.59 ms** |
| **Single Insert** | **~1.28 ms** |
| **GetVector (By ID)** | **~56.0 µs** |
| **GetMetadata (By ID)** | **~41.0 µs** |
| **Delete** | **~786.0 µs** |
| **Count / GetAllIds** | **~0.1 - 1.1 ms** |

---

## 🤝 Contributing

Contributions are welcome! Here’s how to get started:

1.  Fork the repository.
2.  Create a new branch:
    `git checkout -b feature/YourFeature`
3.  Commit your changes:
    `git commit -m "Add amazing feature"`
4.  Push to your branch:
    `git push origin feature/YourFeature`
5.  Open a pull request.

---
## 📜 License

This project is licensed under the **GPL-3.0 License**.
See the [LICENSE](LICENSE) file for full details.

<p align="center">
  Made with ❤️ by <a href="https://github.com/MostafaSensei106">MostafaSensei106</a>
</p>
