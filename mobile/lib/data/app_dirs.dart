/// Per-device cache directories.
///
/// The configured directory (from `turso_config.json`)
/// wins. When none is configured -- the phone, where the
/// config carries no paths -- the app's own documents
/// directory is used, so a file the app writes itself
/// (a researched transport connection) survives a
/// restart instead of costing another DeepSeek call.
/// The PC-side caches (pictures, the legacy's caches)
/// stay configured-only: those are per-machine files
/// the app does not create.
library;

import 'package:path_provider/path_provider.dart';

/// The app's documents directory, resolved once at
/// startup: `main` awaits [initAppDirs] before the
/// first frame.
String? _documentsDir;

Future<void> initAppDirs() async {
  _documentsDir =
      (await getApplicationDocumentsDirectory()).path;
}

Future<String> perDeviceCacheDir(String configured) async {
  if (configured.trim().isNotEmpty) return configured;
  final dir = _documentsDir;
  if (dir != null) return dir;
  try {
    // Not initialized (a test that skipped
    // [initAppDirs]): resolve on demand.
    return (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    // No documents directory available (the test
    // binding): unconfigured, the previous behavior.
    return '';
  }
}
