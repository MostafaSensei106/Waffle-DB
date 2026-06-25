pub fn cosine_similarity(a: &[f32], b: &[f32]) -> Result<f32, String> {
    if a.len() != b.len() {
        return Err("Vectors must have the same length".to_string());
    }

    let mut dot_product = 0.0;
    let mut norm_a = 0.0;
    let mut norm_b = 0.0;

    for i in 0..a.len() {
        dot_product += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    if norm_a == 0.0 || norm_b == 0.0 {
        return Err("Vectors cannot be zero vectors".to_string());
    }

    Ok(dot_product / (norm_a.sqrt() * norm_b.sqrt()))
}
