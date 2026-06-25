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

### 2. Opening the Database and Inserting Vectors

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

  // Insert a single record
  await db.insert(
    'item-1',
    Float32List.fromList(List.filled(128, 0.1)),
    metadata: Uint8List.fromList([1, 2, 3]),
  );

  // Query nearest neighbors
  final results = await db.query(Float32List.fromList(List.filled(128, 0.1)), k: 5);
  for (var res in results) {
    print('Found ${res.id} with distance ${res.distance}');
  }

  await db.close();
}
```

---

## 🔬 Advanced Usage

### Custom Indexing with `WaffleGraphConfig`

You can tune the HNSW index graph parameters for your specific recall vs latency requirements.

```dart
final config = WaffleConfig(
  dimension: 1536, // Perfect for OpenAI embeddings
  path: dbPath,
  graphConfig: const WaffleGraphConfig(
    m: 24, // Higher means better recall, slower indexing
    metric: WaffleMetric.cosine,
    efConstruction: 100, // Search effort during index creation
    efSearch: 64, // Search effort during query
  ),
  maxElements: 500000,
  useQuantization: true, // Compress vectors to save memory
);
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

The **Waffle-DB** library is meticulously optimized for both blistering speed and strict memory efficiency. The following benchmarks were executed to test the **Native Dart Layer** and the **Rust + FFI architecture**. 
The results highlight the massive performance overhead provided by our Rust core.

### 📊 At-a-Glance Summary

### 📊 1536-d Vector Architecture Benchmarks (OpenAI Scale)
We benchmarked the **Native Rust Engine** vs the **End-to-End Dart Layer** using real-world 1536-dimensional vectors (OpenAI embeddings size).

By decoupling metadata fetches and serializing the raw HNSW graph directly to disk via zero-copy mmap, we achieved dramatic speedups:
- **Open+Restore** went from **1.43s** (rebuilding from Sled) down to **~10ms** (mmap graph loading).
- **Queries** avoid full Sled row iterations by using a fast metadata toggle.

| Profile / Metric | Pure Rust Time | FFI / Dart Overhead | Total End-to-End |
| :--- | :--- | :--- | :--- |
| **MOBILE** | | | |
| Single Insert | ~0.043 ms | ~1.030 ms | ~1.062 ms |
| Query (k=10, N=1k) | ~0.490 ms | ~12.931 ms | ~13.689 ms |
| Open+Restore (1k)| ~9.566 ms | N/A | N/A |
| **SERVER** | | | |
| Single Insert | ~0.032 ms | ~2.133 ms | ~2.178 ms |
| Query (k=10, N=1k) | ~1.534 ms | ~36.313 ms | ~37.491 ms |
| Open+Restore (1k)| ~10.245 ms | N/A | N/A |
| **READ-HEAVY** | | | |
| Single Insert | ~0.032 ms | ~1.989 ms | ~2.014 ms |
| Query (k=10, N=1k) | ~1.299 ms | ~36.461 ms | ~38.045 ms |
| Open+Restore (1k)| ~13.817 ms | N/A | N/A |

---

### 🔬 Detailed Deep Dive

#### 🚀 1. The HNSW Persistence Bottleneck (Fixed)
Previously, starting the database required reading all vectors from Sled storage and re-inserting them into the HNSW graph (taking ~1.4s for 1000 vectors). Now, the graph state is saved in raw binary (`.hnsw.graph`) and JSON ID maps are written sequentially, resulting in an **O(1) startup time (~10ms)** regardless of vector size!

#### 🎛️ 2. Workstation-Grade Interaction
Offloading complex math to the Rust core means distance computing doesn't slow down your UI.
* **Rust Native Query:** 10 nearest neighbors out of 1000 (1536-d) takes an average of **0.490 ms**.
* **Zero-Copy Bridge:** Stripping metadata from standard searches reduces FFI and Dart allocation lag to acceptable bounds.

#### 🧽 3. Memory Safety & Full Pipeline
Testing the complete lifecycle ensures there are no memory leaks during extended operations.
* **Metadata Stripping:** The `includeMetadata = false` flag prevents Sled Disk I/O bottlenecks.
* **Concurrency Handling:** Tokio-driven background threads ensure Sled flushes efficiently without pausing the Dart isolate.

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
