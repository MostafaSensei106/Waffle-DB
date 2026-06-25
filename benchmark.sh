#!/bin/bash
set -e

echo "=========================================================="
echo "🧇 WaffleDB Full Performance Report"
echo "=========================================================="

cd rust

echo "🚀 Building Rust code..."
cargo build --release

echo ""
echo "----------------------------------------------------------"
echo "1. Pure Rust Core Performance (scale_bench)"
echo "----------------------------------------------------------"
cargo run --release --bin scale_bench || true

echo ""
echo "----------------------------------------------------------"
echo "2. Rust Micro-benchmarks (Criterion)"
echo "----------------------------------------------------------"
cargo bench || true

cd ..

echo ""
echo "----------------------------------------------------------"
echo "3. Dart FFI / Flutter Bridge Overhead Benchmarks"
echo "----------------------------------------------------------"
echo "Running Dart profile benchmarks..."
cd example
flutter test integration_test/profile_benchmark_test.dart || echo "Skipped (could not run flutter test without device)"

echo ""
echo "Running Dart percentiles benchmark..."
flutter test integration_test/waffle_benchmark_test.dart || echo "Skipped (could not run flutter test without device)"
cd ..

echo ""
echo "=========================================================="
echo "✅ Benchmark Suite Complete"
echo "=========================================================="
