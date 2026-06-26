import '../../rust/api/config.dart';

extension WaffleConfigCopyWith on WaffleConfig {
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

extension WaffleGraphConfigCopyWith on WaffleGraphConfig {
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
