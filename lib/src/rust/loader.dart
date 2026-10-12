import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'frb_generated.dart';

/// Internal native-library bootstrap shared by the app, tests and benchmarks.
///
/// Resolution order:
/// 1. [explicitPath] when given.
/// 2. Default FRB loader (used on mobile/desktop where flutter/cargokit
///    bundles the library inside the app).
/// 3. Script-relative `rust/target/release/<lib>` (plain `dart run` /
///    `dart test` from a source checkout; requires a prior
///    `cargo build --release --manifest-path rust/Cargo.toml`).
///    Desktop only: application sandboxes have no checkout layout.
@internal
class NativeLibraryLoader {
  const NativeLibraryLoader._();

  static String platformLibName() {
    if (Platform.isAndroid) return 'libwaffle_db.so';
    if (Platform.isIOS) return 'libwaffle_db.dylib';
    if (Platform.isLinux) return 'libwaffle_db.so';
    if (Platform.isMacOS) return 'libwaffle_db.dylib';
    if (Platform.isWindows) return 'waffle_db.dll';
    throw UnsupportedError('Unsupported OS: ${Platform.operatingSystem}');
  }

  static Future<void> init({String? explicitPath}) async {
    if (explicitPath != null) {
      final file = File(explicitPath);
      if (!file.existsSync()) {
        throw StateError(
          'Native library not found at $explicitPath. '
          'Build it first: cargo build --release --manifest-path rust/Cargo.toml',
        );
      }
      await RustLib.init(externalLibrary: ExternalLibrary.open(explicitPath));
      return;
    }
    try {
      await RustLib.init();
      return;
    } catch (e) {
      if (Platform.isAndroid || Platform.isIOS) rethrow;
    }
    final libPath = _findCheckoutLibrary();
    if (!File(libPath).existsSync()) {
      throw StateError(
        'Native library not found at $libPath.\n'
        'Build it first: cargo build --release --manifest-path rust/Cargo.toml',
      );
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(libPath));
  }

  static String _findCheckoutLibrary() {
    var dir = File(Platform.script.toFilePath()).parent;
    final sep = Platform.pathSeparator;
    for (var i = 0; i < 6; i++) {
      if (File('${dir.path}${sep}rust${sep}Cargo.toml').existsSync()) {
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return '${dir.path}${sep}rust${sep}target${sep}release$sep${platformLibName()}';
  }
}
