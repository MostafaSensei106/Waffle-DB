use rkyv::{Archive, Deserialize, Serialize};

#[derive(Archive, Serialize, Deserialize, Debug)]
pub struct VectorMetadata {
    pub title: String,
    pub description: String,
    pub category: String,
    pub payload: Vec<u8>,
}

/// Result returned from a KNN query, bridgeable by FRB.
pub struct WaffleQueryResult {
    pub id: String,
    pub distance: f32,
    pub metadata: Option<Vec<u8>>,
}
