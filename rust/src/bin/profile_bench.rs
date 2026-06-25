use std::time::Instant;
use rand::Rng;
use std::fs;
use std::path::PathBuf;
use waffle_db::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
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
    for i in 0..warmup {
        waffle_insert(handle, format!("w_insert_{}", i), insert_vectors[i].clone(), vec![]).unwrap();
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
    for i in 0..warmup {
        waffle_query(handle, query_vectors[i].clone(), 10, 0).unwrap();
    }

    // Bench query
    let mut total_query_us = 0;
    for i in 0..iterations {
        let vec = query_vectors[warmup + i].clone();
        let start = Instant::now();
        waffle_query(handle, vec, 10, 0).unwrap();
        total_query_us += start.elapsed().as_micros();
    }
    let avg_query_us = total_query_us as f64 / iterations as f64;

    waffle_close(handle).unwrap();
    let _ = fs::remove_dir_all(&path);

    println!(
        "{{\"profile\": \"{}\", \"insert_us\": {}, \"query_us\": {}}}",
        profile_name, avg_insert_us, avg_query_us
    );
}

fn main() {
    let dim = 1536;
    bench_profile("Mobile", WaffleConfig::mobile_profile("tmp", dim));
    bench_profile("Server", WaffleConfig::server_profile("tmp", dim));
    bench_profile("ReadHeavy", WaffleConfig::read_heavy_profile("tmp", dim));
    bench_profile("WriteHeavy", WaffleConfig::write_heavy_profile("tmp", dim));
}
