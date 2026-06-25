use num_cpus;

#[derive(Clone, Debug, PartialEq)]
pub enum WaffleMetric {
    Cosine,
    Euclidean,
    DotProduct,
}

#[derive(Clone, Debug)]
pub struct WaffleGraphConfig {
    pub m: u32,
    pub metric: WaffleMetric,
    pub ef_construction: u32,
    pub ef_search: u32,
}

#[derive(Clone, Debug)]
pub struct WaffleConfig {
    pub dimension: u32,
    pub path: String,
    pub graph_config: WaffleGraphConfig,
    pub max_elements: u32,
    pub use_quantization: bool,
    pub cache_size_bytes: u64,
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
