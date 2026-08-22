import 'package:waffle_db/src/rust/frb_generated.dart' show RustLib;

/// Core entrypoint for the WaffleDB plugin.
abstract class WaffleDB {
  /// Initializes the Rust bindings and underlying FFI bridges.
  /// Must be called before using any WaffleDB functionality.
  static Future<void> init() async {
    await RustLib.init();
  }
}
