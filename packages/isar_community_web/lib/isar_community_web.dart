/// Web support for isar_community.
///
/// This package provides pre-built WASM binaries that enable SQLite-backed
/// Isar in Flutter Web applications.
///
/// ## Setup
///
/// 1. Add to `pubspec.yaml`:
///    ```yaml
///    dependencies:
///      isar_community: ^3.3.0
///      isar_community_web: ^3.3.0
///    ```
///
/// 2. Run setup (copies WASM files to web/):
///    ```bash
///    dart run isar_community_web:setup
///    ```
///
/// 3. That's it! Use Isar normally — web support is automatic:
///    ```dart
///    final isar = await Isar.open([MySchema]);
///    ```
library isar_community_web;

export 'src/isar_web_plugin.dart' show IsarCommunityWeb;
