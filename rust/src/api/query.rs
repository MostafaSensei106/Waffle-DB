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
