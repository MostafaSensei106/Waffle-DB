use waffle_db::api::config::{WaffleConfig, WaffleGraphConfig, WaffleMetric};
use waffle_db::api::query::WaffleSearchRequest;
use waffle_db::api::schema::{WaffleField, WaffleFieldType, WaffleLanguage, WaffleSchema};
use waffle_db::api::waffle_db::*;

fn test_schema() -> WaffleSchema {
    WaffleSchema {
        fields: vec![
            WaffleField {
                name: "category".to_owned(),
                field_type: WaffleFieldType::String,
                indexed: true,
            },
            WaffleField {
                name: "price".to_owned(),
                field_type: WaffleFieldType::Integer,
                indexed: true,
            },
        ],
        text_language: WaffleLanguage::English,
    }
}

fn test_config(path: &str) -> WaffleConfig {
    WaffleConfig {
        dimension: 8,
        path: path.to_owned(),
        graph_config: WaffleGraphConfig {
            m: 16,
            metric: WaffleMetric::Cosine,
            ef_construction: 64,
            ef_search: 32,
        },
        max_elements: 1000,
        use_quantization: false,
        cache_size_bytes: 8 * 1024 * 1024,
        worker_threads: 2,
    }
}

#[test]
fn enterprise_roundtrip() {
    let path = "/tmp/waffle_enterprise_test_db";
    let _ = std::fs::remove_dir_all(path);
    let handle = waffle_open(test_config(path), test_schema()).unwrap();

    let vec_a = vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    let vec_b = vec![0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    waffle_insert(
        handle,
        "doc-a".to_owned(),
        vec_a.clone(),
        "fast red car".to_owned(),
        r#"{"category":"auto","price":100}"#.to_owned(),
        Some("parent-1".to_owned()),
        0,
    )
    .unwrap();
    waffle_insert(
        handle,
        "doc-b".to_owned(),
        vec_b.clone(),
        "slow blue boat".to_owned(),
        r#"{"category":"marine","price":200}"#.to_owned(),
        Some("parent-1".to_owned()),
        1,
    )
    .unwrap();

    assert_eq!(waffle_count(handle).unwrap(), 2);

    let hits = waffle_search(
        handle,
        WaffleSearchRequest {
            vector: Some(vec_a.clone()),
            text: None,
            top_k: 5,
            offset: 0,
            filter_json: Some(r#"{"op":"eq","field":"category","value":"auto"}"#.to_owned()),
            alpha: None,
            rrf_k: None,
            ef_search: 0,
        },
    )
    .unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].id, "doc-a");

    let empty = waffle_search(
        handle,
        WaffleSearchRequest {
            vector: Some(vec_a.clone()),
            text: None,
            top_k: 5,
            offset: 0,
            filter_json: Some(r#"{"op":"eq","field":"category","value":"marine"}"#.to_owned()),
            alpha: None,
            rrf_k: None,
            ef_search: 0,
        },
    )
    .unwrap();
    assert_eq!(empty.len(), 1);
    assert_eq!(empty[0].id, "doc-b");

    let neighbors = waffle_get_neighbors(handle, "doc-a".to_owned(), 1).unwrap();
    assert_eq!(neighbors.len(), 2);

    assert!(waffle_delete(handle, "doc-a".to_owned()).unwrap());
    assert_eq!(waffle_count(handle).unwrap(), 1);
    let after = waffle_search(
        handle,
        WaffleSearchRequest {
            vector: Some(vec_a),
            text: None,
            top_k: 5,
            offset: 0,
            filter_json: None,
            alpha: None,
            rrf_k: None,
            ef_search: 0,
        },
    )
    .unwrap();
    assert!(after.iter().all(|h| h.id != "doc-a"));

    let replaced = waffle_upsert(
        handle,
        "doc-b".to_owned(),
        vec![0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "updated boat text".to_owned(),
        r#"{"category":"marine","price":250}"#.to_owned(),
        None,
        0,
    )
    .unwrap();
    assert!(replaced);
    assert_eq!(waffle_count(handle).unwrap(), 1);

    let page = waffle_search(
        handle,
        WaffleSearchRequest {
            vector: None,
            text: Some("boat".to_owned()),
            top_k: 5,
            offset: 1,
            filter_json: None,
            alpha: None,
            rrf_k: None,
            ef_search: 0,
        },
    )
    .unwrap();
    assert!(page.is_empty());

    let wiped = waffle_delete_where(
        handle,
        r#"{"op":"eq","field":"category","value":"marine"}"#.to_owned(),
    )
    .unwrap();
    assert_eq!(wiped, 1);
    assert_eq!(waffle_count(handle).unwrap(), 0);

    waffle_close(handle).unwrap();
    let _ = std::fs::remove_dir_all(path);
}
