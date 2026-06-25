use std::time::Instant;
use rand::Rng;
use std::fs;
use std::path::PathBuf;
use waffle_db::api::config::WaffleConfig;
use waffle_db::api::waffle_db::{waffle_close, waffle_insert, waffle_open, waffle_query};

fn generate_random_vector(dim: usize) -> Vec<f32> {
    let mut rng = rand::thread_rng();
    (0..dim).map(|_| rng.gen::<f32>()).collect()
}

fn bench_profile(profile_name: &str, mut cfg: WaffleConfig) {
    let path = PathBuf::from(format!("/tmp/waffle_bench_rust_{}", profile_name));
    if path.exists() {
        let _ = fs::remove_dir_all(&path);
    }
    cfg.path = path.to_str().unwrap().to_string();
    
    let handle = waffle_open(cfg.clone()).unwrap();
    let dim = cfg.dimension as usize;

    let warmup = 3;
    let iterations = 10;

    let insert_vectors: Vec<Vec<f32>> = (0..(warmup + iterations)).map(|_| generate_random_vector(dim)).collect();
    
    // Warmup insert
    for (i, vec) in insert_vectors.iter().enumerate().take(warmup) {
        waffle_insert(
            handle,
            format!("bench-insert-{}", i),
            vec.clone(),
            Vec::new(),
        )
        .unwrap();
    }
    
    // Bench Insert
    let mut total_insert_us = 0;
    for i in 0..iterations {
        let vec = insert_vectors[warmup + i].clone();
        let start = Instant::now();
        waffle_insert(handle, format!("insert_{}", i), vec, vec![]).unwrap();
        total_insert_us += start.elapsed().as_micros();
    }
    let avg_insert_us = total_insert_us as f64 / iterations as f64;

    // Pre-insert 1000 items
    for i in 0..1000 {
        waffle_insert(handle, format!("pre_{}", i), generate_random_vector(dim), vec![]).unwrap();
    }

    let query_vectors: Vec<Vec<f32>> = (0..(warmup + iterations)).map(|_| generate_random_vector(dim)).collect();

    // Warmup query
    for vec in query_vectors.iter().take(warmup) {
        waffle_query(handle, vec.clone(), 10, 0, false).unwrap();
    }

    // Bench query
    let mut total_query_us = 0;
    for i in 0..iterations {
        let vec = query_vectors[warmup + i].clone();
        let start = Instant::now();
        waffle_query(handle, vec, 10, 0, false).unwrap();
        total_query_us += start.elapsed().as_micros();
    }
    let avg_query_us = total_query_us as f64 / iterations as f64;

    // Test restore speed
    let start_close = Instant::now();
    waffle_close(handle).unwrap();
    let _close_us = start_close.elapsed().as_micros();

    let start_open = Instant::now();
    let _handle2 = waffle_open(cfg).unwrap();
    let restore_us = start_open.elapsed().as_micros();
    waffle_close(_handle2).unwrap();

    println!(
        "JSON_RESULT: {{\"profile\": \"{}\", \"insert_us\": {}, \"query_us\": {}, \"restore_us\": {}}}",
        profile_name, avg_insert_us, avg_query_us, restore_us
    );
    
    let _ = fs::remove_dir_all(&path);
}

fn main() {
    let dim = 1536;
    bench_profile("Mobile", WaffleConfig::mobile_profile("tmp", dim));
    bench_profile("Server", WaffleConfig::server_profile("tmp", dim));
    bench_profile("ReadHeavy", WaffleConfig::read_heavy_profile("tmp", dim));
    bench_profile("WriteHeavy", WaffleConfig::write_heavy_profile("tmp", dim));
}
