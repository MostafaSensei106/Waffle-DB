pub fn cosine_similarity(a: Vec<f32>, b: Vec<f32>) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let (mut dot, mut norm_a, mut norm_b) = (0.0f64, 0.0f64, 0.0f64);
    for (&x, &y) in a.iter().zip(b.iter()) {
        let (xd, yd) = (x as f64, y as f64);
        dot += xd * yd;
        norm_a += xd * xd;
        norm_b += yd * yd;
    }
    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }
    (dot / (norm_a.sqrt() * norm_b.sqrt())) as f32
}
