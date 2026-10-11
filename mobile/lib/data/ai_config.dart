/// The AI key configuration: the DeepSeek API key and the
/// model, read from the same bundled config file the Turso
/// credentials live in.
///
/// The legacy side reads `deepseek_secrets.py` (or
/// `DEEPSEEK_API_KEY`, or Streamlit secrets); the app reads
/// `assets/turso_config.json`, which is git-ignored, under
/// `deepseek_api_key` / `deepseek_model`. Missing is a
/// normal state: the AI features stay hidden rather than
/// erroring, exactly like the legacy page's behaviour
/// without a key.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class AiConfig {
  final String apiKey;
  final String model;

  const AiConfig({this.apiKey = '', this.model = ''});

  bool get isConfigured => apiKey.trim().isNotEmpty;

  static const defaultModel = 'deepseek-chat';

  /// Load the AI half of the config. A missing file leaves
  /// the key empty, which is a configured-but-hidden
  /// feature, not a crash.
  static Future<AiConfig> load() async {
    try {
      final text =
          await rootBundle.loadString('assets/turso_config.json');
      final map = jsonDecode(text) as Map<String, dynamic>;
      return AiConfig(
        apiKey: (map['deepseek_api_key'] as String?)?.trim() ?? '',
        model: (map['deepseek_model'] as String?)?.trim() ?? defaultModel,
      );
    } catch (_) {
      return const AiConfig();
    }
  }
}
