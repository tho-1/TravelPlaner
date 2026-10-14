/// Per-device app settings, a small JSON file the app owns
/// (`app_settings.json`).
///
/// The desktop keeps it in the folder the config's
/// `state_dir` names (the repo root, next to the other
/// per-device state); the phone, which configures no
/// paths, falls back to its documents directory -- the
/// same split every per-device file here uses. The shell
/// resolves the directory once and hands it in, so this
/// class stays plain file IO and the tests run against a
/// temp dir.
///
/// A missing or unreadable file is the default settings,
/// never a crash; a failed *write* is reported (`false`)
/// so the caller can surface it -- the write-loss
/// invariant the repositories follow.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AppSettings {
  /// Whether opening a destination records an
  /// open-destination tab (the legacy sidebar's list).
  final bool openTabsEnabled;

  const AppSettings({this.openTabsEnabled = true});

  static const _fileName = 'app_settings.json';

  /// The file path for a resolved settings directory.
  static String filePath(String dir) => p.join(dir, _fileName);

  /// Load from a resolved directory. A missing or broken
  /// file is the defaults.
  static AppSettings load(String dir) {
    try {
      final text = File(filePath(dir)).readAsStringSync();
      final map = jsonDecode(text) as Map<String, dynamic>;
      return AppSettings(
        openTabsEnabled: map['open_tabs_enabled'] is bool
            ? map['open_tabs_enabled'] as bool
            : true,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  /// Write atomically (tmp + rename, the geocode cache's
  /// pattern) so a crash mid-write cannot truncate the
  /// file. Returns `false` when the write failed.
  bool save(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final path = filePath(dir);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'open_tabs_enabled': openTabsEnabled,
        }),
      );
      tmp.renameSync(path);
      return true;
    } catch (_) {
      return false;
    }
  }
}
