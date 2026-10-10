/// Where the Turso credentials come from.
///
/// The Python side reads `.streamlit/secrets.toml` (or the
/// environment); the app reads `assets/turso_config.json`
/// (git-ignored, template committed as `.example`). Both
/// hold the same URL and token. Without the file the app
/// runs unconfigured -- the same state as the Python side
/// without a token, never a crash.
///
/// The token ships in the APK: the user's decision
/// (2026-10-08) for a personal app -- obfuscation is
/// enough, and Turso's token can be revoked any time.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class TursoConfig {
  final String url;
  final String token;

  const TursoConfig({required this.url, required this.token});

  bool get isConfigured => url.trim().isNotEmpty && token.trim().isNotEmpty;

  static const defaultUrl = 'https://travel-tz123.aws-eu-north-1.turso.io';

  /// Load the bundled config. A missing or malformed file
  /// leaves the app unconfigured rather than failing --
  /// the caller decides what an unconfigured app shows.
  static Future<TursoConfig> load() async {
    try {
      final text =
          await rootBundle.loadString('assets/turso_config.json');
      final map = jsonDecode(text) as Map<String, dynamic>;
      return TursoConfig(
        url: (map['url'] as String?)?.trim() ?? defaultUrl,
        token: (map['token'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return const TursoConfig(url: defaultUrl, token: '');
    }
  }
}
