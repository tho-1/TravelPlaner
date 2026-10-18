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
///
/// Beyond the open-tabs switch, this file also holds
/// per-device overrides for the API keys bundled in
/// `assets/turso_config.json`. An override wins over the
/// bundled value, so a key can be rotated on the device
/// without rebuilding the app. The overrides are consulted
/// by [TursoConfig.load] and [AiConfig.load] through the
/// package-private [configOverrides] holder the shell sets
/// once at startup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The overrides the shell has resolved; consulted by the
/// config loaders so every caller picks up a rotated key
/// without threading the settings directory through every
/// constructor.
AppSettings? _configOverrides;

/// The overrides currently in effect (set by the shell
/// after loading `app_settings.json`), or null while only
/// the bundled config applies.
AppSettings? get configOverrides => _configOverrides;

/// Install the overrides the shell resolved; call once at
/// startup, and again whenever the user rotates a key.
void setConfigOverrides(AppSettings? settings) =>
    _configOverrides = settings;

class AppSettings {
  /// Whether opening a destination records an
  /// open-destination tab (the legacy sidebar's list).
  final bool openTabsEnabled;

  /// Override for the bundled Turso token. Null means the
  /// bundled value applies.
  final String? tursoToken;

  /// Override for the bundled benefits-token. Null means the
  /// bundled value applies.
  final String? benefitsToken;

  /// Override for the bundled DeepSeek key. Null means the
  /// bundled value applies.
  final String? deepseekApiKey;

  /// Override for the bundled FlightAware key. Null means
  /// the bundled value applies.
  final String? flightAwareApiKey;
  final String? deepseekModel;

  const AppSettings({
    this.openTabsEnabled = true,
    this.tursoToken,
    this.benefitsToken,
    this.deepseekApiKey,
    this.flightAwareApiKey,
    this.deepseekModel,
  });

  /// A copy with the named field replaced (null clears it),
  /// used when the user rotates a single key.
  AppSettings copyWith({
    bool? openTabsEnabled,
    String? tursoToken,
    String? benefitsToken,
    String? deepseekApiKey,
    String? flightAwareApiKey,
    String? deepseekModel,
  }) {
    return AppSettings(
      openTabsEnabled: openTabsEnabled ?? this.openTabsEnabled,
      tursoToken: tursoToken,
      benefitsToken: benefitsToken,
      deepseekApiKey: deepseekApiKey,
      flightAwareApiKey: flightAwareApiKey,
      deepseekModel: deepseekModel,
    );
  }

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
        tursoToken: _str(map, 'turso_token'),
        benefitsToken: _str(map, 'benefits_token'),
        deepseekApiKey: _str(map, 'deepseek_api_key'),
        flightAwareApiKey: _str(map, 'flight_aware_api_key'),
        deepseekModel: _str(map, 'deepseek_model'),
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  static String? _str(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Write atomically (tmp + rename, the geocode cache's
  /// pattern) so a crash mid-write cannot truncate the
  /// file. Returns `false` when the write failed.
  bool save(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final path = filePath(dir);
      final tmp = File('$path.tmp');
      final json = <String, dynamic>{
        'open_tabs_enabled': openTabsEnabled,
      };
      if (tursoToken != null) json['turso_token'] = tursoToken;
      if (benefitsToken != null) json['benefits_token'] = benefitsToken;
      if (deepseekApiKey != null) json['deepseek_api_key'] = deepseekApiKey;
       if (flightAwareApiKey != null) {
         json['flight_aware_api_key'] = flightAwareApiKey;
       }
       if (deepseekModel != null) json['deepseek_model'] = deepseekModel;
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(json),
      );
      tmp.renameSync(path);
      return true;
    } catch (_) {
      return false;
    }
  }
}
