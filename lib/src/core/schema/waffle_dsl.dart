import 'dart:convert';

import '../../rust/api/schema.dart';

/// A metadata pre-filter. Combined filters are evaluated to a bitmap
/// inside the Rust engine before any distance is computed.
abstract class WaffleFilter {
  /// Serializes this filter to the JSON AST consumed by the engine.
  Map<String, dynamic> toJson();

  /// Encodes [toJson] for transport over FFI.
  String encode() => jsonEncode(toJson());
}

/// Exact-match filter: `field == value`.
class WaffleEqFilter extends WaffleFilter {
  /// Indexed field name.
  final String field;

  /// Value to match (String, bool, int or double per the schema).
  final Object value;

  /// Creates an equality filter.
  WaffleEqFilter(this.field, this.value);

  @override
  Map<String, dynamic> toJson() => {'op': 'eq', 'field': field, 'value': value};
}

/// Set-membership filter: `field IN values`.
class WaffleInFilter extends WaffleFilter {
  /// Indexed field name.
  final String field;

  /// Accepted values.
  final List<Object> values;

  /// Creates a membership filter.
  WaffleInFilter(this.field, this.values);

  @override
  Map<String, dynamic> toJson() =>
      {'op': 'in', 'field': field, 'values': values};
}

/// Conjunction of filters. An empty list matches everything.
class WaffleAndFilter extends WaffleFilter {
  /// Filters that must all match.
  final List<WaffleFilter> filters;

  /// Creates a conjunction filter.
  WaffleAndFilter(this.filters);

  @override
  Map<String, dynamic> toJson() =>
      {'op': 'and', 'filters': filters.map((f) => f.toJson()).toList()};
}

/// Disjunction of filters.
class WaffleOrFilter extends WaffleFilter {
  /// Filters of which at least one must match.
  final List<WaffleFilter> filters;

  /// Creates a disjunction filter.
  WaffleOrFilter(this.filters);

  @override
  Map<String, dynamic> toJson() =>
      {'op': 'or', 'filters': filters.map((f) => f.toJson()).toList()};
}

/// Factories for declaring schema fields.
abstract final class WaffleFields {
  /// Declares an exact-match string field.
  static WaffleField string(String name, {bool indexed = true}) => WaffleField(
      name: name, fieldType: WaffleFieldType.string, indexed: indexed);

  /// Declares an exact-match integer field.
  static WaffleField integer(String name, {bool indexed = true}) => WaffleField(
      name: name, fieldType: WaffleFieldType.integer, indexed: indexed);

  /// Declares an exact-match double field.
  static WaffleField double(String name, {bool indexed = true}) => WaffleField(
      name: name, fieldType: WaffleFieldType.double, indexed: indexed);

  /// Declares an exact-match boolean field.
  static WaffleField boolean(String name, {bool indexed = true}) => WaffleField(
      name: name, fieldType: WaffleFieldType.boolean, indexed: indexed);

  /// Declares a full-text field for BM25 keyword search.
  static WaffleField text(String name, {bool indexed = true}) => WaffleField(
      name: name, fieldType: WaffleFieldType.text, indexed: indexed);
}
