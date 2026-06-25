use rkyv::{Archive, Deserialize, Serialize};

#[derive(Archive, Serialize, Deserialize, Debug)]
pub struct VectorMetadata {
    pub title: String,
    pub description: String,
    pub category: String,
    pub payload: Vec<u8>,
}
