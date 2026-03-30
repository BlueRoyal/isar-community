// ignore_for_file: avoid_print
//
// Setup script for isar_community_web.
//
// Run with:  dart run isar_community_web:setup
//
// This copies the pre-built WASM binaries from the package into
// your Flutter project's web/ directory so that "flutter build web"
// picks them up automatically.

import 'dart:io';

import 'package:path/path.dart' as p;

void main(List<String> args) {
  print('');
  print('╔══════════════════════════════════════════════╗');
  print('║  isar_community_web setup                    ║');
  print('╚══════════════════════════════════════════════╝');
  print('');

  // ── 1. Locate project root ────────────────────────────────────────

  final projectRoot = Directory.current.path;
  final webDir = Directory(p.join(projectRoot, 'web'));

  if (!webDir.existsSync()) {
    print('❌  No web/ directory found at: ${webDir.path}');
    print('    Make sure you run this from your Flutter project root.');
    print('    Try:  flutter create . --platforms=web');
    exit(1);
  }

  // ── 2. Locate package assets ──────────────────────────────────────

  final packageRoot = _findPackageRoot();
  if (packageRoot == null) {
    print('❌  Could not locate isar_community_web package.');
    print('    Run: flutter pub get');
    exit(1);
  }

  final assetsDir = Directory(p.join(packageRoot, 'assets'));
  if (!assetsDir.existsSync()) {
    print('❌  Assets directory not found in package: ${assetsDir.path}');
    print('    The package might be corrupted. Try: flutter pub get --force');
    exit(1);
  }

  // ── 3. Copy WASM files ────────────────────────────────────────────

  final files = [
    'isar_wasm.js',
    'isar_wasm_bg.wasm',
  ];

  var copied = 0;
  for (final fileName in files) {
    final source = File(p.join(assetsDir.path, fileName));
    final target = File(p.join(webDir.path, fileName));

    if (!source.existsSync()) {
      print('⚠️   $fileName not found in package assets – skipping');
      continue;
    }

    // Check if target already exists and is identical
    if (target.existsSync()) {
      final sourceSize = source.lengthSync();
      final targetSize = target.lengthSync();
      if (sourceSize == targetSize) {
        print('  ✓ $fileName (already up to date)');
        copied++;
        continue;
      }
    }

    source.copySync(target.path);
    final sizeKB = (source.lengthSync() / 1024).round();
    print('  ✓ $fileName (${sizeKB} KB) → web/');
    copied++;
  }

  // ── 4. Check index.html for COOP/COEP headers ────────────────────

  final indexHtml = File(p.join(webDir.path, 'index.html'));
  var headerWarning = false;

  if (indexHtml.existsSync()) {
    final content = indexHtml.readAsStringSync();
    if (!content.contains('Cross-Origin-Opener-Policy')) {
      headerWarning = true;
    }
  }

  // ── 5. Summary ────────────────────────────────────────────────────

  print('');

  if (copied == files.length) {
    print('✅  Setup complete! $copied files copied to web/');
  } else {
    print('⚠️   Setup incomplete: $copied/${files.length} files copied.');
    print('    Run "flutter pub get" and try again.');
  }

  if (headerWarning) {
    print('');
    print('⚠️   OPFS (persistent storage) requires COOP/COEP headers.');
    print('    Add these to web/index.html inside <head>:');
    print('');
    print('    <meta http-equiv="Cross-Origin-Opener-Policy"');
    print('          content="same-origin" />');
    print('    <meta http-equiv="Cross-Origin-Embedder-Policy"');
    print('          content="require-corp" />');
    print('');
    print('    Without them, Isar falls back to in-memory storage');
    print('    (data will not persist across sessions).');
  }

  print('');
  print('🚀  Ready! Run: flutter run -d chrome');
  print('');
}

/// Walk up from the .dart_tool/package_config.json to find our package path.
String? _findPackageRoot() {
  final projectRoot = Directory.current.path;

  // Try .dart_tool/package_config.json (Dart 2.19+)
  final packageConfig = File(
    p.join(projectRoot, '.dart_tool', 'package_config.json'),
  );

  if (packageConfig.existsSync()) {
    final content = packageConfig.readAsStringSync();
    // Simple parse: find our package entry
    // Format: {"name":"isar_community_web","rootUri":"...","packageUri":"lib/"}
    final regex = RegExp(
      r'"name"\s*:\s*"isar_community_web"[^}]*"rootUri"\s*:\s*"([^"]+)"',
    );
    final match = regex.firstMatch(content);
    if (match != null) {
      var rootUri = match.group(1)!;
      // rootUri can be relative to .dart_tool/ or absolute
      if (rootUri.startsWith('file://')) {
        rootUri = Uri.parse(rootUri).toFilePath();
      } else {
        rootUri = p.normalize(
          p.join(projectRoot, '.dart_tool', rootUri),
        );
      }
      if (Directory(rootUri).existsSync()) {
        return rootUri;
      }
    }
  }

  // Fallback: check pub cache paths
  final pubCache = Platform.environment['PUB_CACHE'] ??
      (Platform.isWindows
          ? p.join(Platform.environment['LOCALAPPDATA']!, 'Pub', 'Cache')
          : p.join(Platform.environment['HOME']!, '.pub-cache'));

  final hostedDir = Directory(
    p.join(pubCache, 'hosted', 'pub.dev', 'isar_community_web-3.3.0'),
  );
  if (hostedDir.existsSync()) return hostedDir.path;

  // Fallback: path dependency (monorepo)
  final monoRepo = Directory(
    p.join(projectRoot, '..', 'isar_community_web'),
  );
  if (monoRepo.existsSync()) return monoRepo.path;

  // Also check packages/ structure
  final packagesDir = Directory(
    p.join(projectRoot, 'packages', 'isar_community_web'),
  );
  if (packagesDir.existsSync()) return packagesDir.path;

  return null;
}
