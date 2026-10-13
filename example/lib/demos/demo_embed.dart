import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Local demo embedder: hashed character-trigram TF vectors, L2-normalized.
///
/// This is a stand-in, not a real embedding model: it captures lexical
/// overlap STATISTICALLY so hybrid (dense + BM25) demos run fully offline
/// with no network and no 90MB download. Trigram hashing gives near-duplicate
/// and paraphrase-level similarity; it does NOT understand meaning the way a
/// transformer does. Swap it with a real model through the embedder adapter
/// when one lands — the search API is identical.
abstract final class DemoEmbedder {
  static const int dim = 128;

  static Float32List embed(String text) {
    final counts = Float32List(dim);
    final normalized = text.toLowerCase();
    final units = normalized.runes.toList();
    if (units.isEmpty) return counts;
    for (var i = 0; i < units.length; i++) {
      var h = 2166136261;
      for (var j = i; j < i + 3 && j < units.length; j++) {
        h ^= units[j];
        h = (h * 16777619) & 0xFFFFFFFF;
      }
      h ^= units.length;
      counts[h % dim] += 1.0;
    }
    var norm = 0.0;
    for (var i = 0; i < dim; i++) {
      norm += counts[i] * counts[i];
    }
    norm = norm == 0 ? 1.0 : math.sqrt(norm);
    for (var i = 0; i < dim; i++) {
      counts[i] /= norm;
    }
    return counts;
  }

  /// Stable fingerprint used in tests to assert embedding determinism.
  static String fingerprint(String text) {
    final v = embed(text);
    final digest = StringBuffer();
    for (var i = 0; i < dim; i += 16) {
      digest.write((v[i] * 1000).toInt().toRadixString(36));
    }
    return base64Encode(utf8.encode(digest.toString()));
  }
}
