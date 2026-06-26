/// Distance metric used for vector comparisons.
#[derive(Clone, Debug, PartialEq)]
pub enum WaffleMetric {
    /// Cosine similarity (1 - cosine distance). Best for normalized embeddings.
    Cosine,
    /// Euclidean distance (L2 norm). Best for spatial data.
    Euclidean,
    /// Dot product. Use when vectors are not normalized and magnitude matters.
    DotProduct,
}

/// Configuration for the underlying HNSW graph.
#[derive(Clone, Debug)]
pub struct WaffleGraphConfig {
    /// Max number of connections per element in the graph.
    pub m: u32,
    /// Distance metric to use.
    pub metric: WaffleMetric,
    /// Size of the dynamic list for the nearest neighbors (used during index build).
    pub ef_construction: u32,
    /// Size of the dynamic list for the nearest neighbors (used during search).
    pub ef_search: u32,
}

/// Main configuration for the Waffle Database.
#[derive(Clone, Debug)]
pub struct WaffleConfig {
    /// Dimensionality of the vectors to be stored.
    pub dimension: u32,
    /// File path where the database will be persisted.
    pub path: String,
    /// Configuration for the HNSW graph.
    pub graph_config: WaffleGraphConfig,
    /// Maximum number of elements the database can hold.
    pub max_elements: u32,
    /// Whether to use scalar quantization to save memory.
    pub use_quantization: bool,
    /// Size of the cache in bytes.
    pub cache_size_bytes: u64,
    /// Number of worker threads for parallel operations.
    pub worker_threads: u32,
}

impl Default for WaffleConfig {
    fn default() -> Self {
        Self {
            dimension: 1536,
            graph_config: WaffleGraphConfig {
                m: 16,
                metric: WaffleMetric::Cosine,
                ef_construction: 64,
                ef_search: 32,
            },
            path: "waffle_db_default".to_string(), // Default path for the database
            max_elements: 100_000,
            use_quantization: false,
            cache_size_bytes: 0,
            worker_threads: 1,
        }
    }
}

impl WaffleConfig {
    /// Creates a configuration optimized for mobile devices.
    ///
    /// Example:
    /// ```dart
    /// final config = await WaffleConfig.mobileProfile(path: 'db', dimension: 128);
    /// ```
    pub fn mobile_profile(path: &str, dimension: u32) -> Self {
        Self {
            dimension,
            graph_config: WaffleGraphConfig {
                m: 12,
                metric: WaffleMetric::Cosine,
                ef_construction: 48,
                ef_search: 16,
            },
            path: path.to_string(),
            max_elements: 50_000,
            use_quantization: true,
            cache_size_bytes: 16 * 1024 * 1024, // 16 MB cache
            worker_threads: 2,
        }
    }

    /// Creates a configuration optimized for server environments.
    ///
    /// Example:
    /// ```dart
    /// final config = await WaffleConfig.serverProfile(path: 'db', dimension: 1536);
    /// ```
    pub fn server_profile(path: &str, dimension: u32) -> Self {
        Self {
            dimension,
            graph_config: WaffleGraphConfig {
                m: 32,
                metric: WaffleMetric::Cosine,
                ef_construction: 128,
                ef_search: 64,
            },
            path: path.to_string(),
            max_elements: 5_000_000,
            use_quantization: false,
            cache_size_bytes: 512 * 1024 * 1024, // 512 MB cache
            worker_threads: 4,
        }
    }

    /// Creates a configuration optimized for read-heavy workloads.
    ///
    /// Example:
    /// ```dart
    /// final config = await WaffleConfig.readHeavyProfile(path: 'db', dimension: 1536);
    /// ```
    pub fn read_heavy_profile(path: &str, dimension: u32) -> Self {
        Self {
            dimension,
            path: path.to_string(),
            graph_config: WaffleGraphConfig {
                m: 24,
                metric: WaffleMetric::Cosine,
                ef_construction: 200,
                ef_search: 128,
            },
            max_elements: 10_000_000,
            use_quantization: true,
            cache_size_bytes: 2 * 1024 * 1024 * 1024, // 2 GB cache
            worker_threads: num_cpus::get() as u32,
        }
    }

    /// Creates a configuration optimized for write-heavy workloads.
    ///
    /// Example:
    /// ```dart
    /// final config = await WaffleConfig.writeHeavyProfile(path: 'db', dimension: 1536);
    /// ```
    pub fn write_heavy_profile(path: &str, dimension: u32) -> Self {
        Self {
            dimension,
            path: path.to_string(),
            graph_config: WaffleGraphConfig {
                m: 16,
                metric: WaffleMetric::Cosine,
                ef_construction: 32,
                ef_search: 32,
            },
            max_elements: 20_000_000,
            use_quantization: false,
            cache_size_bytes: 128 * 1024 * 1024, // 128 MB cache
            worker_threads: num_cpus::get() as u32,
        }
    }
}
