use thiserror::Error;

#[derive(Debug, Error)]
pub enum WaffleError {
    #[error("storage error: {0}")]
    Storage(String),
    #[error("vector index error: {0}")]
    Vector(String),
    #[error("text index error: {0}")]
    Text(String),
    #[error("dimension mismatch: expected {expected}, got {actual}")]
    Dimension { expected: usize, actual: usize },
    #[error("schema mismatch: {0}")]
    Schema(String),
    #[error("filter error: {0}")]
    Filter(String),
    #[error("duplicate id: {0}")]
    DuplicateId(String),
    #[error("not supported: {0}")]
    NotSupported(String),
    #[error("invalid handle: {0}")]
    InvalidHandle(u64),
    #[error("serialization error: {0}")]
    Serialization(String),
}

pub type Result<T> = std::result::Result<T, WaffleError>;

impl From<WaffleError> for String {
    fn from(e: WaffleError) -> String {
        e.to_string()
    }
}

impl From<redb::Error> for WaffleError {
    fn from(e: redb::Error) -> Self {
        WaffleError::Storage(e.to_string())
    }
}

impl From<redb::TableError> for WaffleError {
    fn from(e: redb::TableError) -> Self {
        WaffleError::Storage(e.to_string())
    }
}

impl From<redb::TransactionError> for WaffleError {
    fn from(e: redb::TransactionError) -> Self {
        WaffleError::Storage(e.to_string())
    }
}

impl From<redb::StorageError> for WaffleError {
    fn from(e: redb::StorageError) -> Self {
        WaffleError::Storage(e.to_string())
    }
}

impl From<cxx::Exception> for WaffleError {
    fn from(e: cxx::Exception) -> Self {
        WaffleError::Vector(e.what().to_owned())
    }
}

impl From<tantivy::TantivyError> for WaffleError {
    fn from(e: tantivy::TantivyError) -> Self {
        WaffleError::Text(e.to_string())
    }
}

impl From<serde_json::Error> for WaffleError {
    fn from(e: serde_json::Error) -> Self {
        WaffleError::Serialization(e.to_string())
    }
}
