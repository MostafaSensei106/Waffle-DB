use std::time::Instant;
use rand::Rng;
use waffle_db::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
use waffle_db::api::waffle_db::{waffle_close, waffle_insert, waffle_open, waffle_query};
use std::fs;

fn generate_random_vector(dim: usize) -> Vec<f32> {
    let mut rng = rand::thread_rng();
    (0..dim).map(|_| rng.gen::<f32>()).collect()
}

fn bench_scale(n: usize) {
    let dim = 1536;
    let path = format!("/tmp/waffle_scale_{}", n);
    let _ = fs::remove_dir_all(&path);

    let config = WaffleConfig {
        dimension: dim as u32,
        path: path.clone(),
        graph_config: WaffleGraphConfig {
            m: 16,
            metric: WaffleMetric::Cosine,
            ef_construction: 64,
            ef_search: 32,
        },
        max_elements: n as u32 + 1000,
        use_quantization: false,
        cache_size_bytes: 32 * 1024 * 1024,
        worker_threads: 4,
    };

    let handle = waffle_open(config.clone()).unwrap();

    let mut insert_us = 0;
    for i in 0..n {
        let vec = generate_random_vector(dim);
        let start = Instant::now();
        waffle_insert(handle, format!("v{}", i), vec, vec![]).unwrap();
        insert_us += start.elapsed().as_micros();
    }
    let avg_insert_us = insert_us as f64 / n as f64;

    let mut query_us = 0;
    let query_iters = 100;
    for _ in 0..query_iters {
        let vec = generate_random_vector(dim);
        let start = Instant::now();
        waffle_query(handle, vec, 10, 0, false).unwrap();
        query_us += start.elapsed().as_micros();
    }
    let avg_query_us = query_us as f64 / query_iters as f64;

    waffle_close(handle).unwrap();

    let start_open = Instant::now();
    let handle2 = waffle_open(config).unwrap();
    let restore_us = start_open.elapsed().as_micros();
    waffle_close(handle2).unwrap();

    println!(
        "| {:<5} | {:<10.3} | {:<10.3} | {:<10.3} |",
        n, avg_query_us / 1000.0, restore_us as f64 / 1000.0, avg_insert_us / 1000.0
    );

    let _ = fs::remove_dir_all(&path);
}

fn main() {
    println!("| N     | Query (ms) | Open (ms)  | Insert (ms)|");
    println!("|-------|------------|------------|------------|");
    bench_scale(1_000);
    bench_scale(10_000);
    bench_scale(50_000);
    bench_scale(100_000);
}
