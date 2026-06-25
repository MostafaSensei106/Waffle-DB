#!/usr/bin/env python3
import subprocess
import json
import sys

def run_cmd(cmd, cwd):
    print(f"Running: {cmd} in {cwd}...")
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running {cmd}: {result.stderr}")
        sys.exit(1)
    return result.stdout

def main():
    print("🚀 Starting Comprehensive Waffle-DB Benchmarks...")
    print("Testing 'worst-case' 1536-dimensional vectors across all profiles.\n")
    
    # 1. Run Rust Benchmarks
    rust_output = run_cmd("cargo run --release --bin profile_bench", "rust")
    rust_results = {}
    for line in rust_output.split('\n'):
        if line.startswith('{'):
            try:
                data = json.loads(line)
                rust_results[data['profile']] = data
            except:
                pass
                
    # 2. Run Dart Benchmarks
    dart_output = run_cmd("flutter test integration_test/profile_benchmark_test.dart -d linux", "example")
    dart_results = {}
    for line in dart_output.split('\n'):
        if 'BENCHMARK_RESULT_JSON:' in line:
            try:
                json_str = line.split('BENCHMARK_RESULT_JSON:')[1].strip()
                data = json.loads(json_str)
                dart_results[data['profile']] = data
            except Exception as e:
                pass

    profiles = ["Mobile", "Server", "ReadHeavy", "WriteHeavy"]
    
    print("\n" + "="*80)
    print("📊 FULL REPORT: Waffle-DB 1536-d Vector Database")
    print("="*80 + "\n")
    
    for profile in profiles:
        rust = rust_results.get(profile, {'insert_us': 0, 'query_us': 0, 'restore_us': 0})
        dart = dart_results.get(profile, {'insert_us': 0, 'query_us': 0, 'restore_us': 0})
        
        rust_ins = rust.get('insert_us', 0) / 1000.0
        rust_query = rust.get('query_us', 0) / 1000.0
        rust_restore = rust.get('restore_us', 0) / 1000.0
        
        dart_ins = dart.get('insert_us', 0) / 1000.0
        dart_query = dart.get('query_us', 0) / 1000.0
        dart_restore = dart.get('restore_us', 0) / 1000.0
        
        ffi_ins = dart_ins - rust_ins
        ffi_query = dart_query - rust_query
        ffi_restore = dart_restore - rust_restore
        
        print(f"🌟 PROFILE: {profile.upper()}")
        print(f"{'Metric':<20} | {'Pure Rust Time':<15} | {'FFI/Dart Overhead':<18} | {'Total End-to-End Time':<15}")
        print("-" * 75)
        print(f"{'Single Insert':<20} | {rust_ins:>10.3f} ms   | {ffi_ins:>13.3f} ms   | {dart_ins:>10.3f} ms")
        print(f"{'Query (k=10, N=1k)':<20} | {rust_query:>10.3f} ms   | {ffi_query:>13.3f} ms   | {dart_query:>10.3f} ms")
        print("\n")

if __name__ == "__main__":
    main()
