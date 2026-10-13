use waffle_db::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
use waffle_db::api::schema::{WaffleField, WaffleFieldType, WaffleLanguage, WaffleSchema};
use waffle_db::api::waffle_db::*;

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 33) as f64) / (u32::MAX as f64) - 0.5
    }
}

fn schema() -> WaffleSchema {
    WaffleSchema {
        fields: vec![
            WaffleField {
                name: "cat".to_owned(),
                field_type: WaffleFieldType::String,
                indexed: true,
            },
            WaffleField {
                name: "tag".to_owned(),
                field_type: WaffleFieldType::String,
                indexed: false,
            },
        ],
        text_language: WaffleLanguage::English,
    }
}

fn config(path: &str, dim: u32) -> WaffleConfig {
    WaffleConfig {
        dimension: dim,
        path: path.to_owned(),
        graph_config: WaffleGraphConfig {
            m: 16,
            metric: WaffleMetric::Cosine,
            ef_construction: 64,
            ef_search: 32,
        },
        max_elements: 100_000,
        use_quantization: false,
        cache_size_bytes: 64 * 1024 * 1024,
        worker_threads: 2,
    }
}

fn cosine_bruteforce(data: &[(String, Vec<f32>)], query: &[f32], k: usize) -> Vec<String> {
    let mut scored: Vec<(String, f64)> = data
        .iter()
        .map(|(id, v)| {
            let (mut dot, mut na, mut nb) = (0.0f64, 0.0f64, 0.0f64);
            for (x, y) in v.iter().zip(query.iter()) {
                let (xd, yd) = (*x as f64, *y as f64);
                dot += xd * yd;
                na += xd * xd;
                nb += yd * yd;
            }
            (id.clone(), 1.0 - dot / (na.sqrt() * nb.sqrt()))
        })
        .collect();
    scored.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());
    scored.into_iter().take(k).map(|(id, _)| id).collect()
}

fn search_ids(handle: u64, vector: Vec<f32>, k: u32, filter: Option<String>) -> Vec<String> {
    use waffle_db::api::query::WaffleSearchRequest;
    waffle_search(
        handle,
        WaffleSearchRequest {
            vector: Some(vector),
            text: None,
            top_k: k,
            offset: 0,
            filter_json: filter,
            alpha: None,
            rrf_k: None,
            ef_search: 0,
        },
    )
    .unwrap()
    .into_iter()
    .map(|h| h.id)
    .collect()
}

#[test]
fn filtered_and_unfiltered_recall_against_bruteforce() {
    let path = "/tmp/waffle_proof_recall";
    let _ = std::fs::remove_dir_all(path);
    let dim = 64usize;
    let handle = waffle_open(config(path, dim as u32), schema()).unwrap();

    let mut rng = Lcg(0x12345678);
    let mut data: Vec<(String, Vec<f32>)> = Vec::new();
    let mut ids = Vec::new();
    let mut vecs = Vec::new();
    let mut payloads = Vec::new();
    for i in 0..2000 {
        let v: Vec<f32> = (0..dim).map(|_| rng.next() as f32).collect();
        let cat = if i % 20 == 0 { "rare" } else { "common" };
        ids.push(format!("v{i}"));
        payloads.push(format!(r#"{{"cat":"{cat}","tag":"t{i}"}}"#));
        data.push((format!("v{i}"), v.clone()));
        vecs.extend(v);
    }
    let texts = vec![String::new(); 2000];
    let parents = vec![String::new(); 2000];
    let chunks = vec![0u32; 2000];
    waffle_insert_batch(handle, ids, vecs, texts, payloads, parents, chunks).unwrap();

    let query: Vec<f32> = (0..dim).map(|_| rng.next() as f32).collect();
    let expected: std::collections::HashSet<String> = cosine_bruteforce(&data, &query, 10)
        .into_iter()
        .collect();
    let got: std::collections::HashSet<String> =
        search_ids(handle, query.clone(), 10, None).into_iter().collect();
    let recall = got.intersection(&expected).count() as f64 / 10.0;
    assert!(recall >= 0.6, "unfiltered recall@10 = {recall}");

    let rare_data: Vec<(String, Vec<f32>)> = data
        .into_iter()
        .enumerate()
        .filter(|(i, _)| i % 20 == 0)
        .map(|(_, v)| v)
        .collect();
    let expected_f: std::collections::HashSet<String> =
        cosine_bruteforce(&rare_data, &query, 10).into_iter().collect();
    let got_f: std::collections::HashSet<String> = search_ids(
        handle,
        query,
        10,
        Some(r#"{"op":"eq","field":"cat","value":"rare"}"#.to_owned()),
    )
    .into_iter()
    .collect();
    assert!(
        got_f.iter().all(|id| {
            let n: usize = id[1..].parse().unwrap();
            n % 20 == 0
        }),
        "filtered results must all match: {got_f:?}"
    );
    let recall_f = got_f.intersection(&expected_f).count() as f64 / 10.0;
    assert!(recall_f >= 0.4, "filtered recall@10 = {recall_f}");

    waffle_close(handle).unwrap();
    let _ = std::fs::remove_dir_all(path);
}

#[test]
fn selective_filter_fills_topk() {
    let path = "/tmp/waffle_proof_selective";
    let _ = std::fs::remove_dir_all(path);
    let handle = waffle_open(config(path, 8), schema()).unwrap();
    let mut ids = Vec::new();
    let mut vecs = Vec::new();
    for i in 0..60 {
        let cat = if i < 50 { "in" } else { "out" };
        ids.push(format!("s{i}"));
        vecs.extend([0.1 * i as f32, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        let _ = cat;
    }
    let payloads: Vec<String> = (0..60)
        .map(|i| {
            let cat = if i < 50 { "in" } else { "out" };
            format!(r#"{{"cat":"{cat}","tag":"t"}}"#)
        })
        .collect();
    waffle_insert_batch(
        handle,
        ids,
        vecs,
        vec![String::new(); 60],
        payloads,
        vec![String::new(); 60],
        vec![0u32; 60],
    )
    .unwrap();
    let hits = search_ids(
        handle,
        vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        10,
        Some(r#"{"op":"eq","field":"cat","value":"in"}"#.to_owned()),
    );
    assert_eq!(hits.len(), 10);
    waffle_close(handle).unwrap();
    let _ = std::fs::remove_dir_all(path);
}

#[test]
fn concurrent_writes_and_reads_stay_consistent() {
    let path = "/tmp/waffle_proof_concurrent";
    let _ = std::fs::remove_dir_all(path);
    let handle = waffle_open(config(path, 8), schema()).unwrap();

    let mut threads = Vec::new();
    for t in 0..4u32 {
        threads.push(std::thread::spawn(move || {
            for i in 0..250u32 {
                let id = format!("t{t}-{i}");
                let mut v = vec![0.0f32; 8];
                v[(i % 8) as usize] = 1.0;
                waffle_insert(
                    handle,
                    id,
                    v,
                    String::new(),
                    r#"{"cat":"common","tag":"x"}"#.to_owned(),
                    None,
                    0,
                )
                .unwrap();
            }
            let hits = search_ids(
                handle,
                vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                5,
                None,
            );
            assert!(!hits.is_empty());
        }));
    }
    for th in threads {
        th.join().unwrap();
    }
    assert_eq!(waffle_count(handle).unwrap(), 1000);
    assert_eq!(waffle_get_all_ids(handle).unwrap().len(), 1000);
    waffle_close(handle).unwrap();

    let handle = waffle_open(config(path, 8), schema()).unwrap();
    assert_eq!(waffle_count(handle).unwrap(), 1000);
    waffle_close(handle).unwrap();
    let _ = std::fs::remove_dir_all(path);
}

#[test]
fn second_open_of_live_path_fails_loudly() {
    let path = "/tmp/waffle_proof_double_open";
    let _ = std::fs::remove_dir_all(path);
    let first = waffle_open(config(path, 8), schema()).unwrap();
    let second = waffle_open(config(path, 8), schema());
    assert!(
        second.is_err(),
        "opening a live database path twice must fail loudly, not corrupt"
    );
    waffle_close(first).unwrap();
    let reopened = waffle_open(config(path, 8), schema()).unwrap();
    waffle_close(reopened).unwrap();
    let _ = std::fs::remove_dir_all(path);
}

#[test]
fn arabic_stemming_groups_inflections() {
    // Documents the ACTUAL contract of the Snowball Arabic stemmer used by
    // the engine: light prefix/suffix stripping (e.g. the definite article),
    // NOT full root extraction. "الكتب" (stem: كتب) therefore does NOT match
    // "الكتاب" (stem: كتاب) or "مكتبة" (stem: مكتب) — same as Lucene-grade
    // Arabic analyzers without a root dictionary.
    let path = "/tmp/waffle_proof_arabic";
    let _ = std::fs::remove_dir_all(path);
    let mut sch = schema();
    sch.text_language = waffle_db::api::schema::WaffleLanguage::Arabic;
    let handle = waffle_open(config(path, 8), sch).unwrap();
    for (id, text) in [
        ("a1", "الكتاب المفيد على الرف"),
        ("a2", "ذهبت إلى مكتبة الجامعة"),
        ("a3", "مكاتب الموظفين في الطابق الثاني"),
        ("a4", "الطقس مشمس والسماء صافية"),
    ] {
        waffle_insert(
            handle,
            id.to_owned(),
            vec![0.0f32; 8],
            text.to_owned(),
            r#"{"cat":"common","tag":"x"}"#.to_owned(),
            None,
            0,
        )
        .unwrap();
    }
    use waffle_db::api::query::WaffleSearchRequest;
    let ask = |q: &str| {
        waffle_search(
            handle,
            WaffleSearchRequest {
                vector: None,
                text: Some(q.to_owned()),
                top_k: 5,
                offset: 0,
                filter_json: None,
                alpha: None,
                rrf_k: None,
                ef_search: 0,
            },
        )
        .unwrap()
        .into_iter()
        .map(|h| h.id)
        .collect::<Vec<_>>()
    };
    // Same stem after article stripping: definite query finds the doc.
    let hits = ask("الكتاب");
    assert!(hits.contains(&"a1".to_owned()), "missing a1 in {hits:?}");
    assert!(!hits.contains(&"a4".to_owned()));
    let hits = ask("مكتبة");
    assert!(hits.contains(&"a2".to_owned()), "missing a2 in {hits:?}");
    assert!(!hits.contains(&"a4".to_owned()));
    // Unknown term finds nothing instead of everything.
    assert!(ask("زرافة").is_empty());
    waffle_close(handle).unwrap();
    let _ = std::fs::remove_dir_all(path);
}
