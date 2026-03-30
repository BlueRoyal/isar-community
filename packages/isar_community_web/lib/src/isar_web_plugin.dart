// ignore_for_file: public_member_api_docs

/// Helper class for isar_community_web.
///
/// You normally don't need to interact with this directly.
/// It's used internally by the isar_community web bindings.
class IsarCommunityWeb {
  IsarCommunityWeb._();

  /// The expected WASM JS glue filename.
  static const String jsFileName = 'isar_wasm.js';

  /// The expected WASM binary filename.
  static const String wasmFileName = 'isar_wasm_bg.wasm';

  /// Version of the WASM module (must match isar_community version).
  static const String version = '3.3.0';

  /// Instructions shown when WASM files are missing.
  static const String setupInstructions = '''
╔══════════════════════════════════════════════════════════╗
║  isar_community_web: WASM files not found!               ║
║                                                          ║
║  Run this command in your Flutter project root:          ║
║                                                          ║
║    dart run isar_community_web:setup                     ║
║                                                          ║
║  This copies the WASM binaries to your web/ directory.   ║
╚══════════════════════════════════════════════════════════╝
''';
}
