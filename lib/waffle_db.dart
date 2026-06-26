library;

// Core
export 'src/core/waffle_database.dart';
export 'src/core/query/waffle_query_builder.dart';
export 'src/core/extentions/waffle_config_extentions.dart';

// Modules
export 'src/modules/waffle_collection.dart';
export 'src/modules/waffle_record.dart';

// Rust bridge types (config, models, math)
export 'src/rust/api/config.dart'
    show WaffleConfig, WaffleGraphConfig, WaffleMetric;
export 'src/rust/api/math.dart' show cosineSimilarity;
export 'src/rust/api/models.dart' show VectorMetadata, WaffleQueryResult;

// FRB initializer
export 'src/rust/frb_generated.dart' show RustLib;
