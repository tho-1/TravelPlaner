/// The DeepSeek client: one chat completion that returns the
/// destination profile as JSON.
///
/// The Dart port of `deepseek_client.generate_destination_
/// profile`, prompt and payload included (the prompt is the
/// project's asset -- it is what produces the workbook's
/// data, so it travels verbatim):
///
/// * the same system prompt and user template, with the
///   destination / country / continent substituted;
/// * `response_format: json_object`, temperature 0.3;
/// * a 180-second timeout, because the profile JSON plus
///   the climate arrays is slow;
/// * every failure is a `DeepSeekError` with a
///   user-friendly message: no key, cannot reach, HTTP
///   error, timeout, unparseable response.
///
/// Nothing here touches the app's storage: the parsed
/// profile goes to `ai_populator.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/destination_profile.dart';
import 'ai_config.dart';

class DeepSeekError implements Exception {
  final String message;
  const DeepSeekError(this.message);
  @override
  String toString() => message;
}

const deepseekApiUrl = 'https://api.deepseek.com/chat/completions';
const requestTimeout = Duration(seconds: 180);

const systemPrompt =
    'You are a meticulous travel-research assistant. Given a destination, you '
    'return exactly one JSON object containing everything needed for a travel '
    'planner workbook: a written destination profile, a review sentiment '
    'breakdown, and monthly climate data. Output ONLY valid JSON — no prose, '
    'no markdown, no code fences.';

/// A plain template (not an interpolation) so the JSON
/// braces survive; the placeholders are substituted below.
const userTemplate = """Return ONLY a JSON object for the travel destination "__DEST__" in __COUNTRY__ (__CONTINENT__).

Use exactly this schema:
{
  "destination": "__DEST__",
  "country": "__COUNTRY__",
  "continent": "__CONTINENT__",
  "profile": {
    "why_to_go": "2-3 sentence pitch",
    "what_to_expect": "3-4 sentence description of what it is like there",
    "ideal_time_to_go": "e.g. Spring (April-May) and Autumn (September-October)",
    "avoid_going": "e.g. Winter (December-February) (very cold)",
    "recommended_stay": "e.g. 3-4 days",
    "avg_cost_per_day_eur": number,
    "rent_a_car": "No" or "Yes" or "Sometimes",
    "highlights": "a sentence listing the top highlights",
    "population_metro": number of people (metro area, NOT millions),
    "reachable_via": "e.g. High-speed rail, Flights to XXX",
    "visa_requirement": "for German citizens, one of: 'Not at all' / 'ETA' / 'Visa on arrival' / 'Apply beforehand'",
    "flight_time_hours": number (flight time from Frankfurt),
    "safety_rating_10": number from 0 to 10 (10 = safest),
    "introduction_sentence": "one catchy introductory sentence",
    "in_eu": true or false,
    "month_ratings": {
      "January": "ideal|ok|bad", "February": "ideal|ok|bad", "March": "ideal|ok|bad",
      "April": "ideal|ok|bad", "May": "ideal|ok|bad", "June": "ideal|ok|bad",
      "July": "ideal|ok|bad", "August": "ideal|ok|bad", "September": "ideal|ok|bad",
      "October": "ideal|ok|bad", "November": "ideal|ok|bad", "December": "ideal|ok|bad"
    }
  },
  "reviews": {
    "praise": "detailed paragraph of 5 to 10 complete sentences about what travelers praise",
    "dislikes": "detailed paragraph of 5 to 10 complete sentences about recurring criticisms and dislikes",
    "total_reviews_analyzed": 100,
    "date_range": "Feb 2024 - Feb 2026",
    "aspects": {
      "Scenery & atmosphere": {"pos": int, "neutral": int, "neg": int},
      "Things to do": {"pos": int, "neutral": int, "neg": int},
      "Food & drink": {"pos": int, "neutral": int, "neg": int},
      "Value for money": {"pos": int, "neutral": int, "neg": int},
      "Crowds & overtourism": {"pos": int, "neutral": int, "neg": int},
      "Safety & cleanliness": {"pos": int, "neutral": int, "neg": int},
      "Getting around / accessibility": {"pos": int, "neutral": int, "neg": int}
    },
    "platform_ratings": [
      {"source_name": "Google Maps", "avg_rating": number 1-5, "review_count": int},
      {"source_name": "TripAdvisor", "avg_rating": number 1-5, "review_count": int}
    ]
  },
  "climate": {
    "high_c": [12 numbers, January to December],
    "low_c": [12 numbers, January to December],
    "rainy_days": [12 numbers, January to December],
    "rain_mm": [12 numbers, January to December],
    "aqi": [12 numbers, January to December]
  }
}

Rules:
- month_ratings values must be exactly "ideal", "ok", or "bad".
- "praise" and "dislikes" must each be a detailed, comprehensive paragraph containing 5 to 10 complete sentences.
- Each aspect's pos+neutral+neg should be realistic; the positive share should
  reflect how much travelers like that aspect for this destination.
- Each climate array must contain exactly 12 numbers, ordered January through December.
- avg_cost_per_day_eur is for a 3-star hotel plus food, in EUR.
- population_metro is the metro-area population in people (not millions).
- All values must be plausible for the real destination (real climate, real visa
  rules, real safety, real flight times from Frankfurt, Germany).
""";

/// Re-exported from the profile parser: the months the
/// prompt template names, in the workbook's own order.
final monthsFull = fullMonths;
final monthsShort = monthAbbreviations;

class DeepSeekClient {
  final AiConfig config;
  final http.Client httpClient;

  DeepSeekClient(this.config, {http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

  /// Call the API and return the parsed profile. Throws
  /// [DeepSeekError] with a user-friendly message on any
  /// failure, never a raw exception.
  Future<Map<String, dynamic>> generateDestinationProfile({
    required String destination,
    required String country,
    required String continent,
  }) async {
    if (!config.isConfigured) {
      throw const DeepSeekError(
        'The DeepSeek API key is not configured. Add '
        '"deepseek_api_key" to assets/turso_config.json '
        '(git-ignored) and try again.',
      );
    }
    final payload = {
      'model': config.model.isEmpty ? AiConfig.defaultModel : config.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': userPrompt(destination, country, continent),
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0.3,
    };
    final http.Response response;
    try {
      response = await httpClient
          .post(
            Uri.parse(deepseekApiUrl),
            headers: {
              'Authorization': 'Bearer ${config.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(requestTimeout);
    } catch (error) {
      throw DeepSeekError('Could not reach the DeepSeek API (${error.runtimeType}).');
    }
    if (response.statusCode != 200) {
      throw DeepSeekError(
        'DeepSeek API request failed (HTTP ${response.statusCode}): '
        '${_snippet(response.body)}',
      );
    }
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final content = ((data['choices'] as List).first
          as Map)['message']['content'] as String;
      return extractJson(content);
    } catch (error) {
      throw DeepSeekError('DeepSeek returned an unparseable response '
          '(${error.runtimeType}).');
    }
  }

  static String userPrompt(
      String destination, String country, String continent) {
    return userTemplate
        .replaceAll('__DEST__', destination.trim())
        .replaceAll('__COUNTRY__', country.trim())
        .replaceAll('__CONTINENT__', continent.trim());
  }

  static String _snippet(String body) =>
      body.length <= 300 ? body : body.substring(0, 300);
}

/// Parse a JSON object out of a chat response. Tolerates
/// ```json fences and leading prose, the same shapes the
/// legacy `_extract_json` tolerates -- the model is asked
/// for bare JSON but does not always obey.
Map<String, dynamic> extractJson(String text) {
  var body = (text).trim();
  final fence = RegExp(r'```(?:json)?\s*(.*?)```',
          dotAll: true, caseSensitive: false)
      .firstMatch(body);
  if (fence != null) body = fence.group(1)!.trim();
  final start = body.indexOf('{');
  final end = body.lastIndexOf('}');
  if (start != -1 && end > start) {
    body = body.substring(start, end + 1);
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const DeepSeekError('DeepSeek returned no JSON object.');
  }
  return Map<String, dynamic>.from(decoded);
}
