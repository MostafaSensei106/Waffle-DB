import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'frb_generated.dart';

/// Internal native-library bootstrap (moved out of `example/tool/` so all
/// entry points — app, tests, benchmarks — share one path).
///
/// Resolution order:
/// 1. [explicitPath] when given (from [MathOptConfig.libraryPath]).
/// 2. Default FRB loader (works under flutter/cargokit where the
///    library is already bundled).
/// 3. Script-relative `rust/target/release/<lib>` (plain `dart run` /
///    `dart test` from source checkout; requires a prior
///    `cargo build --release --manifest-path rust/Cargo.toml`).
@internal
class NativeLibraryLoader {
  const NativeLibraryLoader._();

  static String platformLibName() {
    if (Platform.isLinux) return 'libdart_mathopt.so';
    if (Platform.isMacOS) return 'libdart_mathopt.dylib';
    if (Platform.isWindows) return 'dart_mathopt.dll';
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
    } on Object {
      // Fall through to script-relative resolution below.
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
