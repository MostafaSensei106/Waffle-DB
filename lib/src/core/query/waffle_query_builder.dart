import 'dart:typed_data';

import 'package:waffle_db/waffle_db.dart';

/// Fluent builder for dense, sparse and hybrid searches with filters.
class WaffleQueryBuilder {
  final WaffleDatabase _db;

  Float32List? _vector;
  String? _text;
  int _limit = 10;
  int _offset = 0;
  int _efSearch = 0;
  double? _alpha;
  int? _rrfK;
  final List<WaffleFilter> _filters = [];

  /// Binds this builder to [db].
  WaffleQueryBuilder(this._db);

  /// Sets the dense query vector.
  WaffleQueryBuilder withVector(Float32List vector) {
    _vector = vector;
    return this;
  }

  /// Sets the dense query vector from plain doubles.
  WaffleQueryBuilder withVectorList(List<double> vector) {
    _vector = Float32List.fromList(vector);
    return this;
  }

  /// Sets the BM25 keyword query text.
  WaffleQueryBuilder withText(String text) {
    _text = text;
    return this;
  }

  /// Sets both sides of a hybrid query at once.
  WaffleQueryBuilder withHybrid({Float32List? vector, String? text}) {
    if (vector != null) _vector = vector;
    if (text != null) _text = text;
    return this;
  }

  /// Caps returned hits at [n].
  WaffleQueryBuilder limit(int n) {
    _limit = n;
    return this;
  }

  /// Skips the first [n] fused hits (pagination).
  WaffleQueryBuilder offset(int n) {
    _offset = n;
    return this;
  }

  /// Overrides index expansion for this query when greater than zero.
  WaffleQueryBuilder efSearch(int ef) {
    _efSearch = ef;
    return this;
  }

  /// Blends dense vs sparse ranks in hybrid mode (0.0 to 1.0).
  WaffleQueryBuilder alpha(double a) {
    _alpha = a.clamp(0.0, 1.0);
    return this;
  }

  /// Sets the RRF smoothing constant (default 60).
  WaffleQueryBuilder rrfK(int k) {
    _rrfK = k;
    return this;
  }

  /// Requires `field == value` (pre-filtered inside the engine).
  WaffleQueryBuilder eq(String field, Object value) {
    _filters.add(WaffleEqFilter(field, value));
    return this;
  }

  /// Requires `field IN values` (pre-filtered inside the engine).
  WaffleQueryBuilder inList(String field, List<Object> values) {
    _filters.add(WaffleInFilter(field, values));
    return this;
  }

  /// Requires at least one of [filters] to match.
  WaffleQueryBuilder or(List<WaffleFilter> filters) {
    _filters.add(WaffleOrFilter(filters));
    return this;
  }

  /// Adds a pre-built filter object.
  WaffleQueryBuilder filter(WaffleFilter filter) {
    _filters.add(filter);
    return this;
  }

  /// Requires every filter in [filters] to match.
  WaffleQueryBuilder and(List<WaffleFilter> filters) {
    _filters.add(WaffleAndFilter(filters));
    return this;
  }

  /// Runs the query and returns fused hits.
  Future<List<WaffleHit>> execute() async {
    if (_vector == null && _text == null) {
      throw StateError(
        'No query set. Call withVector() and/or withText() before execute().',
      );
    }
    return _db.search(
      vector: _vector,
      text: _text,
      topK: _limit,
      offset: _offset,
      filters: _filters.isEmpty ? null : _filters,
      alpha: _alpha,
      rrfK: _rrfK,
      efSearch: _efSearch,
    );
  }
}
