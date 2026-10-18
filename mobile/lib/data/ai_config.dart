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
///
/// **Storing the key inside the app is a decision, not an
/// oversight** (user, 2026-10-11): DeepSeek has no
/// auto-recharge enabled, so the worst case of an extracted
/// key is a spend of at most ~10 EUR before the user notices
/// and rotates it. That blast radius is accepted; the
/// alternative (routing the populate through the PC's API)
/// would tie the phone feature to a running PC, which the
/// user did not want. The same reasoning already applies to
/// the Turso token, which is revocable the same way.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'app_settings.dart' show configOverrides;

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
      final bundledKey = (map['deepseek_api_key'] as String?)?.trim() ?? '';
      final effectiveKey = configOverrides?.deepseekApiKey ??
          bundledKey;
      final bundledModel = (map['deepseek_model'] as String?)?.trim() ?? defaultModel;
      final effectiveModel = configOverrides?.deepseekModel ?? bundledModel;
      return AiConfig(
        apiKey: effectiveKey,
        model: effectiveModel.isEmpty ? defaultModel : effectiveModel,
      );
    } catch (_) {
      return const AiConfig();
    }
  }
}
