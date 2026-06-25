use criterion::{black_box, criterion_group, criterion_main, Criterion};
use rand::Rng;
use std::fs;
use std::path::PathBuf;
use waffle_db::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
use waffle_db::api::waffle_db::{waffle_close, waffle_insert, waffle_open, waffle_query};

fn generate_random_vector(dim: usize) -> Vec<f32> {
    let mut rng = rand::thread_rng();
    (0..dim).map(|_| rng.gen::<f32>()).collect()
}

fn bench_profile(c: &mut Criterion, profile_name: &str, config: WaffleConfig) {
    let mut group = c.benchmark_group(format!("Profile_{}", profile_name));
    group.sample_size(10); // Reduce sample size for heavy profiles to finish faster
    
    let path = PathBuf::from(format!("/tmp/waffle_bench_{}", profile_name));
    if path.exists() {
        let _ = fs::remove_dir_all(&path);
    }

    let mut cfg = config.clone();
    cfg.path = path.to_str().unwrap().to_string();
    
    let handle = waffle_open(cfg.clone()).unwrap();
    let dim = cfg.dimension as usize;

    let mut id_counter = 0;

    // Bench Insert
    group.bench_function("insert", |b| {
        b.iter_with_setup(
            || generate_random_vector(dim),
            |vec| {
                let id = format!("id_{}", id_counter);
                id_counter += 1;
                waffle_insert(handle, id, black_box(vec), vec![]).unwrap();
            },
        )
    });

    // Pre-insert 1000 items for Query bench
    for i in 0..1000 {
        let vec = generate_random_vector(dim);
        waffle_insert(handle, format!("pre_{}", i), vec, vec![]).unwrap();
    }

    // Bench Query
    group.bench_function("query_k10", |b| {
        b.iter_with_setup(
            || generate_random_vector(dim),
            |vec| {
                black_box(waffle_query(handle, vec, 10, 0).unwrap());
            },
        )
    });

    waffle_close(handle).unwrap();
    let _ = fs::remove_dir_all(&path);
}

fn bench_all_profiles(c: &mut Criterion) {
    let dim = 1536; // OpenAI embedding size
    bench_profile(c, "Mobile", WaffleConfig::mobile_profile("tmp", dim as u32));
    bench_profile(c, "Server", WaffleConfig::server_profile("tmp", dim as u32));
    bench_profile(c, "ReadHeavy", WaffleConfig::read_heavy_profile("tmp", dim as u32));
    bench_profile(c, "WriteHeavy", WaffleConfig::write_heavy_profile("tmp", dim as u32));
}

criterion_group!(benches, bench_all_profiles);
criterion_main!(benches);
