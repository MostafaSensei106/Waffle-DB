import 'dart:typed_data';

import 'package:waffle_db/waffle_db.dart';

/// Fluent query builder for WaffleDB vector searches.
///
/// Usage:
/// ```dart
/// final results = await db
///     .queryBuilder()
///     .withVector(queryVector)
///     .limit(20)
///     .efSearch(64)
///     .threshold(0.5)
///     .execute();
/// ```
class WaffleQueryBuilder {
  final WaffleDatabase _db;

  int _limit = 10;
  double _threshold = 0.0;
  int _efSearch = 0;
  Float32List? _vector;
  bool _includeMetadata = true;

  WaffleQueryBuilder(this._db);

  /// Set the query vector (required before [execute]).
  WaffleQueryBuilder withVector(Float32List vector) {
    _vector = vector;
    return this;
  }

  /// Convenience: set query vector from a `List<double>`.
  WaffleQueryBuilder withVectorList(List<double> vector) {
    _vector = Float32List.fromList(vector);
    return this;
  }

  /// Set the maximum number of results to return (default: 10).
  WaffleQueryBuilder limit(int n) {
    _limit = n;
    return this;
  }

  /// Set a distance threshold — results with distance > threshold are excluded.
  /// Default 0.0 means no threshold (return all k results).
  WaffleQueryBuilder threshold(double t) {
    _threshold = t;
    return this;
  }

  /// Override ef_search for this query. Higher = more accurate but slower.
  /// Pass 0 to use the config default.
  WaffleQueryBuilder efSearch(int ef) {
    _efSearch = ef;
    return this;
  }

  /// Whether to include metadata in results (default: true).
  /// Set to false for faster queries when you only need IDs and distances.
  WaffleQueryBuilder includeMetadata(bool include) {
    _includeMetadata = include;
    return this;
  }

  /// Execute the query and return results.
  ///
  /// Throws [StateError] if no query vector has been set.
  Future<List<WaffleQueryResult>> execute() async {
    if (_vector == null) {
      throw StateError(
        'No query vector set. Call withVector() before execute().',
      );
    }

    var results = await _db.query(_vector!, k: _limit, efSearch: _efSearch);

    // Apply distance threshold filter
    if (_threshold > 0.0) {
      results = results.where((r) => r.distance <= _threshold).toList();
    }

    // Strip metadata if not requested
    if (!_includeMetadata) {
      results = results
          .map(
            (r) => WaffleQueryResult(
              id: r.id,
              distance: r.distance,
              metadata: null,
            ),
          )
          .toList();
    }

    return results;
  }
}
