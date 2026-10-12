import 'package:waffle_db/src/rust/frb_generated.dart' show RustLib;
import 'package:waffle_db/src/rust/loader.dart';

/// Core entrypoint for the WaffleDB plugin.
abstract class WaffleDB {
  WaffleDB._();

  static bool _initialized = false;

  /// Whether [init] has completed (idempotent: repeated calls are cheap).
  static bool get isInitialized => _initialized;

  /// Initializes the Rust bindings and underlying FFI bridges.
  /// Must be called before using any WaffleDB functionality.
  static Future<void> init() async {
    await NativeLibraryLoader.init();
    _initialized = true;
  }
}
