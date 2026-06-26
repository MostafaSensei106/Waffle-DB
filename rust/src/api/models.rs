use rkyv::{Archive, Deserialize, Serialize};

/// Internal metadata stored alongside vectors for filtering and context.
#[derive(Archive, Serialize, Deserialize, Debug)]
pub struct VectorMetadata {
    /// Optional title for the vector.
    pub title: String,
    /// Optional description for the vector.
    pub description: String,
    /// Category or tag for grouping vectors.
    pub category: String,
    /// Raw payload bytes for arbitrary user data.
    pub payload: Vec<u8>,
}

/// Result returned from a KNN query, bridgeable by FRB.
pub struct WaffleQueryResult {
    /// Unique identifier of the returned vector.
    pub id: String,
    /// Computed distance from the query vector (lower means more similar).
    pub distance: f32,
    /// Optional metadata payload if requested during the search.
    pub metadata: Option<Vec<u8>>,
}
