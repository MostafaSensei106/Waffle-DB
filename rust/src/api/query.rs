#[derive(Clone, Debug)]
pub struct WaffleSearchRequest {
    pub vector: Option<Vec<f32>>,
    pub text: Option<String>,
    pub top_k: u32,
    pub offset: u32,
    pub filter_json: Option<String>,
    pub alpha: Option<f32>,
    pub rrf_k: Option<u32>,
    pub ef_search: u32,
}

#[derive(Clone, Debug)]
pub struct WaffleHit {
    pub id: String,
    pub score: f32,
    pub distance: Option<f32>,
    pub text: Option<String>,
    pub payload_json: Option<String>,
}

pub(crate) fn rrf_fuse(
    dense: &[(u32, f32)],
    sparse: &[(u32, f32)],
    rrf_k: usize,
    alpha: f32,
    top_k: usize,
) -> Vec<(u32, f32, Option<f32>)> {
    use std::collections::HashMap;
    let k = rrf_k as f32;
    let mut scores: HashMap<u32, (f32, Option<f32>)> = HashMap::new();
    for (rank, (id, dist)) in dense.iter().enumerate() {
        let entry = scores.entry(*id).or_insert((0.0, None));
        entry.0 += alpha / (k + rank as f32 + 1.0);
        entry.1 = Some(*dist);
    }
    for (rank, (id, _)) in sparse.iter().enumerate() {
        let entry = scores.entry(*id).or_insert((0.0, None));
        entry.0 += (1.0 - alpha) / (k + rank as f32 + 1.0);
    }
    let mut fused: Vec<(u32, f32, Option<f32>)> = scores
        .into_iter()
        .map(|(id, (score, dist))| (id, score, dist))
        .collect();
    fused.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    fused.truncate(top_k);
    fused
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn rrf_prefers_items_ranked_high_on_both_sides() {
        let dense = vec![(1u32, 0.1), (2, 0.2), (3, 0.3)];
        let sparse = vec![(3u32, 9.0), (2, 8.0), (1, 7.0)];
        let fused = rrf_fuse(&dense, &sparse, 60, 0.5, 10);
        assert_eq!(fused.len(), 3);
        // id 2 is rank 2 on both sides: 0.5/62 + 0.5/62
        let expected = 0.5 / 62.0 + 0.5 / 62.0;
        assert!(approx(fused[0].1, expected), "got {:?}", fused);
        assert_eq!(fused[0].0, 2);
    }

    #[test]
    fn rrf_alpha_weights_the_dense_side() {
        let dense = vec![(1u32, 0.1)];
        let sparse = vec![(2u32, 9.0)];
        let fused = rrf_fuse(&dense, &sparse, 60, 1.0, 10);
        assert_eq!(fused[0].0, 1);
        assert!(approx(fused[0].1, 1.0 / 61.0));
        assert_eq!(fused[1].0, 2);
        assert!(approx(fused[1].1, 0.0));
    }

    #[test]
    fn rrf_truncates_to_top_k_preserving_order() {
        let dense: Vec<(u32, f32)> = (0..10).map(|i| (i, i as f32)).collect();
        let sparse: Vec<(u32, f32)> = (0..10).map(|i| (9 - i, i as f32)).collect();
        let fused = rrf_fuse(&dense, &sparse, 60, 0.5, 3);
        assert_eq!(fused.len(), 3);
        assert!(fused[0].1 >= fused[1].1 && fused[1].1 >= fused[2].1);
    }

    #[test]
    fn rrf_keeps_dense_distance_for_hits() {
        let dense = vec![(7u32, 0.42)];
        let sparse = vec![];
        let fused = rrf_fuse(&dense, &sparse, 60, 0.5, 10);
        assert_eq!(fused.len(), 1);
        assert_eq!(fused[0].2, Some(0.42));
    }
}
