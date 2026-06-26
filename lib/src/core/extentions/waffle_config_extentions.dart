import '../../rust/api/config.dart';

/// Extension providing a `copyWith` method for `WaffleConfig`.
extension WaffleConfigCopyWith on WaffleConfig {
  /// Creates a copy of this `WaffleConfig` but with the given fields replaced with the new values.
  WaffleConfig copyWith({
    int? dimension,
    String? path,
    WaffleGraphConfig? graphConfig,
    int? maxElements,
    bool? useQuantization,
    BigInt? cacheSizeBytes,
    int? workerThreads,
  }) {
    return WaffleConfig(
      dimension: dimension ?? this.dimension,
      path: path ?? this.path,
      graphConfig: graphConfig ?? this.graphConfig,
      maxElements: maxElements ?? this.maxElements,
      useQuantization: useQuantization ?? this.useQuantization,
      cacheSizeBytes: cacheSizeBytes ?? this.cacheSizeBytes,
      workerThreads: workerThreads ?? this.workerThreads,
    );
  }
}

/// Extension providing a `copyWith` method for `WaffleGraphConfig`.
extension WaffleGraphConfigCopyWith on WaffleGraphConfig {
  /// Creates a copy of this `WaffleGraphConfig` but with the given fields replaced with the new values.
  WaffleGraphConfig copyWith({
    int? m,
    WaffleMetric? metric,
    int? efConstruction,
    int? efSearch,
  }) {
    return WaffleGraphConfig(
      m: m ?? this.m,
      metric: metric ?? this.metric,
      efConstruction: efConstruction ?? this.efConstruction,
      efSearch: efSearch ?? this.efSearch,
    );
  }
}

/// Extension providing a `copyWith` method directly on a `Future<WaffleConfig>`.
extension FutureWaffleConfigCopyWith on Future<WaffleConfig> {
  /// Allows chaining `copyWith` directly on the async profile methods.
  /// Example: `await WaffleConfig.mobileProfile(...).copyWith(...)`
  Future<WaffleConfig> copyWith({
    int? dimension,
    String? path,
    WaffleGraphConfig? graphConfig,
    int? maxElements,
    bool? useQuantization,
    BigInt? cacheSizeBytes,
    int? workerThreads,
  }) async {
    final config = await this;
    return config.copyWith(
      dimension: dimension,
      path: path,
      graphConfig: graphConfig,
      maxElements: maxElements,
      useQuantization: useQuantization,
      cacheSizeBytes: cacheSizeBytes,
      workerThreads: workerThreads,
    );
  }
}
