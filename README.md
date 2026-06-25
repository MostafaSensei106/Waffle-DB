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

The **Waffle-DB** library is meticulously optimized for both blistering speed and strict memory efficiency.

### 📊 Pure Rust Scaling Benchmarks (1536-d Vectors)

Stress tested the core engine scaling up to **100,000** OpenAI-sized embeddings (1536 dimensions). At this scale, the index holds roughly ~600MB of pure vector data.

| Elements (N) | Query Latency | Open/Restore Time | Insert Latency |
| :--- | :--- | :--- | :--- |
| **1,000** | ~0.76 ms | ~11.64 ms | ~0.97 ms |
| **10,000** | ~1.71 ms | ~98.38 ms | ~2.60 ms |
| **50,000** | ~2.17 ms | ~497.96 ms | ~3.63 ms |
| **100,000** | **~2.17 ms** | **~1.66 s** | **~4.27 ms** |

> **Key Takeaway**: Query performance stays virtually constant around **~2ms** even as the database balloons to 100,000 high-dimensional points. This is workstation-grade performance running natively on your local device.

### 📊 End-to-End Dart Performance 

Testing the full pipeline from Dart -> Rust -> Dart using **1536-dimensional** vectors. With new `Sync` architecture.

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
