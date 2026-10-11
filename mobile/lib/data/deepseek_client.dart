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
import 'flight_routes.dart' show isChinaDestination;

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

/// The food system prompt, ported verbatim from
/// `deepseek_client.generate_food_profile` -- the
/// prompt is the project's asset, so it travels
/// exactly as the legacy sends it.
const foodSystemPrompt =
    'You are a precise travel food researcher. Return only valid JSON. '
    'Write grounded, specific information about local food in the named city.';

/// The food user template (a plain template, not an
/// interpolation, so the JSON braces survive); the
/// placeholders are substituted below.
const foodUserTemplate = '''Describe the local food in __DEST__, __COUNTRY__.

Return exactly this JSON object:
{
  "spiciness": number,
  "dishes": ["Dish 1", "Dish 2", "Dish 3", "Dish 4", "Dish 5"],
  "description": "one paragraph of 5 to 10 sentences"
}

Rules:
- Focus especially on how spicy the local food is and mention representative dishes.
- Rate spiciness from 0 (not spicy at all) to 10 (Sichuan spicy); values above 10 are allowed.
- In "dishes", list 4 to 8 representative main dishes named in their local language (using Romanized script/transliteration, e.g. "Masala Dosa", "Ven Pongal", "Chettinad Chicken", "Pad Thai", "Tom Yum Goong", "Ceviche").
- The description must be one paragraph containing 5 to 10 complete sentences.
- Discuss the typical local food, not only one restaurant or isolated dish.
''';

/// The transport system prompt, ported verbatim
/// from `deepseek_client.generate_flight_routes`
/// -- the prompt is the project's asset.
const flightRoutesSystemPrompt =
    'You are a professional aviation network and '
    'high-speed rail transit analyst. Return only valid JSON.';

/// The high-speed rail schema block, inserted
/// for Chinese destinations only.
const _hsrSchema = '''
  "train_stations": ["Primary High-Speed Railway Stations (e.g. Nanchang West Railway Station / 南昌西站, Nanchang Railway Station / 南昌站)"],
  "hsr_routes": [
    {
      "destination_city": "City name (e.g. Changsha)",
      "destination_station": "Arrival Station (e.g. Changsha South)",
      "origin_station": "Departure Station (e.g. Nanchang West)",
      "duration": "Typical Travel Time (e.g. 1h 15m - 1h 35m)",
      "train_types": "G-Train (High-Speed 300-350 km/h) / D-Train",
      "frequency_notes": "e.g. 30+ daily trains (every 15-30 mins)"
    }
  ],''';

/// The high-speed rail intro line, inserted
/// for Chinese destinations only.
const _hsrIntro =
    'Also research all major High-Speed Railway (HSR / 高铁/动车) '
    'connections from this city to other Chinese cities.';

/// The high-speed rail rule line, inserted
/// for Chinese destinations only.
const _hsrRule =
    '- Provide 15 to 30 major direct High-Speed Rail (HSR) connections '
    'to other prominent Chinese cities with accurate travel times.';

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

  /// Ask DeepSeek for the food profile of one destination:
  /// the spiciness, the description and the main dishes.
  /// The Dart port of `deepseek_client.generate_food_profile`
  /// -- the same payload shape and the same validation, so
  /// a response the legacy would reject is rejected here too.
  Future<FoodProfile> generateFoodProfile({
    required String destination,
    required String country,
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
        {'role': 'system', 'content': foodSystemPrompt},
        {
          'role': 'user',
          'content': foodUserTemplate
              .replaceAll('__DEST__', destination.trim())
              .replaceAll('__COUNTRY__', country.trim()),
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
      throw DeepSeekError(
          'Could not reach the DeepSeek API (${error.runtimeType}).');
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
      return parseFoodProfile(extractJson(content));
    } on DeepSeekError {
      // The food validation's own error, not a parse failure.
      rethrow;
    } catch (error) {
      throw DeepSeekError('DeepSeek returned an unparseable response '
          '(${error.runtimeType}).');
    }
  }

  /// Ask DeepSeek for the direct flight routes
  /// (inbound and outbound) and, for Chinese
  /// destinations, the high-speed rail
  /// connections. The Dart port of
  /// `deepseek_client.generate_flight_routes`
  /// -- the same payload shape and the same
  /// validation (the routes must be a list).
  Future<Map<String, dynamic>> generateFlightRoutes({
    required String destination,
    required String country,
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
        {'role': 'system', 'content': flightRoutesSystemPrompt},
        {
          'role': 'user',
          'content': flightRoutesPrompt(
            destination,
            country,
            isChinaDestination(destination, country),
          ),
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0.1,
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
      throw DeepSeekError(
          'Could not reach the DeepSeek API (${error.runtimeType}).');
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
      final result = extractJson(content);
      if (result['routes'] is! List) {
        throw const DeepSeekError(
            'DeepSeek returned an invalid flight route list.');
      }
      result['last_updated'] = _today();
      return result;
    } on DeepSeekError {
      // The route-list validation's own error, not a parse failure.
      rethrow;
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

/// Build the transport research prompt: the
/// flight-route template with the destination
/// and country substituted, and the high-speed
/// rail parts inserted for Chinese cities.
String flightRoutesPrompt(
    String destination, String country, bool isChina) {
  final dest = destination.trim();
  final ctry = country.trim();
  final hsrIntro = isChina ? _hsrIntro : '';
  final hsrSchema = isChina ? _hsrSchema : '';
  final hsrRule = isChina ? _hsrRule : '';
  return '''Research all major direct passenger flight routes (inbound and outbound) and operating airlines departing from or arriving at $dest, $ctry.
$hsrIntro

Return ONLY this JSON object:
{
  "airport_name": "Primary Airport Name (e.g. Nanchang Changbei International Airport)",
  "iata_code": "IATA code (e.g. KHN)",
  "city": "$dest",
  "country": "$ctry",$hsrSchema
  "routes": [
    {
      "destination_city": "City name (e.g. Shanghai)",
      "destination_country": "Country name (e.g. China)",
      "destination_iata": "Airport code(s) (e.g. SHA / PVG)",
      "airlines": ["Airline A", "Airline B"],
      "flight_time": "Estimated flight time (e.g. 1h 45m)",
      "route_type": "Domestic" | "International" | "Regional",
      "frequency_notes": "e.g. Multiple flights daily / Daily / 3x weekly / Seasonal"
    }
  ]
}

Rules:
- Include all major direct non-stop destinations that regularly have passenger service from this city's airport(s).
- Direct passenger routes operate bidirectionally (inbound and outbound).
- Ensure the operating airlines list and flight_time estimate (e.g. "2h 15m") are accurate for each route.
- Set route_type appropriately:
  * "Domestic" for domestic flights within the same country
  * "Regional" for Hong Kong, Macau, Taiwan (if applicable) or close regional dependencies
  * "International" for cross-border international destinations
- Provide between 15 to 45 direct flight routes if the airport is a medium/large hub, or all known direct routes if it is a smaller airport.
$hsrRule
- Return ONLY valid JSON.
''';
}

/// `datetime.now().strftime("%d %b %Y")` -- the
/// date the research was done, stamped onto the
/// cached result.
String _today() {
  const months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now();
  return '${now.day.toString().padLeft(2, '0')} '
      '${months[now.month - 1]} ${now.year}';
}

/// The food profile `generate_food_profile` returns:
/// the spiciness rating, the description paragraph and
/// the main dishes in their local language.
class FoodProfile {
  final double spiciness;
  final String description;
  final List<String> dishes;

  const FoodProfile({
    required this.spiciness,
    required this.description,
    required this.dishes,
  });
}

/// Parse and validate the food JSON DeepSeek returned.
/// Pure, so the validation is testable without the API.
///
/// The legacy `generate_food_profile` raises on a
/// negative spiciness, an empty description or a
/// description that is not 5-10 sentences; the same
/// shapes raise [DeepSeekError] here, so a response
/// the legacy would reject is rejected the same way.
FoodProfile parseFoodProfile(Map<String, dynamic> json) {
  final spiciness = _toDouble(json['spiciness']);
  if (spiciness == null) {
    throw const DeepSeekError(
        'DeepSeek returned an invalid food spiciness rating.');
  }
  final description = (json['description'] ?? '').toString().trim();
  final sentenceCount = countFoodSentences(description);
  if (spiciness < 0 ||
      description.isEmpty ||
      sentenceCount < 5 ||
      sentenceCount > 10) {
    throw const DeepSeekError(
        'DeepSeek returned an invalid food profile; expected a '
        '5-10 sentence paragraph and a non-negative spiciness rating.');
  }
  return FoodProfile(
    spiciness: spiciness,
    description: description,
    dishes: parseFoodDishes(json['dishes']),
  );
}

/// `re.findall(r"[^.!?]+[.!?](?:\s|$)", description)`
/// -- the sentence count the legacy validates with.
int countFoodSentences(String description) =>
    RegExp(r'[^.!?]+[.!?](?:\s|$)').allMatches(description).length;

/// The dishes: a list, or a comma/semicolon/newline
/// separated string -- the two shapes the legacy
/// accepts from the model.
List<String> parseFoodDishes(Object? raw) {
  if (raw is String) {
    return [
      for (final part in raw.split(RegExp(r'[,;\n]+')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }
  if (raw is List) {
    return [
      for (final item in raw)
        if (item.toString().trim().isNotEmpty) item.toString().trim(),
    ];
  }
  return const [];
}

/// A number or nothing -- the spiciness arrives as a
/// JSON number but the model sometimes sends a string.
double? _toDouble(Object? value) {
  if (value == null || value is bool) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
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
